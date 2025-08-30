-- Modules/mcDust.lua — Final v1
-- Unified control for Dust Collector (OUTPUT4), Dust Boot (OUTPUT3), and Vacuum Pumps (OUTPUT5/6)
-- Single source of truth. Other scripts must not write OUTPUT3/4 directly.
--
-- Public API:
--   mcDust.init(inst?)
--   mcDust.update(inst?)
--   mcDust.toggleDustAuto(inst?, onOff)
--   mcDust.toggleBootAuto(inst?, onOff)
--   mcDust.manualToggleDust(inst?)
--   mcDust.manualToggleBoot(inst?)
--   mcDust.clearOverrides(inst?)              -- optional UI action
--   mcDust.endOfProgram(inst?)               -- M30 hook: Dust OFF if #400==1; Boot UP if #402==1; Vacs OFF if #401==1
--
-- Behavior (per spec):
--   • Dust AUTO = spindle ON only; holds pre‑M6 auto state during M6; AUTO muted during laser (T91) but manual allowed
--   • Boot AUTO = DOWN with spindle; UP during M6, any virtual (>=90), or emergency/disable; 500 ms release window after M6/virtual ends
--   • Overrides (#405/#410) clear on spindle rising edge only
--   • Vacuum pumps manual-only; endOfProgram() turns them OFF if #401==1; library does not change vacs during emergency/disable
--   • Emergency/disable: Laser OFF, Boot UP, Dust unchanged
--   • Startup: mirror #403/#404 from actual outputs; sentinel = -999999; 200-entry log ring

local mcDust = {}

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
  latchedDustAuto = SENT, -- pre‑M6 dust auto target latch
  lastDustTarget = -1,    -- last applied dust target (0/1)
  lastBootTarget = -1,    -- last applied boot target (0/1)
  prevM6OrVirtual = false,
  inhibitBootUntil = 0,   -- ms timestamp for 500 ms boot release window
  log = {},               -- ring buffer (max 200)
  -- Cycle-latched dust state
  dustLatched = 0,        -- 0/1 - dust latch state
  programActive = 0,      -- 0/1 - program active state
  lastInCycle = 0,        -- edge detection for Stop
  sw = nil,               -- stopwatch for monotonic timing
  lastMs = 0,             -- cached timestamp
}

-- ==========
-- Utilities
-- ==========
local function instOrGet(inst) return inst or mc.mcGetInstance() end

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
local function pushLog(msg)
  local t = os.clock()
  S.log[#S.log+1] = string.format("[%.3f] %s", t, msg)
  if #S.log > 200 then table.remove(S.log, 1) end
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
function mcDust.init(inst)
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
  
  -- Initialize cycle-latch state
  S.dustLatched = 0
  S.programActive = 0
  S.lastInCycle = 0

  -- Initialize pound vars if uninitialized
  for _,n in ipairs({PV.DustAuto,PV.DustTarget,PV.BootAuto,PV.BootTarget,PV.DustOverride,PV.BootOverride,PV.VacAutoM30,PV.VirtTool,PV.M6Flag}) do
    if getVar(inst,n) == SENT then setVar(inst,n,0) end
  end
  -- Seed pound-var mirrors from actual outputs so UI matches hardware on startup
  if S.h.dust then S.lastDustTarget = sigState(S.h.dust); setVar(inst, PV.DustTarget, S.lastDustTarget) end
  if S.h.boot then S.lastBootTarget = sigState(S.h.boot); setVar(inst, PV.BootTarget, S.lastBootTarget) end

  S.init = true
  pushLog("mcDust.init complete")
end

-- ==========
-- update (PLC)
-- ==========
function mcDust.update(inst)
  inst = instOrGet(inst)
  if not S.init then mcDust.init(inst) end
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

  -- Track M6/virtual transition for 500 ms boot release window
  local m6OrVirtual = m6 or (virt >= 90)
  if S.prevM6OrVirtual and (not m6OrVirtual) then
    S.inhibitBootUntil = now + 500 -- hold boot last state for 500 ms
  end
  S.prevM6OrVirtual = m6OrVirtual
  local bootFreeze = (now < S.inhibitBootUntil)

  -- Emergency/Disable: Boot UP, Laser OFF, Dust OFF (per plan), clear latches
  if isEmergencyOrHold(state) or not enabled then
    setSig(S.h.boot, 0); setVar(inst, PV.BootTarget, 0)
    setSig(S.h.laser, 0)
    
    -- Emergency laser ESS shutoff - critical safety feature
    local success1, hregActivate = pcall(mc.mcRegGetHandle, inst, "ESS/Laser/Test_Mode_Activate")
    local success2, hregEnable = pcall(mc.mcRegGetHandle, inst, "ESS/Laser/Test_Mode_Enable")
    
    if success1 and hregActivate and mc.mcRegGetValue(hregActivate) == 1 then
        mc.mcRegSetValue(hregActivate, 0)  -- Stop firing
        pushLog("EMERGENCY: Laser firing stopped")
    end
    if success2 and hregEnable and mc.mcRegGetValue(hregEnable) == 1 then
        mc.mcRegSetValue(hregEnable, 0)    -- Disarm system  
        pushLog("EMERGENCY: Laser system disarmed")
    end
    
    -- Per plan: dust OFF on emergency/disable if AUTO enabled
    local dustAuto = (getVar(inst, PV.DustAuto) == 1)
    if dustAuto then
      setSig(S.h.dust, 0)
      setVar(inst, PV.DustTarget, 0)
      S.lastDustTarget = 0
      S.dustLatched = 0
      S.programActive = 0
      pushLog("Emergency/Disable: Dust OFF, latches cleared")
    end
    
    -- Continue to compute targets so resumption is seamless
  end

  -- ============
  -- Dust Collector (CYCLE-LATCHED)
  -- ============
  local dustAuto     = (getVar(inst, PV.DustAuto) == 1)
  local dustOverride = (getVar(inst, PV.DustOverride) == 1)
  local laserActive  = (tool == TOOL.Laser or virt == TOOL.Laser)
  local dustTarget   = getVar(inst, PV.DustTarget)

  if dustAuto and (not dustOverride) and (not laserActive) then
    -- Program active takes priority - keep dust ON
    if S.programActive == 1 then
      dustTarget = 1
    -- Latch ON at first inCycle && spindle==ON
    elseif inCycle == 1 and spindle == 1 and S.dustLatched == 0 then
      S.dustLatched = 1
      S.programActive = 1
      dustTarget = 1
      pushLog("Dust latched ON (cycle+spindle)")
    -- M6 preserves pre-M6 state when not in active program
    elseif m6 then
      if S.latchedDustAuto == SENT then
        S.latchedDustAuto = (spindle == 1) and 1 or 0
      end
      dustTarget = S.latchedDustAuto
    -- Manual spindle (not in program)
    else
      S.latchedDustAuto = SENT
      dustTarget = (spindle == 1) and 1 or 0
    end
    setVar(inst, PV.DustTarget, dustTarget)
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

  if bootAuto and (not bootOverride) then
    if m6 or virtualAct or laserActive or (not enabled) or isEmergencyOrHold(state) then
      bootTarget = 0 -- UP
    else
      if bootFreeze then
        bootTarget = S.lastBootTarget -- hold for 500 ms after M6/virtual end
      else
        bootTarget = (spindle == 1) and 1 or 0 -- DOWN with spindle
      end
    end
    setVar(inst, PV.BootTarget, bootTarget)
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
function mcDust.toggleDustAuto(inst, on)
  inst = instOrGet(inst)
  setVar(inst, PV.DustAuto, on and 1 or 0)
  if on then setVar(inst, PV.DustOverride, 0) end
end
function mcDust.toggleBootAuto(inst, on)
  inst = instOrGet(inst)
  setVar(inst, PV.BootAuto, on and 1 or 0)
  if on then setVar(inst, PV.BootOverride, 0) end
end
function mcDust.manualToggleDust(inst)
  inst = instOrGet(inst); revalidate(inst)
  local cur = sigState(S.h.dust)
  local newT = (cur == 1) and 0 or 1
  setVar(inst, PV.DustOverride, 1)  -- set override FIRST
  setVar(inst, PV.DustTarget, newT)
  setSig(S.h.dust, newT)
  S.lastDustTarget = newT
  pushLog("Manual dust -> "..tostring(newT))
end
function mcDust.manualToggleBoot(inst)
  inst = instOrGet(inst)
  local m6 = (getVar(inst, PV.M6Flag) == 1)
  local virt = getVar(inst, PV.VirtTool)
  if m6 then mc.mcCntlSetLastError(inst, "Cannot control dust boot during tool change"); return end
  if virt >= 90 then mc.mcCntlSetLastError(inst, "Cannot control dust boot with virtual tool active"); return end
  revalidate(inst)
  local cur = sigState(S.h.boot)
  local newT = (cur == 1) and 0 or 1
  setVar(inst, PV.BootOverride, 1)  -- set override FIRST
  setVar(inst, PV.BootTarget, newT)
  setSig(S.h.boot, newT)
  S.lastBootTarget = newT
  pushLog("Manual boot -> "..tostring(newT))
end
function mcDust.clearOverrides(inst)
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

  -- Dust OFF only if AUTO was enabled
  if dustAuto == 1 then
    setVar(inst, PV.DustTarget, 0)
    setSig(S.h.dust, 0)
    S.lastDustTarget = 0
  end

  -- Boot UP only if AUTO was enabled
  if bootAuto == 1 then
    setVar(inst, PV.BootTarget, 0)
    setSig(S.h.boot, 0)
    S.lastBootTarget = 0
  end

  -- Vac OFF only at M30 (or explicit EOP), controlled by #401
  if not opts.skipVacOff and vacAutoEOP == 1 then
    setSig(S.h.vacRear, 0)
    setSig(S.h.vacFront, 0)
  end

  -- Clear latches
  S.dustLatched = 0
  S.programActive = 0

  pushLog("EOP/Terminate: " .. tostring(reason))
end

-- ==========================
-- M30 End-of-Program actions
-- ==========================
function mcDust.endOfProgram(inst)
  inst = instOrGet(inst)
  revalidate(inst)
  terminateProgram(inst, "M30", { skipVacOff = false })
end

-- ==========================
-- Program Stop (operator stop, not disable)
-- ==========================
function mcDust.onProgramStop(inst)
  inst = instOrGet(inst)
  revalidate(inst)
  -- Stop should turn OFF dust/boot but NOT vac
  terminateProgram(inst, "Stop", { skipVacOff = true })
end

return mcDust
