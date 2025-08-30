--[[
SystemLib.lua v1.0
===================
System-wide utility library for Mach4 scripts
Provides shared functionality while scripts retain their business logic
This is a TOOLKIT, not a framework - scripts choose what to use

Modules:
- Core: Basic infrastructure and utilities
- Safety: Shared safety checks and validation
- Tools: Tool management utilities
- Machine: Machine state queries
- Profile: Settings persistence
- Signals: Signal handling utilities
- Display: Common formatting functions
- Validation: Input validation helpers

Usage:
  local SystemLib = require("Scripts/System/SystemLib")
  local inst = mc.mcGetInstance()
  
  -- Use what you need
  if not SystemLib.Safety.CheckHoming(inst) then
      -- Handle unhomed state
  end
]]--
 
local SystemLib = {}

-- =======================
-- Core Module
-- =======================
SystemLib.Core = {}

-- One-time initialization (if needed)
SystemLib.Core.initialized = false
function SystemLib.Core.Init(inst)
    if SystemLib.Core.initialized then return end
    inst = inst or mc.mcGetInstance()
    
    -- Any one-time setup here
    SystemLib.Core.initialized = true
    return true
end

-- Get instance with caching
local cachedInstance = nil
function SystemLib.Core.GetInstance()
    if not cachedInstance then
        cachedInstance = mc.mcGetInstance()
    end
    return cachedInstance
end

-- Get profile directory path
function SystemLib.Core.ProfilePath(inst)
    inst = inst or SystemLib.Core.GetInstance()
    return mc.mcProfileGetString(inst, "Preferences", "ProfileDir", "")
end

-- Production-aware debug printing
SystemLib.Core.PRODUCTION_MODE = true  -- Set to false for debugging
function SystemLib.Core.DebugPrint(inst, message)
    if not SystemLib.Core.PRODUCTION_MODE then
        inst = inst or SystemLib.Core.GetInstance()
        mc.mcCntlSetLastError(inst, "[DEBUG] " .. tostring(message))
    end
end

-- Safe function call with error handling
function SystemLib.Core.SafeCall(func, ...)
    local ok, result = pcall(func, ...)
    if not ok then
        SystemLib.Core.DebugPrint(nil, "SafeCall error: " .. tostring(result))
        return nil, result
    end
    return result, nil
end

-- =======================
-- Safety Module
-- =======================
SystemLib.Safety = {}

-- Check if all enabled axes are homed
function SystemLib.Safety.CheckHoming(inst, showMessage)
    inst = inst or SystemLib.Core.GetInstance()
    local allHomed = true
    local unhomedAxes = {}
    
    for axis = 0, 5 do  -- Check X, Y, Z, A, B, C
        local enabled = mc.mcAxisIsEnabled(inst, axis)
        local homed = mc.mcAxisIsHomed(inst, axis)
        
        if enabled == 1 and homed ~= 1 then
            allHomed = false
            local axisNames = {[0]="X", [1]="Y", [2]="Z", [3]="A", [4]="B", [5]="C"}
            table.insert(unhomedAxes, axisNames[axis])
        end
    end
    
    if not allHomed and showMessage then
        local msg = "Please home axes: " .. table.concat(unhomedAxes, ", ")
        wx.wxMessageBox(msg, "Homing Required", wx.wxOK + wx.wxICON_WARNING)
    end
    
    return allHomed, unhomedAxes
end

-- Validate move against soft limits
function SystemLib.Safety.ValidateSoftLimits(inst, x, y, z)
    inst = inst or SystemLib.Core.GetInstance()
    
    -- Check if soft limits are enabled
    local softLimitsOn = mc.mcSoftLimitGetState(inst, mc.X_AXIS) == 1
    if not softLimitsOn then return true end
    
    -- Check each axis if provided
    local axes = {
        [mc.X_AXIS] = x,
        [mc.Y_AXIS] = y, 
        [mc.Z_AXIS] = z
    }
    
    for axis, value in pairs(axes) do
        if value then
            local min = mc.mcSoftLimitGetMin(inst, axis)
            local max = mc.mcSoftLimitGetMax(inst, axis)
            if value < min or value > max then
                return false, string.format("Move exceeds soft limits on axis %d", axis)
            end
        end
    end
    
    return true
end

-- Check if coordinate rotation (G68) is active
function SystemLib.Safety.CheckRotation(inst)
    inst = inst or SystemLib.Core.GetInstance()
    local modalGroup = mc.mcCntlGetPoundVar(inst, 4016) -- G68/G69 modal group
    return modalGroup == 68  -- G68 is active
end


-- Combined safety validation for moves
function SystemLib.Safety.ValidateMove(inst, x, y, z)
    inst = inst or SystemLib.Core.GetInstance()
    
    -- Check homing
    local homed = SystemLib.Safety.CheckHoming(inst, false)
    if not homed then
        return false, "Axes not homed"
    end
    
    -- Check soft limits
    local valid, err = SystemLib.Safety.ValidateSoftLimits(inst, x, y, z)
    if not valid then
        return false, err
    end
    
    -- Check machine state
    if not SystemLib.Machine.IsEnabled(inst) then
        return false, "Machine not enabled"
    end
    
    return true
end

-- =======================
-- Tool Module (renamed from Tools for consistency)
-- =======================
SystemLib.Tool = {}

-- Activate tool with optional deploy output (for probes/laser)
-- deployOutput: optional mc.OSIG_* handle; deployOn: 1/0
function SystemLib.Tool.Activate(inst, toolNumber, deployOutput, deployOn)
    deployOn = (deployOn == nil) and 1 or deployOn
    if mc.mcToolGetCurrent(inst) ~= toolNumber then
        mc.mcCntlGcodeExecuteWait(inst, string.format("T%d M6", toolNumber))
    end
    if deployOutput then
        local h = mc.mcSignalGetHandle(inst, deployOutput)
        mc.mcSignalSetState(h, deployOn)
        wx.wxMilliSleep(300)
    end
    return mc.mcToolGetCurrent(inst) == toolNumber
end

-- =======================
-- Tools Module (Legacy compatibility)
-- =======================
SystemLib.Tools = {}

-- Get current tool number
function SystemLib.Tools.GetCurrentTool(inst)
    inst = inst or SystemLib.Core.GetInstance()
    return mc.mcToolGetCurrent(inst)
end

-- Synchronize height offset with tool number
function SystemLib.Tools.SyncHOffset(inst, toolNum)
    inst = inst or SystemLib.Core.GetInstance()
    toolNum = toolNum or SystemLib.Tools.GetCurrentTool(inst)
    
    -- Cancel current offset
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    
    -- Apply new offset if tool > 0
    if toolNum > 0 and toolNum < 90 then  -- Physical tools only
        mc.mcCntlGcodeExecuteWait(inst, string.format("G43 H%d", toolNum))
        return true
    end
    
    return false
end

-- Check if tool is virtual (90-99)
function SystemLib.Tools.IsVirtualTool(toolNum)
    return toolNum >= 90 and toolNum <= 99
end

-- Validate tool number
function SystemLib.Tools.ValidateToolNumber(toolNum)
    if type(toolNum) ~= "number" then
        return false, "Tool number must be numeric"
    end
    
    if toolNum < 0 or toolNum > 99 then
        return false, "Tool number must be 0-99"
    end
    
    return true
end

-- Get tool description
function SystemLib.Tools.GetToolDescription(inst, toolNum)
    inst = inst or SystemLib.Core.GetInstance()
    toolNum = toolNum or SystemLib.Tools.GetCurrentTool(inst)
    
    local valid = SystemLib.Tools.ValidateToolNumber(toolNum)
    if not valid then return "Invalid Tool" end
    
    if toolNum == 0 then return "No Tool" end
    
    local desc = mc.mcToolGetDesc(inst, toolNum)
    return desc or string.format("Tool %d", toolNum)
end

-- =======================
-- Machine Module
-- =======================
SystemLib.Machine = {}

-- Get current machine state
function SystemLib.Machine.GetMachineState(inst)
    inst = inst or SystemLib.Core.GetInstance()
    return mc.mcCntlGetState(inst)
end

-- Check if machine is enabled
function SystemLib.Machine.IsEnabled(inst)
    inst = inst or SystemLib.Core.GetInstance()
    local handle = mc.mcSignalGetHandle(inst, mc.OSIG_MACHINE_ENABLED)
    if handle and handle > 0 then
        return mc.mcSignalGetState(handle) == 1
    end
    return false
end

-- Check if in cycle
function SystemLib.Machine.IsInCycle(inst)
    inst = inst or SystemLib.Core.GetInstance()
    return mc.mcCntlIsInCycle(inst) == 1
end

-- Get modal group value
function SystemLib.Machine.GetModalGroup(inst, group)
    inst = inst or SystemLib.Core.GetInstance()
    return mc.mcCntlGetPoundVar(inst, group)
end

-- Safe G-code execution with error handling
function SystemLib.Machine.SafeExecuteGCode(inst, gcode)
    inst = inst or SystemLib.Core.GetInstance()
    
    local rc = mc.mcCntlGcodeExecuteWait(inst, gcode)
    if rc ~= mc.MERROR_NOERROR then
        return false, string.format("G-code execution failed: %d", rc)
    end
    
    return true
end

-- =======================
-- Profile Module
-- =======================
SystemLib.Profile = {}

-- Save setting to profile
function SystemLib.Profile.SaveSetting(inst, section, key, value)
    inst = inst or SystemLib.Core.GetInstance()
    
    if type(value) == "boolean" then
        value = value and "true" or "false"
    elseif type(value) == "number" then
        value = tostring(value)
    end
    
    mc.mcProfileWriteString(inst, section, key, value)
    return true
end

-- Load setting from profile
function SystemLib.Profile.LoadSetting(inst, section, key, default)
    inst = inst or SystemLib.Core.GetInstance()
    
    local value = mc.mcProfileGetString(inst, section, key, "")
    if value == "" then
        return default
    end
    
    -- Try to convert to appropriate type
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    elseif tonumber(value) then
        return tonumber(value)
    else
        return value
    end
end

-- Save dialog geometry
function SystemLib.Profile.SaveDialogGeometry(inst, name, dialog)
    inst = inst or SystemLib.Core.GetInstance()
    
    local x, y = dialog:GetPosition():GetXY()
    local w, h = dialog:GetSize():GetWidth(), dialog:GetSize():GetHeight()
    
    SystemLib.Profile.SaveSetting(inst, "DialogGeometry", name .. "_x", x)
    SystemLib.Profile.SaveSetting(inst, "DialogGeometry", name .. "_y", y)
    SystemLib.Profile.SaveSetting(inst, "DialogGeometry", name .. "_w", w)
    SystemLib.Profile.SaveSetting(inst, "DialogGeometry", name .. "_h", h)
    
    return true
end

-- Restore dialog geometry
function SystemLib.Profile.RestoreDialogGeometry(inst, name, dialog)
    inst = inst or SystemLib.Core.GetInstance()
    
    local x = SystemLib.Profile.LoadSetting(inst, "DialogGeometry", name .. "_x", -1)
    local y = SystemLib.Profile.LoadSetting(inst, "DialogGeometry", name .. "_y", -1)
    local w = SystemLib.Profile.LoadSetting(inst, "DialogGeometry", name .. "_w", -1)
    local h = SystemLib.Profile.LoadSetting(inst, "DialogGeometry", name .. "_h", -1)
    
    if x >= 0 and y >= 0 then
        dialog:SetPosition(wx.wxPoint(x, y))
    else
        dialog:Centre()
    end
    
    if w > 0 and h > 0 then
        dialog:SetSize(wx.wxSize(w, h))
    end
    
    return true
end

-- Create settings backup
function SystemLib.Profile.BackupSettings(inst)
    inst = inst or SystemLib.Core.GetInstance()
    -- This would create a backup of critical settings
    -- Implementation depends on what needs backing up
    return true
end

-- ============================================
-- STORAGE MODULE - Centralized settings storage
-- ============================================
SystemLib.Storage = {}

-- Create settings manager for a module
-- Uses Machine.ini with consistent section naming
function SystemLib.Storage.CreateSettings(inst, moduleName, defaults)
    local settings = {
        inst = inst,
        section = "Settings_" .. moduleName,  -- Consistent prefix
        defaults = defaults or {}
    }
    
    -- Get setting with type conversion
    function settings:get(key, default)
        default = default or self.defaults[key]
        local value = mc.mcProfileGetString(self.inst, self.section, key, "")
        
        -- Return default if empty
        if value == "" then
            return default
        end
        
        -- Auto type conversion
        if value == "true" then return true
        elseif value == "false" then return false
        elseif tonumber(value) then return tonumber(value)
        else return value
        end
    end
    
    -- Set setting (no auto-flush for performance)
    function settings:set(key, value)
        -- Convert to string
        if type(value) == "boolean" then
            value = value and "true" or "false"
        else
            value = tostring(value)
        end
        
        return mc.mcProfileWriteString(self.inst, self.section, key, value) == mc.MERROR_NOERROR
    end
    
    -- Type-specific helpers
    function settings:getInt(key, default)
        local val = self:get(key, default)
        return math.floor(tonumber(val) or default or 0)
    end
    
    function settings:getFloat(key, default)
        local val = self:get(key, default)
        return tonumber(val) or default or 0.0
    end
    
    function settings:getBool(key, default)
        local val = self:get(key, default)
        if type(val) == "boolean" then return val end
        return val == "true" or val == "1"
    end
    
    return settings
end

-- =======================
-- Signals Module
-- =======================
SystemLib.Signals = {}

-- Get signal state safely
function SystemLib.Signals.GetSignalState(inst, signal)
    inst = inst or SystemLib.Core.GetInstance()
    
    local handle = mc.mcSignalGetHandle(inst, signal)
    if not handle or handle <= 0 then
        return nil, "Invalid signal handle"
    end
    
    return mc.mcSignalGetState(handle)
end

-- Set signal state safely
function SystemLib.Signals.SetSignalState(inst, signal, state)
    inst = inst or SystemLib.Core.GetInstance()
    
    local handle = mc.mcSignalGetHandle(inst, signal)
    if not handle or handle <= 0 then
        return false, "Invalid signal handle"
    end
    
    mc.mcSignalSetState(handle, state and 1 or 0)
    return true
end

-- Get signal handle with validation
function SystemLib.Signals.GetSignalHandle(inst, signal)
    inst = inst or SystemLib.Core.GetInstance()
    
    local handle = mc.mcSignalGetHandle(inst, signal)
    if not handle or handle <= 0 then
        return nil
    end
    
    return handle
end

-- Monitor signal for changes (returns current and previous)
function SystemLib.Signals.MonitorSignalChange(inst, signal, lastState)
    inst = inst or SystemLib.Core.GetInstance()
    
    local currentState = SystemLib.Signals.GetSignalState(inst, signal)
    if currentState == nil then
        return nil, nil, false
    end
    
    local changed = (lastState ~= nil) and (currentState ~= lastState)
    return currentState, lastState, changed
end

-- Mirror input signal to output with protection
function SystemLib.Signals.MirrorSignal(inst, inputSignal, outputSignal, protect)
    inst = inst or SystemLib.Core.GetInstance()
    
    -- Optional protection check (like M6 running)
    if protect and protect(inst) then
        return false, "Protection active"
    end
    
    local inputState = SystemLib.Signals.GetSignalState(inst, inputSignal)
    if inputState == nil then
        return false, "Invalid input signal"
    end
    
    return SystemLib.Signals.SetSignalState(inst, outputSignal, inputState)
end

-- =======================
-- Display Module  
-- =======================
SystemLib.Display = {}

-- Format seconds to HH:MM:SS
function SystemLib.Display.SecondsToTime(seconds)
    if not seconds or seconds < 0 then
        return "00:00:00"
    end
    
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    return string.format("%02d:%02d:%02.0f", hours, mins, secs)
end

-- Convert decimal to fraction
function SystemLib.Display.DecToFrac(value)
    if not value then return "0" end
    
    local sign = value < 0 and "-" or ""
    value = math.abs(value)
    
    local whole = math.floor(value)
    local remainder = value - whole
    
    -- Find closest fraction (1/16 resolution)
    local sixteenths = math.floor(remainder * 16 + 0.5)
    
    if sixteenths == 0 then
        return sign .. tostring(whole)
    elseif sixteenths == 16 then
        return sign .. tostring(whole + 1)
    end
    
    -- Reduce fraction
    local num, denom = sixteenths, 16
    while num % 2 == 0 and denom % 2 == 0 do
        num = num / 2
        denom = denom / 2
    end
    
    if whole > 0 then
        return string.format("%s%d %d/%d", sign, whole, num, denom)
    else
        return string.format("%s%d/%d", sign, num, denom)
    end
end

-- Format coordinate for display
function SystemLib.Display.FormatCoordinate(value, precision)
    precision = precision or 4
    if not value then return "0.0000" end
    
    return string.format("%." .. precision .. "f", value)
end

-- Set last error message
function SystemLib.Display.SetLastError(inst, message)
    inst = inst or SystemLib.Core.GetInstance()
    mc.mcCntlSetLastError(inst, message)
end

-- Show message box
function SystemLib.Display.ShowMessageBox(message, title, type)
    type = type or wx.wxOK + wx.wxICON_INFORMATION
    return wx.wxMessageBox(message, title, type)
end

-- =======================
-- Validation Module
-- =======================
SystemLib.Validation = {}

-- Validate numeric value with range
function SystemLib.Validation.ValidateNumeric(value, min, max)
    local num = tonumber(value)
    if not num then
        return false, "Not a valid number"
    end
    
    if min and num < min then
        return false, string.format("Value must be >= %g", min)
    end
    
    if max and num > max then
        return false, string.format("Value must be <= %g", max)
    end
    
    return true, num
end

-- Validate feed rate
function SystemLib.Validation.ValidateFeedRate(rate)
    local valid, num = SystemLib.Validation.ValidateNumeric(rate, 0.1, 500)
    if not valid then
        return false, "Feed rate must be between 0.1 and 500 IPM"
    end
    return true, num
end

-- Validate coordinate value
function SystemLib.Validation.ValidateCoordinate(value, axis)
    local num = tonumber(value)
    if not num then
        return false, "Invalid coordinate value"
    end
    
    -- Could add axis-specific limits here
    return true, num
end

-- Validate file path
function SystemLib.Validation.ValidatePath(path)
    if not path or path == "" then
        return false, "Path cannot be empty"
    end
    
    -- Check for invalid characters
    if path:match("[<>:|?*]") then
        return false, "Path contains invalid characters"
    end
    
    return true
end

-- Create error report from validation errors
function SystemLib.Validation.CreateErrorReport(errors)
    if not errors or #errors == 0 then
        return nil
    end
    
    local report = "Validation Errors:\n"
    for i, err in ipairs(errors) do
        report = report .. string.format("%d. %s\n", i, err)
    end
    
    return report
end

-- =======================
-- Laser Module - Emergency shutoff utilities
-- =======================
SystemLib.Laser = {}

function SystemLib.Laser.EmergencyShutoff(inst)
    inst = inst or SystemLib.Core.GetInstance()
    
    -- Turn off hardware output
    local h = mc.mcSignalGetHandle(inst, mc.OSIG_OUTPUT1)
    if h and h > 0 then
        mc.mcSignalSetState(h, 0)
    end
    
    -- Disable ESS registers for safety
    local success1, hregActivate = pcall(mc.mcRegGetHandle, inst, "ESS/Laser/Test_Mode_Activate")
    local success2, hregEnable = pcall(mc.mcRegGetHandle, inst, "ESS/Laser/Test_Mode_Enable")
    
    local result = false
    if success1 and hregActivate and mc.mcRegGetValue(hregActivate) == 1 then
        mc.mcRegSetValue(hregActivate, 0)
        result = true
    end
    if success2 and hregEnable and mc.mcRegGetValue(hregEnable) == 1 then
        mc.mcRegSetValue(hregEnable, 0)
        result = true
    end
    
    return result
end

-- =======================
-- Module Return
-- =======================
return SystemLib