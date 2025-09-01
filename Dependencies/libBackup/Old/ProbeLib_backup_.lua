-- ProbeLibrary v2.1 - Utility Toolkit
-- Core utilities for probe scripts - not a framework
-- Generated: 2025-08-27 | Simplified per revision plan
--
-- This library provides utilities, not architecture.
-- Scripts retain their business logic and flow control.

local ProbeLib = {
    VERSION = "2.1.0"
}

-- ============================================
-- CONSTANTS
-- ============================================
ProbeLib.CONSTANTS = {
    PROBE_TOOL = 90,
    PROBE_OUTPUT = mc.OSIG_OUTPUT7,
    PROBE_SIGNAL = mc.ISIG_PROBE1,
    SENTINEL_VALUE = -999999.0,
    SENTINEL_FLAG_VAR = 388,
    SENTINEL_VARS = {389, 390, 391, 392, 394},
    POSITION_TOLERANCE = 0.001,
    SOFT_LIMIT_BUFFER = 0.010,
    PROBE_SETTLE_MS = 100
}

-- ============================================
-- CORE MODULE - Infrastructure utilities
-- ============================================
ProbeLib.Core = {}

-- Get Mach4 instance with validation
function ProbeLib.Core.GetInstance()
    local inst = mc.mcGetInstance()
    if not inst then
        error("No Mach4 instance found!")
    end
    return inst
end

-- Check if probe is triggered
function ProbeLib.Core.IsProbeTriggered(inst)
    local probeHandle = mc.mcSignalGetHandle(inst, ProbeLib.CONSTANTS.PROBE_SIGNAL)
    return mc.mcSignalGetState(probeHandle) == 1
end

-- Check if probe tool is active
function ProbeLib.Core.IsProbeToolActive(inst)
    local currentTool = mc.mcToolGetCurrent(inst)
    return currentTool == ProbeLib.CONSTANTS.PROBE_TOOL
end

-- Check if probe is deployed
function ProbeLib.Core.IsProbeDeployed(inst)
    local probeDownHandle = mc.mcSignalGetHandle(inst, ProbeLib.CONSTANTS.PROBE_OUTPUT)
    return mc.mcSignalGetState(probeDownHandle) == 1
end

-- Get profile path
function ProbeLib.Core.GetProfilePath(inst)
    local profileName = mc.mcProfileGetName(inst)
    local machDir = mc.mcCntlGetMachDir(inst)
    return machDir .. "\\Profiles\\" .. profileName
end

-- Activate probe tool with dialog if needed
function ProbeLib.Core.ActivateProbeTool(inst)
    local currentTool = mc.mcToolGetCurrent(inst)
    local probeDownHandle = mc.mcSignalGetHandle(inst, ProbeLib.CONSTANTS.PROBE_OUTPUT)
    local probeDeployed = mc.mcSignalGetState(probeDownHandle)
    
    -- Check if probe is already active
    if currentTool == ProbeLib.CONSTANTS.PROBE_TOOL and probeDeployed == 1 then
        return true  -- Already active
    end
    
    -- Determine parent window
    local parent = wx.NULL
    local app = wx.wxGetApp()
    if app then
        local ok, top = pcall(function() return app:GetTopWindow() end)
        if ok and top then parent = top end
    end
    
    -- Show error dialog
    local dlgW, dlgH = 340, 200
    local sw = wx.wxSystemSettings.GetMetric(wx.wxSYS_SCREEN_X) or 1024
    local sh = wx.wxSystemSettings.GetMetric(wx.wxSYS_SCREEN_Y) or 768
    local posX = math.floor((sw - dlgW) / 2)
    local posY = math.floor((sh - dlgH) / 2)
    
    local errorDlg = wx.wxDialog(parent, wx.wxID_ANY,
        "Probe Not Active",
        wx.wxPoint(posX, posY), wx.wxSize(dlgW, dlgH),
        wx.wxDEFAULT_DIALOG_STYLE)
    
    local panel = wx.wxPanel(errorDlg, wx.wxID_ANY)
    local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
    
    -- Error message
    local msg = wx.wxStaticText(panel, wx.wxID_ANY,
        "Please activate T90 (probe) before using this function.\n\n" ..
        "Click 'Change Tool to T90' to activate the probe,\n" ..
        "or 'Cancel' to exit.")
    msg:SetFont(wx.wxFont(10, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL))
    sizer:Add(msg, 1, wx.wxALL + wx.wxALIGN_CENTER, 20)
    
    -- Button sizer
    local btnSizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    
    -- Change Tool button
    local changeBtn = wx.wxButton(panel, wx.wxID_ANY, "Change Tool to T90")
    changeBtn:SetMinSize(wx.wxSize(130, 28))
    btnSizer:Add(changeBtn, 0, wx.wxRIGHT, 10)
    
    -- Cancel button
    local cancelBtn = wx.wxButton(panel, wx.wxID_CANCEL, "Cancel")
    cancelBtn:SetMinSize(wx.wxSize(90, 28))
    btnSizer:Add(cancelBtn, 0, wx.wxLEFT, 0)
    
    sizer:Add(btnSizer, 0, wx.wxALIGN_CENTER + wx.wxBOTTOM, 15)
    
    -- Handle Change Tool button
    changeBtn:Connect(wx.wxID_ANY, wx.wxEVT_COMMAND_BUTTON_CLICKED, function(event)
        errorDlg:EndModal(wx.wxID_YES)  -- Use YES as indicator to change tool
    end)
    
    panel:SetSizer(sizer)
    errorDlg:Centre()
    
    local result = errorDlg:ShowModal()
    errorDlg:Destroy()
    
    if result == wx.wxID_YES then
        -- Execute tool change
        mc.mcCntlGcodeExecuteWait(inst, "T90 M6")
        mc.mcCntlSetLastError(inst, "T90 activated - probe ready")
        return true
    else
        return false  -- User cancelled
    end
end

-- ============================================
-- MOVEMENT MODULE - Basic probe movements
-- ============================================
ProbeLib.Movement = {}

-- Enable sentinel mode for probe failure detection
function ProbeLib.Movement.EnableSentinel(inst)
    local sentinel = ProbeLib.CONSTANTS.SENTINEL_VALUE
    mc.mcCntlSetPoundVar(inst, ProbeLib.CONSTANTS.SENTINEL_FLAG_VAR, 1)
    for _, var in ipairs(ProbeLib.CONSTANTS.SENTINEL_VARS) do
        mc.mcCntlSetPoundVar(inst, var, sentinel)
    end
end

-- Disable sentinel mode
function ProbeLib.Movement.DisableSentinel(inst)
    mc.mcCntlSetPoundVar(inst, ProbeLib.CONSTANTS.SENTINEL_FLAG_VAR, 0)
end

-- Check if probe hit based on sentinel value
function ProbeLib.Movement.CheckHit(inst, varNum)
    local value = mc.mcCntlGetPoundVar(inst, varNum)
    return value ~= nil and value ~= ProbeLib.CONSTANTS.SENTINEL_VALUE
end

-- Execute a basic probe move (simplified - scripts handle sequencing)
-- Returns: success (bool), position (number or nil), machine_pos (number or nil)
function ProbeLib.Movement.ExecuteProbe(inst, direction, label)
    label = label or "probe"
    
    -- Map direction to probe variable
    local dirMap = {
        [1] = 389,  -- +X (S1)
        [2] = 390,  -- -X (S2)
        [3] = 391,  -- +Y (S3)
        [4] = 392,  -- -Y (S4)
        [5] = 394,  -- -Z (S5)
        [6] = 393   -- +Z (S6)
    }
    
    local varNum = dirMap[direction]
    if not varNum then
        return false, nil, nil
    end
    
    -- Enable sentinel
    ProbeLib.Movement.EnableSentinel(inst)
    
    -- Execute M311 S[direction]
    local gcode = string.format("M311 S%d", direction)
    mc.mcCntlGcodeExecuteWait(inst, gcode)
    
    -- Check result
    local hit = ProbeLib.Movement.CheckHit(inst, varNum)
    
    if hit then
        local workPos = mc.mcCntlGetPoundVar(inst, varNum)
        
        -- Get machine position based on direction
        local axis = (direction <= 2) and 0 or ((direction <= 4) and 1 or 2)
        local machinePos = mc.mcAxisGetMachinePos(inst, axis)
        
        -- Disable sentinel
        ProbeLib.Movement.DisableSentinel(inst)
        
        return true, workPos, machinePos
    else
        -- Disable sentinel
        ProbeLib.Movement.DisableSentinel(inst)
        return false, nil, nil
    end
end

-- ============================================
-- SAFETY MODULE - Safety checks
-- ============================================
ProbeLib.Safety = {}

-- Check if position is within soft limits
function ProbeLib.Safety.CheckSoftLimits(inst, axis, position)
    local min, max
    
    if axis == 0 then  -- X
        min = mc.mcCntlGetPoundVar(inst, 310) or -10
        max = mc.mcCntlGetPoundVar(inst, 311) or 10
    elseif axis == 1 then  -- Y
        min = mc.mcCntlGetPoundVar(inst, 312) or -10
        max = mc.mcCntlGetPoundVar(inst, 313) or 10
    elseif axis == 2 then  -- Z
        min = mc.mcCntlGetPoundVar(inst, 314) or -10
        max = mc.mcCntlGetPoundVar(inst, 315) or 10
    else
        return false
    end
    
    local buffer = ProbeLib.CONSTANTS.SOFT_LIMIT_BUFFER
    return position >= (min + buffer) and position <= (max - buffer)
end

-- Validate travel distance is reasonable
function ProbeLib.Safety.ValidateTravel(distance, maxAllowed)
    maxAllowed = maxAllowed or 10.0
    return math.abs(distance) <= maxAllowed
end

-- ============================================
-- CALCULATIONS MODULE - Common math utilities
-- ============================================
ProbeLib.Calculations = {}

-- Calculate center from two edges (single axis)
function ProbeLib.Calculations.GetCenter(edge1, edge2)
    if not edge1 or not edge2 then
        return nil
    end
    return (edge1 + edge2) / 2
end

-- Calculate width/distance between edges
function ProbeLib.Calculations.GetWidth(edge1, edge2)
    if not edge1 or not edge2 then
        return nil
    end
    return math.abs(edge1 - edge2)
end

-- Convert angle to normalized range
function ProbeLib.Calculations.NormalizeAngle(angle)
    while angle > 180 do
        angle = angle - 360
    end
    while angle < -180 do
        angle = angle + 360
    end
    return angle
end

-- Calculate angle from two points
function ProbeLib.Calculations.GetAngle(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local angle = math.deg(math.atan2(dy, dx))
    return ProbeLib.Calculations.NormalizeAngle(angle)
end

-- Check if dimensions are reasonably perpendicular
function ProbeLib.Calculations.CheckPerpendicularity(width1, width2, tolerance)
    tolerance = tolerance or 0.95
    local ratio = math.min(width1, width2) / math.max(width1, width2)
    return ratio >= tolerance
end

-- ============================================
-- STORAGE MODULE - Settings persistence
-- ============================================
ProbeLib.Storage = {}

-- Create settings object for a script
function ProbeLib.Storage.CreateSettings(inst, scriptName, defaults)
    local settings = {
        inst = inst,
        scriptName = scriptName,
        defaults = defaults or {},
        profilePath = ProbeLib.Core.GetProfilePath(inst)
    }
    
    -- Load a setting with default fallback
    function settings:get(key, default)
        default = default or self.defaults[key]
        local fullKey = self.scriptName .. "_" .. key
        local fileName = self.profilePath .. "\\probe_settings.ini"
        
        local file = io.open(fileName, "r")
        if file then
            for line in file:lines() do
                local k, v = line:match("([^=]+)=(.+)")
                if k == fullKey then
                    file:close()
                    return v
                end
            end
            file:close()
        end
        return default
    end
    
    -- Get integer setting
    function settings:getInt(key, default)
        local value = self:get(key, default)
        return tonumber(value) or default
    end
    
    -- Get float setting
    function settings:getFloat(key, default)
        local value = self:get(key, default)
        return tonumber(value) or default
    end
    
    -- Get boolean setting
    function settings:getBool(key, default)
        local value = self:get(key, default)
        if type(value) == "boolean" then
            return value
        end
        return value == "true" or value == "1"
    end
    
    -- Save a setting
    function settings:set(key, value)
        local fullKey = self.scriptName .. "_" .. key
        local fileName = self.profilePath .. "\\probe_settings.ini"
        
        -- Read existing settings
        local settings = {}
        local file = io.open(fileName, "r")
        if file then
            for line in file:lines() do
                local k, v = line:match("([^=]+)=(.+)")
                if k and k ~= fullKey then
                    settings[k] = v
                end
            end
            file:close()
        end
        
        -- Update setting
        settings[fullKey] = tostring(value)
        
        -- Write back
        file = io.open(fileName, "w")
        if file then
            for k, v in pairs(settings) do
                file:write(k .. "=" .. v .. "\n")
            end
            file:close()
        end
    end
    
    -- Convenience setters
    function settings:setInt(key, value)
        self:set(key, tostring(value))
    end
    
    function settings:setFloat(key, value)
        self:set(key, string.format("%.6f", value))
    end
    
    function settings:setBool(key, value)
        self:set(key, value and "true" or "false")
    end
    
    return settings
end

-- ============================================
-- LOGGING MODULE - Event logging to CSV
-- ============================================
ProbeLib.Logging = {}

-- Detect CSV format (4 or 6 columns) by checking header
function ProbeLib.Logging.DetectCSVFormat(fileName)
    local file = io.open(fileName, "r")
    if not file then
        return 6  -- Default to new format for new files
    end
    
    local firstLine = file:read("*l")
    file:close()
    
    if not firstLine then
        return 6  -- Default for empty files
    end
    
    -- Count commas to determine format
    local commaCount = 0
    for i = 1, #firstLine do
        if firstLine:sub(i, i) == "," then
            commaCount = commaCount + 1
        end
    end
    
    -- 3 commas = 4 columns (old format)
    -- 5 commas = 6 columns (new format)
    if commaCount <= 3 then
        return 4
    else
        return 6
    end
end

-- Log probe event to CSV
function ProbeLib.Logging.LogEvent(inst, probeType, x, y, z, details)
    local profilePath = ProbeLib.Core.GetProfilePath(inst)
    local fileName = profilePath .. "\\probe_log.csv"
    
    -- Detect existing format
    local columnCount = ProbeLib.Logging.DetectCSVFormat(fileName)
    
    -- Check if file exists
    local file = io.open(fileName, "r")
    local exists = file ~= nil
    if file then file:close() end
    
    -- Open for append
    file = io.open(fileName, "a")
    if not file then return false end
    
    -- Write header if new file
    if not exists then
        if columnCount == 6 then
            file:write("Timestamp,ProbeType,X,Y,Z,Details\n")
        else
            file:write("Timestamp,X,Y,Z\n")
        end
    end
    
    -- Write data
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    if columnCount == 6 then
        file:write(string.format("%s,%s,%.4f,%.4f,%.4f,%s\n",
            timestamp, probeType or "", x or 0, y or 0, z or 0, details or ""))
    else
        -- Old format - just log coordinates
        file:write(string.format("%s,%.4f,%.4f,%.4f\n",
            timestamp, x or 0, y or 0, z or 0))
    end
    
    file:close()
    return true
end

-- ============================================
-- GCODE MODULE - G-code generation utilities
-- ============================================
ProbeLib.GCode = {}

-- Generate G-code for setting work offset
function ProbeLib.GCode.SetWorkOffset(x, y, z)
    local parts = {}
    if x ~= nil then table.insert(parts, string.format("X%.4f", x)) end
    if y ~= nil then table.insert(parts, string.format("Y%.4f", y)) end
    if z ~= nil then table.insert(parts, string.format("Z%.4f", z)) end
    
    if #parts > 0 then
        return "G10 L20 P0 " .. table.concat(parts, " ")
    end
    return nil
end

-- Generate safe retract move
function ProbeLib.GCode.Retract(axis, distance, feedrate)
    feedrate = feedrate or 30
    return string.format("G91 G1 %s%.4f F%.1f", axis, distance, feedrate)
end

-- Generate absolute move
function ProbeLib.GCode.MoveAbsolute(x, y, z, rapid)
    local mode = rapid and "G0" or "G1"
    local parts = {mode}
    if x ~= nil then table.insert(parts, string.format("X%.4f", x)) end
    if y ~= nil then table.insert(parts, string.format("Y%.4f", y)) end
    if z ~= nil then table.insert(parts, string.format("Z%.4f", z)) end
    
    if #parts > 1 then
        return table.concat(parts, " ")
    end
    return nil
end

-- ============================================
-- CLEANUP MODULE - Standard cleanup
-- ============================================
ProbeLib.Cleanup = {}

-- Standard cleanup after probe operation
function ProbeLib.Cleanup.Standard(inst, success, errorMsg)
    -- Ensure we're in absolute mode
    mc.mcCntlGcodeExecuteWait(inst, "G90")
    
    -- Clear any errors if successful
    if success then
        mc.mcCntlSetLastError(inst, "Probe complete")
    else
        if errorMsg then
            mc.mcCntlSetLastError(inst, "Probe failed: " .. errorMsg)
        end
    end
    
    -- Ensure sentinel is disabled
    ProbeLib.Movement.DisableSentinel(inst)
end

-- ============================================
-- Return the library
-- ============================================
return ProbeLib