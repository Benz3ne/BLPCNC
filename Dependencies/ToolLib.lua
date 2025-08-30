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
    if g68Active and SystemLib and SystemLib.G68 then
        -- Store current G68 state before applying offset
        local currentX = getPV(inst, 1245, 0)  -- G68 X center
        local currentY = getPV(inst, 1246, 0)  -- G68 Y center
        local currentR = getPV(inst, 1247, 0)  -- G68 rotation
        
        setPV(inst, PV.G68_STORED_X, currentX)
        setPV(inst, PV.G68_STORED_Y, currentY)
        setPV(inst, PV.G68_STORED_R, currentR)
        setPV(inst, PV.G68_NEEDS_RESTORE, 1)
        
        -- Cancel G68 temporarily
        mc.mcCntlGcodeExecuteWait(inst, "G69")
        
        -- Apply G52 offset
        mc.mcCntlGcodeExecuteWait(inst, string.format("G52 X%.4f Y%.4f", -xOffset, -yOffset))
        
        -- Reapply G68 with adjusted center
        mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", 
            currentX - xOffset, currentY - yOffset, currentR))
        
        pushLog(string.format("G68 adjusted for virtual tool: X%.4f Y%.4f", 
            currentX - xOffset, currentY - yOffset))
    else
        -- No rotation active, just apply G52
        mc.mcCntlGcodeExecuteWait(inst, string.format("G52 X%.4f Y%.4f", -xOffset, -yOffset))
    end
    
    -- Store state
    setPV(inst, PV.VIRTUAL_TOOL, toolNum)
    setPV(inst, PV.X_DELTA, xOffset)
    setPV(inst, PV.Y_DELTA, yOffset)
    
    -- Set current tool
    mc.mcToolSetCurrent(inst, toolNum)
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    mc.mcCntlGcodeExecuteWait(inst, string.format("G43 H%d", toolNum))
    
    pushLog(string.format("Deployed virtual T%d (%s) with G52 offset", toolNum, config.name))
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
    
    -- Clear G52 offset
    mc.mcCntlGcodeExecuteWait(inst, "G52 X0 Y0")
    
    -- Handle G68 restoration if it was active
    if getPV(inst, PV.G68_NEEDS_RESTORE, 0) == 1 then
        local storedX = getPV(inst, PV.G68_STORED_X, 0)
        local storedY = getPV(inst, PV.G68_STORED_Y, 0)
        local storedR = getPV(inst, PV.G68_STORED_R, 0)
        
        -- Cancel current G68
        mc.mcCntlGcodeExecuteWait(inst, "G69")
        
        -- Restore original G68
        mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", 
            storedX, storedY, storedR))
        
        -- Clear restoration flag
        setPV(inst, PV.G68_NEEDS_RESTORE, 0)
        
        pushLog(string.format("G68 restored: X%.4f Y%.4f R%.4f", storedX, storedY, storedR))
    end
    
    -- Clear state
    setPV(inst, PV.VIRTUAL_TOOL, 0)
    setPV(inst, PV.X_DELTA, 0)
    setPV(inst, PV.Y_DELTA, 0)
    
    -- Set tool to 0
    mc.mcToolSetCurrent(inst, 0)
    mc.mcCntlGcodeExecuteWait(inst, "G49")
    
    pushLog(string.format("Retracted virtual T%d, G52 cleared", current))
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
        
        -- Clear G52 offset
        mc.mcCntlGcodeExecuteWait(inst, "G52 X0 Y0")
        
        -- Clear G68 if it was being managed
        if getPV(inst, PV.G68_NEEDS_RESTORE, 0) == 1 then
            mc.mcCntlGcodeExecuteWait(inst, "G69")
            setPV(inst, PV.G68_NEEDS_RESTORE, 0)
        end
        
        -- Clear state
        setPV(inst, PV.VIRTUAL_TOOL, 0)
        setPV(inst, PV.X_DELTA, 0)
        setPV(inst, PV.Y_DELTA, 0)
        
        mc.mcToolSetCurrent(inst, 0)
        mc.mcCntlGcodeExecuteWait(inst, "G49")
        
        return true, "Virtual tool cleared, G52 reset"
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
-- G68 ROTATION STATE MANAGEMENT (STUB)
-- ============================================
-- TODO: Move this to SystemLib.lua when implementing full G68 support
-- These functions manage G68 rotation state when virtual tools are deployed/retracted
-- Virtual tools apply X/Y offsets that need to adjust the G68 rotation center

ToolLib.G68 = {
    -- Clear any stored G68 state tracking
    ClearState = function(inst)
        -- TODO: Clear G68 tracking variables
        -- Should reset #440-443 (G68_STORED_X/Y/R and G68_NEEDS_RESTORE)
        -- This is called when starting fresh with a virtual tool
    end,
    
    -- Store current G68 state before removing virtual tool offsets
    StoreState = function(inst, xDelta, yDelta)
        -- TODO: Implementation needed
        -- 1. Check if G68 is active (pound var #4016 == 68)
        -- 2. If active, store current G68 center (vars #1245, #1246) and rotation (#1247)
        -- 3. Calculate how the center needs to adjust when offsets are removed
        -- 4. Store this info in pound vars #440-443
        -- 5. Return true if G68 adjustment will be needed
        return false  -- For now, indicate no adjustment needed
    end,
    
    -- Restore original G68 state after virtual tool offsets removed
    RestoreState = function(inst)
        -- TODO: Implementation needed
        -- 1. Check if G68 restoration is needed (pound var #443)
        -- 2. If needed, restore the original G68 center and rotation from #440-442
        -- 3. This maintains the rotation point relative to the workpiece
        -- 4. Clear the restoration flag
    end
}

return ToolLib