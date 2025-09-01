-- DustLib.lua Final v1
-- Unified control for Dust Collector (OUTPUT4), Dust Boot (OUTPUT3), and Vacuum Pumps (OUTPUT5/6)
-- 
-- CRITICAL DESIGN RULE:
-- This library is the SOLE OWNER of OUTPUT3 (dust boot) and OUTPUT4 (dust collector).
-- NO OTHER CODE may write to these outputs directly.
--
-- Control flow:
-- 1. All functions modify state variables (#403-#410) only
-- 2. update() reads state variables and writes outputs
-- 3. update() is called every PLC cycle (~10ms)
--
-- Maximum latency from state change to output: 10ms
--
-- Public API:
--   dustLib.init(inst?)
--   dustLib.update(inst?)
--   dustLib.toggleDustAuto(inst?, onOff)
--   dustLib.toggleBootAuto(inst?, onOff)
--   dustLib.manualToggleDust(inst?)
--   dustLib.manualToggleBoot(inst?)
--   dustLib.clearOverrides(inst?)              -- optional UI action
--   dustLib.endOfProgram(inst?)               -- M30 hook: Dust OFF if #400==1; Boot UP if #402==1; Vacs OFF if #401==1
--
-- Behavior (per spec):
--   Dust AUTO = spindle ON only; holds pre-M6 auto state during M6; AUTO muted during laser (T91) but manual allowed
--   Boot AUTO = DOWN with spindle; UP during M6, any virtual (>=90), or emergency/disable
--   Overrides (#405/#410) clear on spindle rising edge only
--   Vacuum pumps manual-only; endOfProgram() turns them OFF if #401==1; library does not change vacs during emergency/disable
--   Emergency/disable: Laser OFF, Boot UP, Dust unchanged
--   Startup: mirror #403/#404 from actual outputs; sentinel = -999999; 200-entry log ring

local dustLib = {}

-- Try to load SystemLib for laser shutoff
local SystemLib = nil
pcall(function() SystemLib = require("SystemLib") end)

-- =============================
-- Pound Variables (important)
-- =============================
local PV = {
  DustAuto     = 400,   -- 1:auto, 0:manual
  DustTarget   = 404,   -- 0/1 mirror of OUTPUT4
  BootAuto     = 402,   -- 1:auto, 0:manual
  BootTarget   = 403,   -- 0/1 mirror of OUTPUT3
  DustOverride = 405,   -- 1:manual overrides dust
  BootOverride = 410,   -- 1:manual overrides boot
  VacAutoM30   = 401,   -- 1:turn vacs OFF at M30
  VirtTool     = 406,   -- >=90 => virtual; 90:probe; 91:laser
  M6Flag       = 499,   -- 1 during tool change
}

-- IDs / constants
local TOOL  = { Probe = 90, Laser = 91 }
local STATE = { STOP=109, MHOLD=103, FHOLD=101, PHOLD=102 }
local SENT  = -999999

-- ================
-- Internal State
-- ================
local S = {
  init = false,
  h = {},                 -- signal handles
  lastSpindle = 0,        -- previous SPINDLEON state (for edge detect)
  latchedDustAuto = SENT, -- pre-M6 dust auto target latch
  lastDustTarget = -1,    -- last applied dust target (0/1)
  lastBootTarget = -1,    -- last applied boot target (0/1)
  log = {},               -- ring buffer (max 200)
  sw = nil,               -- stopwatch for monotonic timing
  lastMs = 0,             -- cached timestamp
}

-- ==========
-- Utilities
-- ==========
local function instOrGet(inst) return inst or mc.mcGetInstance() end

-- Persistent file logging for debugging
local function logToFile(msg)
  if not _G.PRODUCTION_MODE then  -- Only log in debug mode
    local inst = mc.mcGetInstance()
    local machDir = mc.mcCntlGetMachDir(inst)
    local dir = machDir .. "\\Logs\\"
    os.execute('mkdir "' .. dir .. '" 2>nul')  -- Create dir if needed
    
    local filename = dir .. "DustLib_" .. os.date("%Y%m%d") .. ".txt"
    local file = io.open(filename, "a")
    if file then
      file:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
      file:close()
    end
  end
end

local function pushLog(msg)
  local t = os.clock()
  S.log[#S.log+1] = string.format("[%.3f] %s", t, msg)
  if #S.log > 50 then table.remove(S.log, 1) end  -- Reduced from 200
  logToFile(msg)  -- Add persistent logging
end

-- Monotonic timebase (preferred)
local function ensureStopwatch()
  if wx and wx.wxStopWatch and not S.sw then
    S.sw = wx.wxStopWatch()
    pushLog("Stopwatch initialized")
  end
end

local function nowMs()
  -- Try stopwatch first (monotonic)
  if S.sw then
    return S.sw:Time()
  end
  -- Fallback to wx time
  if wx and wx.wxGetUTCTimeMillis then
    return wx.wxGetUTCTimeMillis()
  end
  -- Last resort
  return math.floor(os.clock()*1000)
end
local function getHandle(inst, code)
  local h = mc.mcSignalGetHandle(inst, code)
  if not h or h <= 0 then return nil end
  return h
end
local function revalidate(inst)
  local h = S.h
  if not h.spindleOn or h.spindleOn <= 0 then h.spindleOn = getHandle(inst, mc.OSIG_SPINDLEON) end
  if not h.boot      or h.boot      <= 0 then h.boot      = getHandle(inst, mc.OSIG_OUTPUT3)  end
  if not h.dust      or h.dust      <= 0 then h.dust      = getHandle(inst, mc.OSIG_OUTPUT4)  end
  if not h.vacRear   or h.vacRear   <= 0 then h.vacRear   = getHandle(inst, mc.OSIG_OUTPUT5)  end
  if not h.vacFront  or h.vacFront  <= 0 then h.vacFront  = getHandle(inst, mc.OSIG_OUTPUT6)  end
  if not h.machineEn or h.machineEn <= 0 then h.machineEn = getHandle(inst, mc.OSIG_MACHINE_ENABLED) end
  if not h.laser     or h.laser     <= 0 then h.laser     = getHandle(inst, mc.OSIG_OUTPUT1)  end
end
local function sigState(h) return (h and h>0) and mc.mcSignalGetState(h) or 0 end
local function setSig(h, v) if h and h>0 then mc.mcSignalSetState(h, v) end end
local function getVar(inst, n)
  local v = mc.mcCntlGetPoundVar(inst, n)
  if v < -1e300 then return SENT end
  return v
end
local function setVar(inst, n, v) mc.mcCntlSetPoundVar(inst, n, v) end
local function isEmergencyOrHold(state)
  return state==STATE.STOP or state==STATE.MHOLD or state==STATE.FHOLD or state==STATE.PHOLD
end

-- ======
-- init
-- ======
function dustLib.init(inst)
  inst = instOrGet(inst)
  if S.init then return end
  
  -- Initialize stopwatch for timing
  ensureStopwatch()
  
  S.h = {
    spindleOn = getHandle(inst, mc.OSIG_SPINDLEON),
    boot      = getHandle(inst, mc.OSIG_OUTPUT3),
    dust      = getHandle(inst, mc.OSIG_OUTPUT4),
    vacRear   = getHandle(inst, mc.OSIG_OUTPUT5),
    vacFront  = getHandle(inst, mc.OSIG_OUTPUT6),
    machineEn = getHandle(inst, mc.OSIG_MACHINE_ENABLED),
    laser     = getHandle(inst, mc.OSIG_OUTPUT1),
  }
  S.lastSpindle = sigState(S.h.spindleOn)

  -- Initialize pound vars if uninitialized
  for _,n in ipairs({PV.DustAuto,PV.DustTarget,PV.BootAuto,PV.BootTarget,PV.DustOverride,PV.BootOverride,PV.VacAutoM30,PV.VirtTool,PV.M6Flag}) do
    if getVar(inst,n) == SENT then setVar(inst,n,0) end
  end
  -- Seed pound-var mirrors from actual outputs so UI matches hardware on startup
  if S.h.dust then S.lastDustTarget = sigState(S.h.dust); setVar(inst, PV.DustTarget, S.lastDustTarget) end
  if S.h.boot then S.lastBootTarget = sigState(S.h.boot); setVar(inst, PV.BootTarget, S.lastBootTarget) end

  S.init = true
  pushLog("dustLib.init complete")
end

-- ==========
-- update (PLC)
-- ==========
function dustLib.update(inst)
  inst = instOrGet(inst)
  if not S.init then dustLib.init(inst) end
  revalidate(inst)

  local state    = mc.mcCntlGetState(inst)
  local m6       = (getVar(inst, PV.M6Flag) == 1)
  local virt     = getVar(inst, PV.VirtTool)
  local tool     = mc.mcToolGetCurrent(inst)
  local enabled  = (sigState(S.h.machineEn) == 1)
  local spindle  = sigState(S.h.spindleOn)
  local now      = nowMs()
  local inCycle  = mc.mcCntlIsInCycle(inst)

  -- Update cached timestamp
  S.lastMs = now

  -- Rising edge: clear overrides when spindle turns ON
  if spindle ~= S.lastSpindle then
    if spindle == 1 then
      setVar(inst, PV.DustOverride, 0)
      setVar(inst, PV.BootOverride, 0)
      pushLog("Spindle rising edge: cleared overrides")
    end
    S.lastSpindle = spindle
  end

  -- No boot delay - respond immediately to all state changes

  -- Emergency/Disable: Boot UP, Laser OFF, Dust UNCHANGED
  if isEmergencyOrHold(state) or not enabled then
    -- Set boot target UP (output written by update())
    setVar(inst, PV.BootTarget, 0)
    
    -- Emergency laser ESS shutoff
    if SystemLib and SystemLib.Laser then
        if SystemLib.Laser.EmergencyShutoff(inst) then
            pushLog("EMERGENCY: Laser system disarmed")
        end
    else
        -- Fallback if SystemLib not available
        setSig(S.h.laser, 0)
        pushLog("EMERGENCY: Laser output disabled (SystemLib unavailable)")
    end
    
    -- DUST STAYS UNCHANGED - don't modify dust state
    
    -- Continue to compute targets so resumption is seamless
  end

  -- ============
  -- Dust Collector Control (simplified)
  -- ============
  local dustAuto     = (getVar(inst, PV.DustAuto) == 1)
  local dustOverride = (getVar(inst, PV.DustOverride) == 1)
  local laserActive  = (tool == TOOL.Laser or virt == TOOL.Laser)
  local dustTarget   = getVar(inst, PV.DustTarget)

  if dustAuto and (not dustOverride) and (not laserActive) then
    if inCycle == 1 then
      -- In program: dust follows spindle
      dustTarget = (spindle == 1) and 1 or 0
    elseif m6 then
      -- During M6: preserve pre-M6 state
      if S.latchedDustAuto == SENT then
        S.latchedDustAuto = dustTarget
      end
      dustTarget = S.latchedDustAuto
    else
      -- Not in program: dust OFF regardless of spindle
      dustTarget = 0
      S.latchedDustAuto = SENT
    end
    setVar(inst, PV.DustTarget, dustTarget)
  else
    -- Manual mode or override: read manual target
    dustTarget = getVar(inst, PV.DustTarget)
  end
  if S.lastDustTarget ~= dustTarget then
    setSig(S.h.dust, dustTarget)
    S.lastDustTarget = dustTarget
  end

  -- ========
  -- Dust Boot
  -- ========
  local bootAuto     = (getVar(inst, PV.BootAuto) == 1)
  local bootOverride = (getVar(inst, PV.BootOverride) == 1)
  local bootTarget   = getVar(inst, PV.BootTarget)
  local virtualAct   = (virt >= 90)

  -- Safety overrides everything - M6 and virtual tools ALWAYS raise boot
  if m6 or virtualAct then
    bootTarget = 0 -- UP  -- UNCONDITIONAL for safety
    setVar(inst, PV.BootTarget, bootTarget)
    -- Don't allow manual override during these operations
  elseif bootAuto and (not bootOverride) then
    -- AUTO mode logic
    if laserActive or (not enabled) or isEmergencyOrHold(state) then
      bootTarget = 0 -- UP
    else
      -- Normal spindle-based control (no delay)
      bootTarget = (spindle == 1) and 1 or 0 -- DOWN with spindle
    end
    setVar(inst, PV.BootTarget, bootTarget)
  else
    -- MANUAL mode or override active: read manual target
    bootTarget = getVar(inst, PV.BootTarget)
  end
  if S.lastBootTarget ~= bootTarget then
    setSig(S.h.boot, bootTarget)
    S.lastBootTarget = bootTarget
  end

  -- Vacuum pumps: manual-only (no runtime changes here)
end

-- ======================
-- UI / Button wrappers
-- ======================
function dustLib.toggleDustAuto(inst, on)
  inst = instOrGet(inst)
  setVar(inst, PV.DustAuto, on and 1 or 0)
  if on then setVar(inst, PV.DustOverride, 0) end
end
function dustLib.toggleBootAuto(inst, on)
  inst = instOrGet(inst)
  setVar(inst, PV.BootAuto, on and 1 or 0)
  if on then setVar(inst, PV.BootOverride, 0) end
end
function dustLib.manualToggleDust(inst)
  inst = instOrGet(inst); revalidate(inst)
  -- Read target state, not output (single source of truth)
  local cur = getVar(inst, PV.DustTarget)
  local newT = (cur == 1) and 0 or 1
  setVar(inst, PV.DustOverride, 1)  -- set override FIRST
  setVar(inst, PV.DustTarget, newT)
  -- Output will be written on next update() call (max 10ms latency)
  pushLog("Manual dust -> "..tostring(newT))
end
function dustLib.manualToggleBoot(inst)
  inst = instOrGet(inst)
  local m6 = (getVar(inst, PV.M6Flag) == 1)
  local virt = getVar(inst, PV.VirtTool)
  if m6 then mc.mcCntlSetLastError(inst, "Cannot control dust boot during tool change"); return end
  if virt >= 90 then mc.mcCntlSetLastError(inst, "Cannot control dust boot with virtual tool active"); return end
  revalidate(inst)
  -- Read target state, not output (single source of truth)
  local cur = getVar(inst, PV.BootTarget)
  local newT = (cur == 1) and 0 or 1
  setVar(inst, PV.BootOverride, 1)  -- set override FIRST
  setVar(inst, PV.BootTarget, newT)
  -- Output will be written on next update() call (max 10ms latency)
  pushLog("Manual boot -> "..tostring(newT))
end
function dustLib.clearOverrides(inst)
  inst = instOrGet(inst)
  setVar(inst, PV.DustOverride, 0)
  setVar(inst, PV.BootOverride, 0)
end

-- ==========================
-- Program termination helpers
-- ==========================
local function terminateProgram(inst, reason, opts)
  opts = opts or {}
  local dustAuto = getVar(inst, PV.DustAuto) or 0
  local bootAuto = getVar(inst, PV.BootAuto) or 0
  local vacAutoEOP = getVar(inst, PV.VacAutoM30) or 0

  -- Set targets only - don't write outputs
  if dustAuto == 1 then
    setVar(inst, PV.DustTarget, 0)
  end

  if bootAuto == 1 then
    setVar(inst, PV.BootTarget, 0)
  end

  -- Vacuum OFF is acceptable to write directly at M30 only
  if not opts.skipVacOff and vacAutoEOP == 1 then
    setSig(S.h.vacRear, 0)   -- OK for M30
    setSig(S.h.vacFront, 0)  -- OK for M30
  end

  pushLog("EOP/Terminate: " .. tostring(reason))
end

-- ==========================
-- M30 End-of-Program actions
-- ==========================
function dustLib.endOfProgram(inst)
  inst = instOrGet(inst)
  revalidate(inst)
  terminateProgram(inst, "M30", { skipVacOff = false })
end

-- ==========================
-- Program Stop (operator stop, not disable)
-- ==========================
function dustLib.onProgramStop(inst)
  inst = instOrGet(inst)
  revalidate(inst)
  -- Stop should turn OFF dust/boot but NOT vac
  terminateProgram(inst, "Stop", { skipVacOff = true })
end

return dustLib
