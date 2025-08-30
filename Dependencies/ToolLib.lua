-- ToolLib.lua v1.0
-- Single owner of tool-related outputs and state
-- Manages physical tools, virtual tools, and tool change operations

local ToolLib = {
    VERSION = "1.0.0"
}

-- ============================================
-- CONSTANTS
-- ============================================
local PV = {
    -- Virtual tool state
    VIRTUAL_TOOL = 406,      -- Active virtual tool (0=none, 90-99=virtual)
    X_DELTA = 407,           -- X offset applied
    Y_DELTA = 408,           -- Y offset applied
    
    -- Virtual tool config
    PROBE_X_OFFSET = 301,
    PROBE_Y_OFFSET = 302,
    LASER_X_OFFSET = 318,
    LASER_Y_OFFSET = 319,
    
    -- G68 coordination
    G68_STORED_X = 440,
    G68_STORED_Y = 441,
    G68_STORED_R = 442,
    G68_NEEDS_RESTORE = 443,
    
    -- Tool change state
    M6_RUNNING = 499,
    DIALOG_SUPPRESS = 498,
    LAST_PHYSICAL = 351,
    
    -- Height measurement
    WORK_SURFACE_Z = 353,
    PROBE_STATION_X = 311,
    PROBE_STATION_Y = 312,
}

local OUTPUT = {
    LASER = mc.OSIG_OUTPUT1,
    CLAMP = mc.OSIG_OUTPUT2,
    PROBE = mc.OSIG_OUTPUT7,
}

local INPUT = {
    CLAMP_BUTTON = mc.ISIG_INPUT8,
    TOOL_PRESENT = mc.ISIG_INPUT17,
}

local SENTINEL = -999999
local MAX_OFFSET = 12.0

-- ============================================
-- STATE MANAGEMENT
-- ============================================
local S = {
    init = false,
    handles = {},
    lastOutputs = {
        probe = -1,
        laser = -1,
        clamp = -1,
    },
    lastVirtual = -1,
    log = {},
}

-- ============================================
-- UTILITIES
-- ============================================
local function getPV(inst, var, default)
    local v = mc.mcCntlGetPoundVar(inst, var)
    if v == nil or v < -1e300 then
        return default or 0
    end
    return v
end

local function setPV(inst, var, value)
    mc.mcCntlSetPoundVar(inst, var, value)
end

local function getHandle(inst, sig)
    local h = mc.mcSignalGetHandle(inst, sig)
    if h and h > 0 then return h end
    return nil
end

local function pushLog(msg)
    table.insert(S.log, string.format("[%.3f] %s", os.clock(), msg))
    if #S.log > 100 then table.remove(S.log, 1) end
end

-- Check if machine is in safe state for modal changes
local function isSafeForModalChange(inst)
    -- Check if in cycle
    local inCycle = mc.mcCntlIsInCycle(inst)
    if inCycle == 1 then
        mc.mcCntlSetLastError(inst, "DEBUG: In cycle check failed - mcCntlIsInCycle=1")
        return false, "Cannot change modes during program execution"
    end
    
    -- State check removed - it's useless since M6 always runs as state 200 (macro)
    -- The important checks are: not in cycle and axes not moving
    
    -- Check for axis motion
    for axis = 0, 5 do
        if mc.mcAxisIsEnabled(inst, axis) == 1 then
            local vel = mc.mcAxisGetVel(inst, axis)
            if math.abs(vel) > 0.001 then
                local axisName = ({"X","Y","Z","A","B","C"})[axis + 1]
                mc.mcCntlSetLastError(inst, string.format("DEBUG: Axis %s in motion - vel=%.4f", axisName, vel))
                return false, string.format("Axes in motion (%s vel=%.4f)", axisName, vel)
            end
        end
    end
    
    return true
end

-- Get virtual tool configuration
local function getVirtualToolConfig(inst, toolNum)
    if toolNum == 90 then
        return {
            name = "Probe",
            xOffset = getPV(inst, PV.PROBE_X_OFFSET, 0),
            yOffset = getPV(inst, PV.PROBE_Y_OFFSET, 0),
            output = OUTPUT.PROBE
        }
    elseif toolNum == 91 then
        return {
            name = "Laser",
            xOffset = getPV(inst, PV.LASER_X_OFFSET, 0),
            yOffset = getPV(inst, PV.LASER_Y_OFFSET, 0),
            output = OUTPUT.LASER
        }
    else
        -- Tools 92-99 not configured
        return nil
    end
end

-- ============================================
-- INITIALIZATION
-- ============================================
function ToolLib.init(inst)
    if S.init then return true end
    
    -- Get handles
    S.handles = {
        probe = getHandle(inst, OUTPUT.PROBE),
        laser = getHandle(inst, OUTPUT.LASER),
        clamp = getHandle(inst, OUTPUT.CLAMP),
        toolPresent = getHandle(inst, INPUT.TOOL_PRESENT),
        clampButton = getHandle(inst, INPUT.CLAMP_BUTTON),
    }
    
    -- Initialize state from hardware
    if S.handles.probe then
        S.lastOutputs.probe = mc.mcSignalGetState(S.handles.probe)
    end
    if S.handles.laser then
        S.lastOutputs.laser = mc.mcSignalGetState(S.handles.laser)
    end
    if S.handles.clamp then
        S.lastOutputs.clamp = mc.mcSignalGetState(S.handles.clamp)
    end
    
    S.lastVirtual = getPV(inst, PV.VIRTUAL_TOOL, 0)
    S.init = true
    
    pushLog("ToolLib initialized")
    return true
end

-- ============================================
-- CORE UPDATE (Called by PLC every cycle)
-- ============================================
function ToolLib.update(inst)
    if not S.init then ToolLib.init(inst) end
    
    local virtualTool = getPV(inst, PV.VIRTUAL_TOOL, 0)
    local m6Running = getPV(inst, PV.M6_RUNNING, 0)
    
    -- Determine target outputs based on state
    local targetProbe = (virtualTool == 90) and 1 or 0
    local targetLaser = (virtualTool == 91) and 1 or 0
    
    -- Write probe output if changed
    if targetProbe ~= S.lastOutputs.probe then
        if S.handles.probe then
            mc.mcSignalSetState(S.handles.probe, targetProbe)
            S.lastOutputs.probe = targetProbe
            pushLog(string.format("Probe output -> %d", targetProbe))
        else
            -- Try to get handle if we don't have it yet
            S.handles.probe = getHandle(inst, OUTPUT.PROBE)
            if S.handles.probe then
                mc.mcSignalSetState(S.handles.probe, targetProbe)
                S.lastOutputs.probe = targetProbe
                pushLog("Probe handle acquired late, output set")
            end
        end
    end
    
    -- Write laser output if changed
    if targetLaser ~= S.lastOutputs.laser then
        if S.handles.laser then
            mc.mcSignalSetState(S.handles.laser, targetLaser)
            S.lastOutputs.laser = targetLaser
            pushLog(string.format("Laser output -> %d", targetLaser))
        else
            -- Try to get handle if we don't have it yet
            S.handles.laser = getHandle(inst, OUTPUT.LASER)
            if S.handles.laser then
                mc.mcSignalSetState(S.handles.laser, targetLaser)
                S.lastOutputs.laser = targetLaser
                pushLog("Laser handle acquired late, output set")
            end
        end
    end
    
    -- Handle tool clamp (OUTPUT2) with protection
    if m6Running ~= 1 and virtualTool < 90 then
        -- Mirror INPUT8 to OUTPUT2 only when safe
        if S.handles.clampButton and S.handles.clamp then
            local buttonState = mc.mcSignalGetState(S.handles.clampButton)
            if buttonState ~= S.lastOutputs.clamp then
                mc.mcSignalSetState(S.handles.clamp, buttonState)
                S.lastOutputs.clamp = buttonState
            end
        end
    end
    
    -- Log virtual tool changes
    if virtualTool ~= S.lastVirtual then
        pushLog(string.format("Virtual tool: %d -> %d", S.lastVirtual, virtualTool))
        S.lastVirtual = virtualTool
    end
end

-- ============================================
-- VIRTUAL TOOL DEPLOYMENT
-- ============================================
function ToolLib.requestDeploy(inst, toolNum)
    -- Validate tool number
    if toolNum < 90 or toolNum > 99 then
        return false, "Invalid virtual tool number"
    end
    
    -- Get tool configuration
    local config = getVirtualToolConfig(inst, toolNum)
    if not config then
        return false, string.format("Virtual tool T%d not configured", toolNum)
    end
    
    -- Check if safe to make modal changes
    local safe, err = isSafeForModalChange(inst)
    if not safe then
        return false, err
    end
    
    -- Check if already active
    local current = getPV(inst, PV.VIRTUAL_TOOL, 0)
    if current == toolNum then
        return true, "Already deployed"
    end
    
    -- Retract different virtual tool if active
    if current >= 90 and current <= 99 then
        local ok, err = ToolLib.requestRetract(inst)
        if not ok then return false, err end
    end
    
    -- Get offsets from config
    local xOffset = config.xOffset
    local yOffset = config.yOffset
    
    -- Validate offsets
    if math.abs(xOffset) > MAX_OFFSET or math.abs(yOffset) > MAX_OFFSET then
        return false, string.format("Offsets too large: X=%.4f Y=%.4f", xOffset, yOffset)
    end
    
    -- Check for negligible offsets (warn if basically zero)
    if math.abs(xOffset) < 0.001 and math.abs(yOffset) < 0.001 then
        pushLog(string.format("WARNING: T%d has near-zero offsets", toolNum))
    end
    
    -- Handle G68 rotation if active
    local g68Active = (getPV(inst, 4016, 69) == 68)
    if g68Active then
        -- Store current G68 state before applying offset
        local currentX = getPV(inst, 1245, 0)  -- G68 X center
        local currentY = getPV(inst, 1246, 0)  -- G68 Y center
        local currentR = getPV(inst, 1247, 0)  -- G68 rotation
        
        setPV(inst, PV.G68_STORED_X, currentX)
        setPV(inst, PV.G68_STORED_Y, currentY)
        setPV(inst, PV.G68_STORED_R, currentR)
        setPV(inst, PV.G68_NEEDS_RESTORE, 1)
        
        -- Cancel G68 temporarily (we'll reapply after offset modification)
        mc.mcCntlGcodeExecuteWait(inst, "G69")
        
        pushLog(string.format("G68 stored for later restoration: X%.4f Y%.4f R%.4f", 
            currentX, currentY, currentR))
    end
    
    -- POUND VARIABLE METHOD: Modify work offsets directly
    -- This makes the virtual tool appear at the spindle position
    -- by subtracting the tool's offset from all work coordinates
    for i = 0, 5 do
        local baseVar = 5221 + (i * 20)  -- G54=#5221, G55=#5241, G56=#5261, G57=#5281, G58=#5301, G59=#5321
        local currentX = getPV(inst, baseVar, 0)
        local currentY = getPV(inst, baseVar + 1, 0)
        
        -- Sanity check - only modify if coordinates look reasonable
        if currentX and currentY and currentX > -1e300 and currentY > -1e300 then
            if math.abs(currentX) < 1000 and math.abs(currentY) < 1000 then
                -- Apply offset: subtract from work coordinates
                -- This shifts the zero point so the virtual tool appears at spindle position
                setPV(inst, baseVar, currentX - xOffset)
                setPV(inst, baseVar + 1, currentY - yOffset)
                
                pushLog(string.format("G%d offsets modified: X%.4f->%.4f Y%.4f->%.4f", 
                    54 + i, currentX, currentX - xOffset, currentY, currentY - yOffset))
            else
                pushLog(string.format("WARNING: G%d coordinates out of range, skipping", 54 + i))
            end
        end
    end
    
    -- Reapply G68 with adjusted center if it was active
    if g68Active then
        local storedX = getPV(inst, PV.G68_STORED_X, 0)
        local storedY = getPV(inst, PV.G68_STORED_Y, 0)
        local storedR = getPV(inst, PV.G68_STORED_R, 0)
        
        -- The G68 center must be adjusted by the same offset we applied to work coordinates
        -- This maintains the rotation center relative to the workpiece
        mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", 
            storedX - xOffset, storedY - yOffset, storedR))
        
        pushLog(string.format("G68 reapplied with adjusted center: X%.4f Y%.4f", 
            storedX - xOffset, storedY - yOffset))
    end
    
    -- Store state
    setPV(inst, PV.VIRTUAL_TOOL, toolNum)
    setPV(inst, PV.X_DELTA, xOffset)
    setPV(inst, PV.Y_DELTA, yOffset)
    
    -- Set current tool
    mc.mcToolSetCurrent(inst, toolNum)
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    mc.mcCntlGcodeExecuteWait(inst, string.format("G43 H%d", toolNum))
    
    pushLog(string.format("Deployed virtual T%d (%s) with work offset modification", toolNum, config.name))
    return true
end

-- ============================================
-- VIRTUAL TOOL RETRACTION
-- ============================================
function ToolLib.requestRetract(inst)
    local current = getPV(inst, PV.VIRTUAL_TOOL, 0)
    
    if current < 90 or current > 99 then
        return true, "No virtual tool active"
    end
    
    -- Check if safe to make modal changes
    local safe, err = isSafeForModalChange(inst)
    if not safe then
        return false, err
    end
    
    -- Get stored deltas
    local xDelta = getPV(inst, PV.X_DELTA, 0)
    local yDelta = getPV(inst, PV.Y_DELTA, 0)
    
    -- Validate deltas before using (corruption check)
    if xDelta < -1e300 or yDelta < -1e300 then
        pushLog("WARNING: Virtual tool deltas corrupted, skipping offset restoration")
        -- Still clear state and turn off hardware
        setPV(inst, PV.VIRTUAL_TOOL, 0)
        setPV(inst, PV.X_DELTA, 0)
        setPV(inst, PV.Y_DELTA, 0)
        mc.mcToolSetCurrent(inst, 0)
        mc.mcCntlGcodeExecuteWait(inst, "G49")
        return true, "Cleared corrupted virtual tool state"
    end
    
    -- Check if G68 needs restoration
    local g68NeedsRestore = getPV(inst, PV.G68_NEEDS_RESTORE, 0) == 1
    if g68NeedsRestore then
        -- Cancel current G68 before restoring offsets
        mc.mcCntlGcodeExecuteWait(inst, "G69")
        pushLog("G68 temporarily cancelled for offset restoration")
    end
    
    -- POUND VARIABLE METHOD: Restore original work offsets
    -- Add the deltas back to return work coordinates to their original values
    for i = 0, 5 do
        local baseVar = 5221 + (i * 20)  -- G54=#5221, G55=#5241, G56=#5261, G57=#5281, G58=#5301, G59=#5321
        local currentX = getPV(inst, baseVar, 0)
        local currentY = getPV(inst, baseVar + 1, 0)
        
        -- Sanity check - only restore if coordinates look reasonable
        if currentX and currentY and currentX > -1e300 and currentY > -1e300 then
            if math.abs(currentX) < 1000 and math.abs(currentY) < 1000 then
                -- Restore offset: add back to work coordinates
                setPV(inst, baseVar, currentX + xDelta)
                setPV(inst, baseVar + 1, currentY + yDelta)
                
                pushLog(string.format("G%d offsets restored: X%.4f->%.4f Y%.4f->%.4f", 
                    54 + i, currentX, currentX + xDelta, currentY, currentY + yDelta))
            else
                pushLog(string.format("WARNING: G%d coordinates out of range, skipping restoration", 54 + i))
            end
        end
    end
    
    -- Restore G68 if it was active
    if g68NeedsRestore then
        local storedX = getPV(inst, PV.G68_STORED_X, 0)
        local storedY = getPV(inst, PV.G68_STORED_Y, 0)
        local storedR = getPV(inst, PV.G68_STORED_R, 0)
        
        -- Restore original G68 with original center
        mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", 
            storedX, storedY, storedR))
        
        -- Clear restoration flag
        setPV(inst, PV.G68_NEEDS_RESTORE, 0)
        
        pushLog(string.format("G68 restored to original: X%.4f Y%.4f R%.4f", storedX, storedY, storedR))
    end
    
    -- Clear state
    setPV(inst, PV.VIRTUAL_TOOL, 0)
    setPV(inst, PV.X_DELTA, 0)
    setPV(inst, PV.Y_DELTA, 0)
    
    -- Set tool to 0
    mc.mcToolSetCurrent(inst, 0)
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    
    pushLog(string.format("Retracted virtual T%d, work offsets restored", current))
    return true
end

-- ============================================
-- TOOL CHANGE SUPPORT
-- ============================================
function ToolLib.openClamp(inst)
    if S.handles.clamp then
        mc.mcSignalSetState(S.handles.clamp, 1)
        S.lastOutputs.clamp = 1
        return true
    end
    return false
end

function ToolLib.closeClamp(inst)
    if S.handles.clamp then
        mc.mcSignalSetState(S.handles.clamp, 0)
        S.lastOutputs.clamp = 0
        return true
    end
    return false
end

function ToolLib.isToolPresent(inst)
    if S.handles.toolPresent then
        return mc.mcSignalGetState(S.handles.toolPresent) == 1
    end
    return false
end

-- ============================================
-- HEIGHT OFFSET MANAGEMENT
-- ============================================
function ToolLib.syncHeightOffset(inst, toolNum)
    local currentH = mc.mcCntlGetPoundVar(inst, 4120)
    local compMode = mc.mcCntlGetPoundVar(inst, 4008)
    
    -- Cancel current offset
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    
    -- Apply new offset if tool > 0
    if toolNum > 0 and toolNum < 90 then
        mc.mcCntlGcodeExecuteWait(inst, string.format("G43 H%d", toolNum))
        pushLog(string.format("H offset synced to T%d", toolNum))
    end
    
    return true
end

-- ============================================
-- STATE QUERIES
-- ============================================
function ToolLib.isActive(inst)
    return getPV(inst, PV.VIRTUAL_TOOL, 0) >= 90
end

function ToolLib.getActiveTool(inst)
    return getPV(inst, PV.VIRTUAL_TOOL, 0)
end

function ToolLib.isDeployed(inst, toolNum)
    return getPV(inst, PV.VIRTUAL_TOOL, 0) == toolNum
end

-- ============================================
-- RECOVERY
-- ============================================
function ToolLib.recover(inst)
    if not S.init then ToolLib.init(inst) end
    
    local virtualTool = getPV(inst, PV.VIRTUAL_TOOL, 0)
    
    if virtualTool >= 90 and virtualTool <= 99 then
        pushLog(string.format("Recovering from virtual T%d", virtualTool))
        
        -- Force outputs off
        if S.handles.probe then
            mc.mcSignalSetState(S.handles.probe, 0)
        end
        if S.handles.laser then
            mc.mcSignalSetState(S.handles.laser, 0)
        end
        
        -- Get stored deltas for possible restoration
        local xDelta = getPV(inst, PV.X_DELTA, 0)
        local yDelta = getPV(inst, PV.Y_DELTA, 0)
        
        -- Try to restore work offsets if deltas are valid
        if xDelta > -1e300 and yDelta > -1e300 and math.abs(xDelta) < MAX_OFFSET and math.abs(yDelta) < MAX_OFFSET then
            -- POUND VARIABLE METHOD: Attempt to restore work offsets
            for i = 0, 5 do
                local baseVar = 5221 + (i * 20)  -- G54=#5221, G55=#5241, etc.
                local currentX = getPV(inst, baseVar, 0)
                local currentY = getPV(inst, baseVar + 1, 0)
                
                if currentX and currentY and currentX > -1e300 and currentY > -1e300 then
                    if math.abs(currentX) < 1000 and math.abs(currentY) < 1000 then
                        -- Restore offset: add back to work coordinates
                        setPV(inst, baseVar, currentX + xDelta)
                        setPV(inst, baseVar + 1, currentY + yDelta)
                    end
                end
            end
            pushLog("Work offsets restored during recovery")
        else
            pushLog("WARNING: Cannot restore work offsets - deltas invalid or corrupted")
        end
        
        -- Clear G68 if it was being managed
        if getPV(inst, PV.G68_NEEDS_RESTORE, 0) == 1 then
            mc.mcCntlGcodeExecuteWait(inst, "G69")
            setPV(inst, PV.G68_NEEDS_RESTORE, 0)
            pushLog("G68 cleared during recovery")
        end
        
        -- Clear state
        setPV(inst, PV.VIRTUAL_TOOL, 0)
        setPV(inst, PV.X_DELTA, 0)
        setPV(inst, PV.Y_DELTA, 0)
        
        mc.mcToolSetCurrent(inst, 0)
        mc.mcCntlGcodeExecuteWait(inst, "G49")
        
        return true, "Virtual tool cleared, work offsets restored if possible"
    end
    
    return false, "No recovery needed"
end

-- ============================================
-- EMERGENCY STOP
-- ============================================
function ToolLib.emergencyStop(inst)
    -- Turn off all outputs immediately
    if S.handles.probe then
        mc.mcSignalSetState(S.handles.probe, 0)
    end
    if S.handles.laser then
        mc.mcSignalSetState(S.handles.laser, 0)
    end
    if S.handles.clamp then
        mc.mcSignalSetState(S.handles.clamp, 0)
    end
    
    pushLog("Emergency stop executed")
end

-- ============================================
-- DIRECT HARDWARE CONTROL
-- ============================================
-- Toggle virtual tool hardware output directly
-- This provides immediate control without waiting for PLC update cycle
-- Parameters:
--   inst: Mach4 instance  
--   toolNum: Virtual tool number (90-99)
--   state: true=on, false=off, nil=toggle current state
-- Returns:
--   success: true if operation succeeded
--   newState: true if output is now on, false if off
--   errorMsg: Error message if failed
function ToolLib.setHardware(inst, toolNum, state)
    -- Initialize if needed
    if not S.init then ToolLib.init(inst) end
    
    -- Map virtual tool numbers to output constants
    local outputMap = {
        [90] = OUTPUT.PROBE,    -- Probe uses OUTPUT7
        [91] = OUTPUT.LASER,    -- Laser uses OUTPUT1
        -- Add more mappings as needed for other virtual tools
    }
    
    local output = outputMap[toolNum]
    if not output then 
        return false, nil, string.format("Tool T%d is not a virtual tool", toolNum)
    end
    
    -- Get the appropriate handle
    local handle
    local cacheKey
    
    if output == OUTPUT.PROBE then
        handle = S.handles.probe or getHandle(inst, OUTPUT.PROBE)
        cacheKey = "probe"
    elseif output == OUTPUT.LASER then
        handle = S.handles.laser or getHandle(inst, OUTPUT.LASER)
        cacheKey = "laser"
    end
    
    if not handle or handle <= 0 then
        return false, nil, string.format("No handle for T%d output signal", toolNum)
    end
    
    -- Get current state
    local currentState = mc.mcSignalGetState(handle) == 1
    
    -- Determine target state
    local targetState
    if state == nil then
        -- Toggle mode
        targetState = not currentState
    else
        -- Explicit on/off
        targetState = state
    end
    
    -- Set the hardware state
    mc.mcSignalSetState(handle, targetState and 1 or 0)
    
    -- Update cached state to prevent PLC from fighting us
    if cacheKey then
        S.lastOutputs[cacheKey] = targetState and 1 or 0
    end
    
    -- Log the change
    pushLog(string.format("T%d hardware %s (direct control)", 
                         toolNum, targetState and "ON" or "OFF"))
    
    -- Add settling time for mechanical movement if state changed
    if targetState ~= currentState then
        if toolNum == 90 then
            -- Probe needs time to physically deploy/retract
            wx.wxMilliSleep(500)
        elseif toolNum == 91 then
            -- Laser might need warmup time
            wx.wxMilliSleep(100)
        end
    end
    
    -- Verify state changed
    local newState = mc.mcSignalGetState(handle) == 1
    
    return true, newState
end

-- ============================================
-- G68 ROTATION STATE MANAGEMENT (STUB)
-- ============================================
-- TODO: Move this to SystemLib.lua when implementing full G68 support
-- These functions manage G68 rotation state when virtual tools are deployed/retracted
-- Virtual tools apply X/Y offsets that need to adjust the G68 rotation center

ToolLib.G68 = {
    -- Clear any stored G68 state tracking
    ClearState = function(inst)
        -- Clear G68 tracking variables (#440-443)
        mc.mcCntlSetPoundVar(inst, 440, 0)  -- G68_STORED_X
        mc.mcCntlSetPoundVar(inst, 441, 0)  -- G68_STORED_Y
        mc.mcCntlSetPoundVar(inst, 442, 0)  -- G68_STORED_R
        mc.mcCntlSetPoundVar(inst, 443, 0)  -- G68_NEEDS_RESTORE flag
    end,
    
    -- Store current G68 state before removing virtual tool offsets
    StoreState = function(inst, xDelta, yDelta)
        -- Check if G68 is active (pound var #4016 == 68 means G68 is active)
        local g68Active = mc.mcCntlGetPoundVar(inst, 4016)
        if g68Active ~= 68 then
            return false  -- G68 not active, no adjustment needed
        end
        
        -- Store current G68 center and rotation
        local currentX = mc.mcCntlGetPoundVar(inst, 1245)  -- G68 X center
        local currentY = mc.mcCntlGetPoundVar(inst, 1246)  -- G68 Y center
        local currentR = mc.mcCntlGetPoundVar(inst, 1247)  -- G68 rotation angle
        
        -- Store these values for later restoration
        mc.mcCntlSetPoundVar(inst, 440, currentX)  -- Store original X
        mc.mcCntlSetPoundVar(inst, 441, currentY)  -- Store original Y
        mc.mcCntlSetPoundVar(inst, 442, currentR)  -- Store rotation
        mc.mcCntlSetPoundVar(inst, 443, 1)         -- Set restore flag
        
        -- Return true to indicate G68 adjustment will be needed
        return true
    end,
    
    -- Restore original G68 state after virtual tool offsets removed
    RestoreState = function(inst)
        -- Check if G68 restoration is needed
        local needsRestore = mc.mcCntlGetPoundVar(inst, 443)
        if needsRestore ~= 1 then
            return  -- No restoration needed
        end
        
        -- Get stored G68 state
        local storedX = mc.mcCntlGetPoundVar(inst, 440)  -- Original X center
        local storedY = mc.mcCntlGetPoundVar(inst, 441)  -- Original Y center
        local storedR = mc.mcCntlGetPoundVar(inst, 442)  -- Original rotation
        
        -- Restore the original G68 center and rotation
        mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", 
            storedX, storedY, storedR))
        
        -- Clear the restoration flag
        mc.mcCntlSetPoundVar(inst, 443, 0)
    end,
    
    -- Get current G68 state (helper function for debugging)
    GetState = function(inst)
        return {
            active = mc.mcCntlGetPoundVar(inst, 4016) == 68,
            currentX = mc.mcCntlGetPoundVar(inst, 1245),
            currentY = mc.mcCntlGetPoundVar(inst, 1246),
            currentR = mc.mcCntlGetPoundVar(inst, 1247),
            storedX = mc.mcCntlGetPoundVar(inst, 440),
            storedY = mc.mcCntlGetPoundVar(inst, 441),
            storedR = mc.mcCntlGetPoundVar(inst, 442),
            needsRestore = mc.mcCntlGetPoundVar(inst, 443) == 1
        }
    end
}

return ToolLib