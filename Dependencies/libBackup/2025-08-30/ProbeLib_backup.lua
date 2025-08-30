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
-- CONSTANTS - All pound variables and settings
-- ============================================
ProbeLib.CONSTANTS = {
    -- Hardware configuration
    PROBE_TOOL = 90,
    PROBE_OUTPUT = mc.OSIG_OUTPUT7,
    PROBE_SIGNAL = mc.ISIG_PROBE1,
    
    -- Probe configuration parameters (#300-305)
    VAR_TIP_DIAMETER = 300,     -- Probe tip diameter
    VAR_X_OFFSET = 301,         -- X offset: spindle to probe
    VAR_Y_OFFSET = 302,         -- Y offset: spindle to probe  
    VAR_FAST_FEED = 303,        -- Fast probe feedrate
    VAR_SLOW_FEED = 304,        -- Slow probe feedrate
    VAR_MAX_TRAVEL = 305,       -- Maximum probe travel
    
    -- Probe calibration (#320-321)
    VAR_Z_OFFSET = 320,         -- Z offset for calibration
    VAR_LIFT_HEIGHT = 321,      -- Probe lift height
    
    -- M311 sentinel mode (#388)
    VAR_SENTINEL_FLAG = 388,    -- 0=normal, 1=sentinel active
    SENTINEL_VALUE = -999999.0, -- Impossible value for miss detection
    
    -- M311 result variables (#389-394)
    VAR_RESULT_X_PLUS = 389,    -- +X probe result (machine)
    VAR_RESULT_X_MINUS = 390,   -- -X probe result (machine)
    VAR_RESULT_Y_PLUS = 391,    -- +Y probe result (machine)
    VAR_RESULT_Y_MINUS = 392,   -- -Y probe result (machine)
    VAR_RESULT_Z_PLUS = 393,    -- +Z probe result (machine)
    VAR_RESULT_Z_MINUS = 394,   -- -Z probe result (machine)
    
    -- Work offset variables (computed from modal)
    VAR_WORK_OFFSET_MODE = 4014, -- Current G54-G59 (54-59)
    
    -- G68 rotation state
    VAR_G68_MODE = 4016,        -- 68 if G68 active
    VAR_G68_X = 1245,           -- G68 X center
    VAR_G68_Y = 1246,           -- G68 Y center
    VAR_G68_R = 1247,           -- G68 rotation angle
    
    -- State storage for probe operations (#395-399, #440-445)
    VAR_RUNTIME_1 = 395,        -- Runtime state storage
    VAR_RUNTIME_2 = 396,
    VAR_RUNTIME_3 = 397,
    VAR_G68_STORED_X = 440,     -- Stored G68 X
    VAR_G68_STORED_Y = 441,     -- Stored G68 Y
    VAR_G68_STORED_R = 442,     -- Stored G68 rotation
    VAR_G68_NEEDS_RESTORE = 443,-- 1=needs restore
    
    -- Legacy compatibility (remove these in future versions)
    SENTINEL_FLAG_VAR = 388,
    SENTINEL_VARS = {389, 390, 391, 392, 394},
    
    -- Tolerances
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

-- Get and validate all probe parameters with strict validation
-- Throws error on invalid values to prevent probe crashes
-- Returns table with all parameters using descriptive names
function ProbeLib.Core.GetProbeParameters(inst)
    local params = {}
    
    -- Define all probe parameters with validation rules
    -- Each entry: pound var number, internal name, min value, max value, description
    local definitions = {
        {var=300, name="tipDiameter", min=0.001, max=1.0, desc="Probe tip diameter"},
        {var=301, name="xOffset", min=-10, max=10, desc="X offset from spindle to probe"},
        {var=302, name="yOffset", min=-10, max=10, desc="Y offset from spindle to probe"},
        {var=303, name="fastFeed", min=0.1, max=500, desc="Fast probe feedrate"},
        {var=304, name="slowFeed", min=0.1, max=100, desc="Slow probe feedrate"},
        {var=305, name="maxTravel", min=0.01, max=10, desc="Maximum probe travel"},
        {var=320, name="zOffset", min=-10, max=10, desc="Z offset for calibration"},
        {var=321, name="liftHeight", min=0.01, max=5, desc="Probe lift height"}
    }
    
    -- Validate each parameter
    for _, def in ipairs(definitions) do
        local value = mc.mcCntlGetPoundVar(inst, def.var)
        
        -- Check if pound var is uninitialized (Mach4 returns huge negative for unset vars)
        if type(value) ~= "number" or value < -1e300 then
            error(string.format("Probe parameter #%d (%s) not initialized", 
                def.var, def.desc))
        end
        
        -- Validate range
        if value < def.min or value > def.max then
            error(string.format("Invalid #%d (%s): %.4f - must be %.3f to %.3f", 
                def.var, def.desc, value, def.min, def.max))
        end
        
        params[def.name] = value
    end
    
    -- Add computed parameters for convenience
    params.probeRadius = params.tipDiameter / 2.0
    
    return params
end

-- Capture complete machine state for probe operations
-- Returns both machine and work coordinates for all axes
-- Machine coords used for G53 movements, work coords for display/logging
function ProbeLib.Core.CaptureState(inst)
    local state = {
        -- Machine coordinates (for G53 absolute positioning)
        machine = {
            x = mc.mcAxisGetMachinePos(inst, mc.X_AXIS),
            y = mc.mcAxisGetMachinePos(inst, mc.Y_AXIS),
            z = mc.mcAxisGetMachinePos(inst, mc.Z_AXIS),
            a = mc.mcAxisGetMachinePos(inst, mc.A_AXIS),
            b = mc.mcAxisGetMachinePos(inst, mc.B_AXIS),
            c = mc.mcAxisGetMachinePos(inst, mc.C_AXIS)
        },
        
        -- Work coordinates (for display and logging)
        work = {
            x = mc.mcAxisGetPos(inst, mc.X_AXIS),
            y = mc.mcAxisGetPos(inst, mc.Y_AXIS),
            z = mc.mcAxisGetPos(inst, mc.Z_AXIS),
            a = mc.mcAxisGetPos(inst, mc.A_AXIS),
            b = mc.mcAxisGetPos(inst, mc.B_AXIS),
            c = mc.mcAxisGetPos(inst, mc.C_AXIS)
        },
        
        -- Current work offset (G54-G59)
        workOffset = mc.mcCntlGetPoundVar(inst, 4014) or 54,
        
        -- Current tool
        currentTool = mc.mcToolGetCurrent(inst),
        
        -- Timestamp for logging
        timestamp = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    -- Validate critical values aren't nil
    if not state.machine.x or not state.machine.y or not state.machine.z then
        error("Failed to capture machine position - check controller connection")
    end
    
    return state
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

-- Apply datum or print coordinates based on action mode (moved from Results)
function ProbeLib.Core.ApplyOrPrint(inst, actionMode, coords, p_index)
    if actionMode == 1 then
        local g10 = ProbeLib.GCode.SetWorkOffset(coords, p_index)
        if g10 then mc.mcCntlGcodeExecuteWait(inst, g10) end
        mc.mcCntlSetLastError(inst, "Datum updated")
    else
        local fmt = function(v) return (v and string.format("%.4f", v)) or "—" end
        mc.mcCntlSetLastError(inst, string.format("Coords: X%s Y%s Z%s", 
            fmt(coords.x), fmt(coords.y), fmt(coords.z)))
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

-- Helper function to check if soft limits are enabled
local function _softEnabled(inst, axis)
    local en = mc.mcSoftLimitGetState(inst, axis)
    return (en == 1)
end

-- Get maximum safe travel distance considering soft limits
function ProbeLib.Movement.GetMaxSafeTravel(inst, axis, direction, buffer)
    buffer = buffer or ProbeLib.CONSTANTS.SOFT_LIMIT_BUFFER
    if not _softEnabled(inst, axis) then
        return math.huge -- soft-limits off: do not constrain here
    end
    local minv, rc1 = mc.mcAxisGetSoftlimitMin(inst, axis)
    local maxv, rc2 = mc.mcAxisGetSoftlimitMax(inst, axis)
    if rc1 ~= mc.MERROR_NOERROR or rc2 ~= mc.MERROR_NOERROR then
        return math.huge
    end
    local cur = mc.mcAxisGetMachinePos(inst, axis)
    if direction > 0 then
        return math.max(0, (maxv - buffer) - cur)
    else
        return math.max(0, cur - (minv + buffer))
    end
end

-- Validate if probe travel is within soft limits
-- Returns ok, allowedTravel
function ProbeLib.Movement.ValidateProbeTravel(inst, axis, direction, requested)
    local avail = ProbeLib.Movement.GetMaxSafeTravel(inst, axis, direction)
    if avail == math.huge or avail >= requested then
        return true, requested
    end
    return false, avail
end

-- Calculate smart retreat distance for retry/iteration
function ProbeLib.Movement.SmartRetreatSlice(probeMaxTravel, remaining)
    local slice = (probeMaxTravel >= 1.0) and 1.0 or (probeMaxTravel * 0.9)
    return math.min(slice, remaining)
end


-- Execute just the M311 macro with given direction
-- Returns success and raw pound var values
function ProbeLib.Movement.ExecuteM311(inst, direction)
    -- Validate direction
    if direction < 1 or direction > 6 then
        return false, nil, "Invalid probe direction"
    end
    
    -- Execute the probe macro
    local gcode = string.format("M311 S%d", direction)
    local rc = mc.mcCntlGcodeExecuteWait(inst, gcode)
    
    -- Let M311 handle its own timing
    wx.wxMilliSleep(ProbeLib.CONSTANTS.PROBE_SETTLE_MS)
    
    return rc == mc.MERROR_NOERROR, rc
end

-- Check if probe made contact based on sentinel value
-- varNum: pound variable to check (389-394 depending on direction)
function ProbeLib.Movement.CheckProbeHit(inst, varNum)
    local value = mc.mcCntlGetPoundVar(inst, varNum)
    
    -- Check against sentinel to detect probe miss
    if value == ProbeLib.CONSTANTS.SENTINEL_VALUE then
        return false, nil
    end
    
    -- Validate the value is reasonable
    if type(value) ~= "number" or value < -1e300 then
        return false, nil
    end
    
    return true, value
end

-- Get probe results from pound variables
-- Returns work position and machine position
function ProbeLib.Movement.GetProbeResult(inst, direction)
    -- Map direction to result variables
    -- Each direction uses its specific pound variable for machine position
    local varMap = {
        [1] = {machine=389, work=391},  -- +X uses #389
        [2] = {machine=390, work=391},  -- -X uses #390
        [3] = {machine=391, work=391},  -- +Y uses #391
        [4] = {machine=392, work=391},  -- -Y uses #392
        [5] = {machine=394, work=391},  -- -Z uses #394
        [6] = {machine=393, work=391}   -- +Z uses #393
    }
    
    local vars = varMap[direction]
    if not vars then
        return nil, nil, "Invalid direction"
    end
    
    local machinePos = mc.mcCntlGetPoundVar(inst, vars.machine)
    local workPos = mc.mcCntlGetPoundVar(inst, vars.work)
    
    return workPos, machinePos, nil
end

-- High-level probe execution (compatibility wrapper)
-- Maintains original ExecuteProbe interface for existing scripts
function ProbeLib.Movement.ExecuteProbe(inst, direction, label)
    label = label or "probe"
    
    -- Enable sentinel mode
    ProbeLib.Movement.EnableSentinel(inst)
    
    -- Execute M311
    local success, rc = ProbeLib.Movement.ExecuteM311(inst, direction)
    if not success then
        ProbeLib.Movement.DisableSentinel(inst)
        return false, nil, nil
    end
    
    -- Check for hit (direction determines which var to check)
    local varNum = ({389, 390, 391, 392, 394, 393})[direction]
    local hit, value = ProbeLib.Movement.CheckProbeHit(inst, varNum)
    
    if hit then
        -- Get full results
        local workPos, machinePos = ProbeLib.Movement.GetProbeResult(inst, direction)
        ProbeLib.Movement.DisableSentinel(inst)
        return true, workPos, machinePos
    else
        ProbeLib.Movement.DisableSentinel(inst)
        return false, nil, nil
    end
end

-- ============================================
-- SAFETY MODULE - Safety checks
-- ============================================
ProbeLib.Safety = {}

-- Check if position is within soft limits using correct API
-- axis: 0=X, 1=Y, 2=Z
-- position: machine coordinate to check
function ProbeLib.Safety.CheckSoftLimits(inst, axis, position)
    -- Check if soft limits are enabled for this axis
    if mc.mcSoftLimitGetState(inst, axis) ~= 1 then
        return true  -- Soft limits off, allow movement
    end
    
    -- Get actual soft limit values from API
    local min, minRc = mc.mcAxisGetSoftlimitMin(inst, axis)
    local max, maxRc = mc.mcAxisGetSoftlimitMax(inst, axis)
    
    -- Validate we got good values
    if minRc ~= mc.MERROR_NOERROR or maxRc ~= mc.MERROR_NOERROR then
        -- Can't get limits, be conservative
        return false, "Cannot read soft limits"
    end
    
    -- Check with safety buffer
    local buffer = ProbeLib.CONSTANTS.SOFT_LIMIT_BUFFER
    return position >= (min + buffer) and position <= (max - buffer)
end

-- Validate travel distance is reasonable
function ProbeLib.Safety.ValidateTravel(distance, maxAllowed)
    maxAllowed = maxAllowed or 10.0
    return math.abs(distance) <= maxAllowed
end

-- Check for coordinate rotation (G68) and handle according to policy
-- policy: "warn" (default) | "cancel" (G69) | "deny" | "ignore"
function ProbeLib.Safety.CheckRotation(inst, policy, prompt)
    policy = policy or "warn"
    local modal = tonumber(mc.mcCntlGetPoundVar(inst, 4016)) -- modal group code
    local g68   = tonumber(mc.mcCntlGetPoundVar(inst, 318))  -- rotation deg
    local active = (modal == 68) or (g68 and g68 ~= 0)
    if not active then return true end

    if policy == "ignore" then return true end
    if policy == "cancel" then mc.mcCntlGcodeExecuteWait(inst, "G69"); return true end
    local msg = prompt or "Coordinate rotation (G68) is active. Continue?"
    if policy == "deny" then
        wx.wxMessageBox(msg .. "\n\nProbing blocked by policy.", "Rotation Active", wx.wxOK + wx.wxICON_WARNING)
        return false
    end
    local res = wx.wxMessageBox(msg, "Rotation Active", wx.wxYES_NO + wx.wxICON_WARNING)
    return res == wx.wxYES
end

-- Emit rotation banner if rotation is active
function ProbeLib.Safety.EmitRotationBanner(inst)
    local modal = tonumber(mc.mcCntlGetPoundVar(inst, 4016))
    local g68   = tonumber(mc.mcCntlGetPoundVar(inst, 318))
    local active = (modal == 68) or (g68 and g68 ~= 0)
    if active then mc.mcCntlSetLastError(inst, "[Notice] Proceeding with rotation active (G68).") end
end

-- Ensure probe is not already triggered (moved from Precheck)
function ProbeLib.Safety.EnsureProbeNotTripped(inst)
    if not ProbeLib.Core.IsProbeTriggered(inst) then
        return true
    end
    
    -- Try to clear latch
    mc.mcCntlGcodeExecuteWait(inst, "G31.2")
    wx.wxMilliSleep(50)
    
    -- Check again
    if ProbeLib.Core.IsProbeTriggered(inst) then
        wx.wxMessageBox("Probe input is already active. Check for mechanical contact.", 
                       "Probe Stuck", wx.wxOK + wx.wxICON_WARNING)
        return false
    end
    return true
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
-- LOGGING MODULE - Event logging to CSV
-- ============================================
ProbeLib.Logging = {}


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
-- UI MODULE - UI utilities
-- ============================================
ProbeLib.UI = {}

-- Generate datum summary text based on action mode and axes
function ProbeLib.UI.DatumSummary(actionMode, axes)
    local list = {}
    if axes.x then list[#list+1] = "X" end
    if axes.y then list[#list+1] = "Y" end
    if axes.z then list[#list+1] = "Z" end
    local ax = (#list > 0) and table.concat(list, " ") or "(none)"
    return (actionMode == 1) and ("Datum will be set: " .. ax)
                             or  ("Will print work coords: " .. ax)
end

-- ============================================
-- GCODE MODULE - G-code generation utilities
-- ============================================
ProbeLib.GCode = {}

-- Build a single G10 L20 Pn with provided coords table {x=?,y=?,z=?}
function ProbeLib.GCode.SetWorkOffset(coords, p_index)
    if not coords then return nil end
    local terms = {}
    if coords.x then terms[#terms+1] = string.format("X%.4f", coords.x) end
    if coords.y then terms[#terms+1] = string.format("Y%.4f", coords.y) end
    if coords.z then terms[#terms+1] = string.format("Z%.4f", coords.z) end
    if #terms == 0 then return nil end
    local p = tonumber(p_index) or 0 -- P0=current active WCS
    return string.format("G10 L20 P%d %s", p, table.concat(terms, " "))
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
-- ERROR MODULE - Comprehensive error handling
-- ============================================
ProbeLib.Error = {}

-- Execute function with full error handling and cleanup
-- inst: Mach4 instance (required for error messages)
-- func: function to execute
-- cleanup: optional cleanup function(success, error)
-- Returns: success, result or error message
function ProbeLib.Error.SafeExecute(inst, func, cleanup, ...)
    -- Capture arguments for func
    local args = {...}
    
    -- Execute with protected call
    local success, result = xpcall(
        function() return func(table.unpack(args)) end,
        debug.traceback  -- Capture full stack trace
    )
    
    -- Always run cleanup if provided
    if cleanup then
        local cleanupOk = pcall(cleanup, success, result)
        if not cleanupOk then
            mc.mcCntlSetLastError(inst, "WARNING: Cleanup failed")
        end
    end
    
    return success, result
end

-- Format probe-specific error messages
function ProbeLib.Error.FormatProbeError(errorType, details)
    local messages = {
        miss = "Probe did not make contact within travel distance",
        stuck = "Probe is stuck triggered - check for mechanical contact",
        soft_limit = "Movement would exceed soft limits",
        invalid_measurement = "Invalid measurement detected",
        config = "Probe configuration error - check pound variables"
    }
    
    local base = messages[errorType] or "Unknown probe error"
    if details then
        return string.format("%s\n%s", base, details)
    end
    return base
end

-- ============================================
-- CLEANUP MODULE - Standard cleanup
-- ============================================
ProbeLib.Cleanup = {}

-- Complete cleanup contract for probe operations
-- Clears sentinel state and resets runtime probe pound vars (no motion on failure)
function ProbeLib.Cleanup.Standard(inst, wasSuccess, msg)
    -- Always clear probe sentinel enable, if used by your macros
    pcall(function() mc.mcCntlSetPoundVar(inst, 388, 0) end)
    
    -- Clear runtime result vars often used by M311-based flows
    local S = ProbeLib.CONSTANTS.SENTINEL_VALUE
    local safeSet = function(n) 
        pcall(function() mc.mcCntlSetPoundVar(inst, n, S) end) 
    end
    
    -- Common result vars seen in scripts/macros (#389..#392, #394)
    for _, n in ipairs({389, 390, 391, 392, 394}) do 
        safeSet(n) 
    end

    -- Ensure we're in absolute mode
    mc.mcCntlGcodeExecuteWait(inst, "G90")
    
    -- Handle messages
    if msg and msg ~= "" then
        if wasSuccess then 
            mc.mcCntlSetLastError(inst, msg) 
        else 
            wx.wxMessageBox(msg, "Probe", wx.wxOK + wx.wxICON_WARNING) 
        end
    elseif wasSuccess then
        mc.mcCntlSetLastError(inst, "Probe complete")
    end
    
    -- Ensure sentinel is disabled
    ProbeLib.Movement.DisableSentinel(inst)
end

-- ============================================
-- G68 MODULE - Probe-specific rotation handling
-- ============================================
ProbeLib.G68 = {}

-- Store G68 state when probe tool is activated
-- Called before applying probe offsets
function ProbeLib.G68.StoreState(inst)
    -- Check if G68 is currently active
    local modalGroup = mc.mcCntlGetPoundVar(inst, 4016)
    if modalGroup ~= 68 then
        return false  -- No rotation active
    end
    
    -- Get current G68 parameters
    local currentX = mc.mcCntlGetPoundVar(inst, 1245)  -- G68 X center
    local currentY = mc.mcCntlGetPoundVar(inst, 1246)  -- G68 Y center  
    local currentR = mc.mcCntlGetPoundVar(inst, 1247)  -- G68 rotation angle
    
    -- Store in #440-443 for later restoration
    mc.mcCntlSetPoundVar(inst, 440, currentX)
    mc.mcCntlSetPoundVar(inst, 441, currentY)
    mc.mcCntlSetPoundVar(inst, 442, currentR)
    mc.mcCntlSetPoundVar(inst, 443, 1)  -- Flag: rotation needs restore
    
    return true
end

-- Restore G68 after probe tool deactivation
function ProbeLib.G68.RestoreState(inst)
    -- Check if we need to restore
    if mc.mcCntlGetPoundVar(inst, 443) ~= 1 then
        return false
    end
    
    -- Retrieve stored parameters
    local x = mc.mcCntlGetPoundVar(inst, 440)
    local y = mc.mcCntlGetPoundVar(inst, 441)
    local r = mc.mcCntlGetPoundVar(inst, 442)
    
    -- Reapply G68
    mc.mcCntlGcodeExecuteWait(inst, string.format("G68 X%.4f Y%.4f R%.4f", x, y, r))
    
    -- Clear flag
    mc.mcCntlSetPoundVar(inst, 443, 0)
    
    return true
end

-- Clear stored G68 state (error recovery)
function ProbeLib.G68.ClearState(inst)
    mc.mcCntlSetPoundVar(inst, 443, 0)
end

-- ============================================
-- Return the library
-- ============================================
return ProbeLib