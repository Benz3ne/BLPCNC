# BLP CNC System - Developer README

### Core Files You'll Work With
- Scripts/System/ScreenLoad.txt - Initialization, global functions, UI setup
- Scripts/System/PLC.txt - Real-time monitoring (~20Hz), automation control  
- Macros/m6.mcs - Tool change logic (physical and virtual tools)
- Scripts/Dependencies/ - All shared libraries

### Key Design Principles
1. **Single Source of Truth**: Each output signal has ONE writer (see Signal Ownership below)
2. **Libraries as Toolkits**: Libraries don't dictate flow, scripts choose what to use
3. **No Blocking in PLC**: All dialogs must be non-blocking (timer-based)

---

## Library Architecture (Updated 2025-08-28)

All libraries are now consolidated in Scripts/Dependencies/:

Scripts/Dependencies/
├── SystemLib.lua    - Core utilities, G68 management, safety checks
├── DustLib.lua      - Dust collection & boot control (renamed from mcDust)
├── ProbeLib.lua     - Probing utilities (renamed from ProbeLibrary)
├── UILib.lua        - UI dialog and control utilities
└── libBackup/       - Original library files for reference

### Library Loading
ScreenLoad.txt configures the Lua path:
```lua
package.path = package.path .. ";C:/Mach4Hobby/Profiles/BLP/Scripts/Dependencies/?.lua"
```

This enables simple requires:
```lua
SystemLib = require("SystemLib")
dustLib = require("DustLib")
local ProbeLib = require("ProbeLib")
```

---

## Complete Pound Variables Reference

### Profile Storage Sections
[ProbeSettings]         Stores all probe/tool parameters (#300-#320, #353)
[RememberPos]           Stores X, Y, Z machine positions for return
[PersistentDROs]        Stores edge finder, gage block values (#1034-#1036)
[FixtureDescriptions]   Custom descriptions for G54-G59 fixtures

IO Registers:
Keyboard/Enable              Keyboard input enable state
Keyboard/EnableKeyboardJog   Keyboard jog enable state

### Virtual Tool System (Enhanced)
#406  Active virtual tool (0=none, 90-99=virtual active)
#407  X offset delta applied to work coordinates
#408  Y offset delta applied to work coordinates
#440  Stored G68 X center (for virtual tool recovery)
#441  Stored G68 Y center (for virtual tool recovery)
#442  Stored G68 rotation angle (for virtual tool recovery)
#443  G68 adjustment needed flag (0=no, 1=needs adjustment)
#444  Virtual tool apply counter (debugging)
#494  Dust boot state before virtual tool (0=unknown, 1=was down, 2=was up)

### Tool Change Parameters
#300  Probe diameter
#301  Probe X offset (T90)
#302  Probe Y offset (T90)
#303  Probe fast feed
#304  Probe slow feed
#305  Probe max travel
#306  Probe backoff 1
#307  Probe backoff 2
#308  Tool change Z height (typically -6.5)
#309  Tool pullout distance (typically 1.75)
#310  Approach feed rate (typically 200)
#311  Height probe station X
#312  Height probe station Y
#314  Max probe depth
#315  Fast tool height feed
#316  Slow tool height feed
#317  Tool height retract
#318  Laser X offset (T91)
#319  Laser Y offset (T91)
#320  Probe Z calibration offset
#321  Probe lift height (clearance height above surface for XY moves)
#351  Last physical tool (for virtual tool return)
#353  Work surface Z reference (critical for height calcs)

### Probe State and Results
#388  Probe state mode (0=normal, 1=sentinel mode, 2=error state)
#389  Probe contact Z (legacy - not actively used)
#390  Raw probe contact position (before compensation)
#391  Edge position (adjusted for probe radius on X/Y, Z offset on Z)
#392  Spindle position (adjusted for probe offset from spindle)
#394  TRUE surface Z (H-compensated) for datum setting
#395  Surface Z reference (machine coordinate during probe sequence)
#396  Safe plane Z (machine coordinate during probe sequence)
#397  Probe plane Z (machine coordinate during probe sequence)

### Enhanced Automation Control
#400  Dust collection automation enable (0=manual, 1=auto)
#401  Vacuum table automation enable (0=manual, 1=auto)
#402  Dust boot automation enable (0=manual, 1=auto)
#403  Dust boot target state (0=UP, 1=DOWN)
#404  Dust collection target (0=OFF, 1=ON)
#405  Dust collection manual override flag (0=auto, 1=override active)
#410  Dust boot manual override flag (0=auto, 1=override active)

### System Control & Debug
#470  Universal button handler ID (reserved for future)
#471  Virtual tool operation selector (reserved for future)
#472  Dust control operation selector (reserved for future)
#473  State machine temporary storage (reserved for future)
#474  State machine temporary storage (reserved for future)
#475  Reserved for future expansion
#476  Reserved for future expansion
#477  Reserved for future expansion
#478  Reserved for future expansion
#479  Reserved for future expansion

### M6 and System State
#483  M6 call time (os.clock() for debugging)
#495  Spindle spin-up delay armed flag (set by M6, cleared by PLC)
#496  Spindle spin-up delay seconds (configurable, default 3)
#498  Dialog suppression flag (prevents prompts during M6)
#499  M6 running flag (1=running, 0=idle)

### Temporary Storage
#500  First probe contact storage (used in m2010)
#501  Second probe contact storage (used in m2010)

### G68 Rotation State (System)
#1245  Current G68 X center
#1246  Current G68 Y center  
#1247  Current G68 rotation angle (degrees)

### DRO Persistence Variables
#1034  Edge finder DRO value (persisted to profile)
#1035  Gage block DRO value (persisted to profile)
#1036  Gage block T DRO value (persisted to profile)

### Modal State Variables (G-code state tracking)
#4000  Motion mode (0=G0, 1=G1, 2=G2, 3=G3)
#4001  Feed mode (94=G94 units/min, 95=G95 units/rev)
#4002  Plane selection (17=G17 XY, 18=G18 XZ, 19=G19 YZ)
#4003  Absolute/Incremental mode (90=G90 absolute, 91=G91 incremental)
#4008  Tool compensation/H offset state (49=G49 cancelled, 43=G43 active)
#4014  Modal work offset (alternate detection for current fixture)
#4016  Rotation modal (68=G68 rotation active, 69=G69 no rotation)
#4120  Active H offset number (which H is currently applied)

### Probing Result Variables
#5061  Probe contact X position
#5062  Probe contact Y position
#5063  Probe contact Z position
#5073  Final probe contact Z position (from G31)

### Extended Fixture Variables
#5219  BUFP - P number for G54.1 extended fixtures
#5220  Current work offset (54=G54, 55=G55... 54.1=G54.1 P1)

### Work Offsets (G54-G59)
G54: X=#5221, Y=#5222, Z=#5223
G55: X=#5241, Y=#5242, Z=#5243
G56: X=#5261, Y=#5262, Z=#5263
G57: X=#5281, Y=#5282, Z=#5283
G58: X=#5301, Y=#5302, Z=#5303
G59: X=#5321, Y=#5322, Z=#5323

### Extended Fixtures (G54.1)
#7001-7020   G54.1 P1 (X,Y,Z,A,B,C + reserved)
#7021-7040   G54.1 P2
...continues every 20 variables...
#14001-14020 G54.1 P51
...continues to P100...

---

## Signal Ownership Matrix

**CRITICAL**: Each output has ONE writer. Never write to outputs owned by other modules.

### Output Signals
| Signal | Owner | Purpose | Notes |
|--------|-------|---------|-------|
| OSIG_OUTPUT1 | M6/ScreenLoad | Laser crosshair power | Virtual tool T91 |
| OSIG_OUTPUT2 | PLC | Tool release solenoid | Mirrors INPUT8 |
| OSIG_OUTPUT3 | **dustLib ONLY** | Dust boot down (1=down, 0=up) | Never write directly! |
| OSIG_OUTPUT4 | **dustLib ONLY** | Dust collector power | Never write directly! |
| OSIG_OUTPUT5 | **dustLib ONLY** | Vacuum table 1 (rear) | Never write directly! |
| OSIG_OUTPUT6 | **dustLib ONLY** | Vacuum table 2 (front) | Never write directly! |
| OSIG_OUTPUT7 | M6/ScreenLoad | Touch probe power | Virtual tool T90 |
| OSIG_SPINDLEON | Spindle | Spindle running signal | System controlled |
| OSIG_MACHINE_ENABLED | System | Machine enabled state | System controlled |
| OSIG_JOG_CONT | System | Continuous jog mode active | System controlled |
| OSIG_JOG_INC | System | Incremental jog mode active | System controlled |
| OSIG_JOG_MPG | System | MPG jog mode active | System controlled |
| OSIG_SOFTLIMITS_ON | System | Soft limits enabled | System controlled |

### Input Signals
| Signal | Purpose | Debounced | Primary Reader |
|--------|---------|-----------|----------------|
| ISIG_INPUT6 | Low air pressure (1=low/bad, 0=normal) | No | PLC, dustLib |
| ISIG_INPUT7 | Dust boot up sensor (1=up, 0=down) | No | Multiple |
| ISIG_INPUT8 | Tool release button (manual override) | No | PLC |
| ISIG_INPUT16 | Tool clamp open sensor (1=open, 0=closed) | No | M6 |
| ISIG_INPUT17 | Tool present in spindle (1=present, 0=empty) | Yes (50ms) | PLC |
| ISIG_PROBE | Probe contact signal (1=contact, 0=no contact) | No | Probing scripts |

---

## Machine States (Mach4 Official Values)

STATE_IDLE              = 0     Machine idle
STATE_FRUN              = 100   Feed running (program executing)
STATE_FHOLD             = 101   Feed hold
STATE_FRUN_PROBE        = 102   Probing run (active G31 probing)
STATE_FRUN_PROBE_FH     = 103   Feed hold while probing
STATE_FRUN_MACROH_JOG   = 109   Macro hold + jog enabled
STATE_FRUN_SINGLE_BLOCK = 110   Single block execution
STATE_MRUN              = 200   MDI/Macro running
STATE_MRUN_FH           = 201   MDI/Macro feed hold
STATE_MRUN_THREAD_FH    = 205   Thread feed hold
STATE_MRUN_TAP          = 206   Tapping operation
STATE_MRUN_MACROH       = 207   Macro hold
STATE_MRUN_MACROH_JOG   = 208   Macro hold + jog enabled

Additional State Constants:
mc.MERROR_NOERROR  = Success/no error return code

CRITICAL NOTES:
- State 102 is ACTIVE PROBING, not a hold state!
- State 103 is the probe-specific feed hold
- State 109 is NOT a stop state, it's macro hold with jog
- For detecting ANY hold condition, check: 101, 103, 201, 207
- For detecting ANY running condition, check: 100, 102, 200

---

## Axis Constants

mc.X_AXIS = 0    X axis index
mc.Y_AXIS = 1    Y axis index
mc.Z_AXIS = 2    Z axis index

---

### Adding Automation to an Output
1. **Check Signal Ownership** - Ensure not already owned
2. **Extend dustLib** if dust-related, otherwise create new module
3. **Update PLC** to call your automation logic
4. **Document ownership** in this README

---

## Module Dependencies

ScreenLoad.txt
├── Requires: SystemLib, dustLib
├── Provides: Global RetractVirtualTool()
└── Provides: Global ShowToolSelectionDialog()

PLC.txt  
├── Requires: dustLib, Global functions
└── Updates: Screen properties, pound vars

M6.mcs
├── Requires: SystemLib (G68), dustLib (clearOverrides)
└── Calls: RetractVirtualTool()

Button Scripts
└── Call: dustLib functions directly

---

## File Naming Conventions

- .txt files - Lua scripts (historical reasons)
- .mcs files - M-code macros  
- .lua files - Pure Lua libraries
- Button scripts - Named by button function (e.g., DustBootManual.txt)

---

## Critical Functions & Locations

| Function | Defined In | Called By | Purpose | Status |
|----------|------------|-----------|---------|---------|
| `RetractVirtualTool()` | Screen Load | M6, PLC, Recovery | Single source virtual tool cleanup with G68 support | ✓ Enhanced |
| `PopulateTools()` | Screen Load | Machine enable | Build tool dropdown from table | ✓ Stable |
| `UpdateToolPreview()` | Screen Load | Tool changes | Update UI display | ✓ Stable |
| `promptToolSelection()` | PLC | PLC | Get tool number | ⚠ BLOCKS PLC |
| `CheckHomingBeforeMove()` | Screen Load | Cycle start | Enforce homing safety | ✓ Enhanced |
| `UpdateDustBoot()` | Screen Load | PLC | Simplified dust boot control | ✓ New |
| `UpdateAllDustButtons()` | PLC | PLC | Sync dust button UI states | ✓ Optimized |
| `ShowHomingRequiredDialog()` | Screen Load | Movement commands | Homing warning with bypass | ✓ Enhanced |
| `ValidateVirtualToolConfig()` | Screen Load | Startup | Check/repair virtual tool offsets | ✓ New |

---

## Recovery & Safety Systems

### E-Stop/Crash Recovery
Machine Disabled:
  1. Virtual tool outputs OFF immediately (prevent Mach4 memory issues)
  2. State preserved in #406/#407/#408 for recovery
  3. M6 flags cleared (#499, #498)
  4. Tool selection cleared
  5. Motion flags reset

Machine Re-enabled:  
  1. Check #406 for orphaned virtual tool
  2. If found, call enhanced RetractVirtualTool() with G68 support
  3. Resync H offsets (G49 then G43 if needed)
  4. Cancel rotation (G69) 
  5. Check homing state
  6. Refresh tool dropdown

### Enhanced Homing Safety
Before any movement:
  1. Check all enabled axes for homing status
  2. If any unhomed, show enhanced dialog:
     - HOME ALL (green, default, Enter key)
     - Ignore Warning → Confirmation → Bypass if confirmed
  3. Block movement unless homed or explicitly bypassed
  4. Reset bypass on successful homing or machine disable
  5. Visual indicators: Flashing yellow "HOME REQUIRED" button

### Virtual Tool Offset Mechanics
Deploy (T90/T91):
  1. Validate offsets are reasonable (< 12.0)
  2. Set atomic operation flag (#445 = 1, #446 = 1)
  3. FOR each fixture G54-G59:
       X = X - offset  // Tool appears at spindle position
       Y = Y - offset
  4. Store deltas in #407, #408 and increment counter #444
  5. Clear atomic flag (#445 = 0)

Retract (Enhanced):
  1. Check for active G68 rotation (#4016 == 68)
  2. If G68 active:
     - Calculate adjusted center: currentCenter + deltas
     - Store adjustment data (#440-#443)
     - Cancel G68 temporarily
  3. FOR each fixture G54-G59:
       X = X + offset  // Restore original zeros
       Y = Y + offset  
  4. If G68 was active:
     - Reapply with adjusted center
     - Clear adjustment flags
  5. Clear state (#406, #407, #408, #444, #445)

### Low Air Pressure Safety
Detection (3-cycle debounce):
  1. ISIG_INPUT6 == 1 detected for 3 consecutive PLC cycles
  
Response Sequence:
  1. If in cycle: Feed hold → Cycle stop
  2. If spindle running: Stop spindle  
  3. Disable machine (mc.mcCntlEnable(0))
  4. Set _G.lowAirDisabled = true
  5. Show non-blocking dialog via coroutine
  6. Update UI: Red "Air Pressure LOW!" button

Recovery:
  1. ISIG_INPUT6 == 0 detected (pressure restored)
  2. Clear _G.lowAirDisabled = false
  3. Show "Air Pressure Restored" dialog
  4. User must manually re-enable machine
  5. Update UI: Green "Air Pressure NORMAL" button

---

## State Machine Implementations

### Dust Collection State Machine (dustLib)
States: {OFF, MANUAL_ON, LATCHED, PROGRAM_ACTIVE}

State Transitions:
  OFF → MANUAL_ON:       Spindle ON (no program)
  OFF → LATCHED:         inCycle==1 && spindle==1
  LATCHED → PROGRAM_ACTIVE: Latch triggered
  PROGRAM_ACTIVE → OFF:  M30 executed
  PROGRAM_ACTIVE → OFF:  Stop detected by PLC
  MANUAL_ON → OFF:       Spindle OFF (no program)
  
Persistence: State saved in #500 (dustLatched), #501 (programActive)

### Boot Position State Machine (dustLib)
States: {DOWN, UP, FREEZE}

State Transitions:
  DOWN → UP:      Virtual tool active (#406 >= 90)
  UP → DOWN:      Virtual tool inactive && freeze expired
  DOWN → FREEZE:  M6 ends with virtual tool (500ms)
  FREEZE → DOWN:  Timer expires
  ANY → UP:       Manual override (#401 = 2)
  ANY → DOWN:     Manual override (#401 = 1)
  
Persistence: Override state in #401, freeze timer in memory

### Tool Change State Machine (M6)
States: {IDLE, CHECK_VIRTUAL, DEPLOY_VIRTUAL, RETRACT_VIRTUAL, PHYSICAL_MOVE, MEASURE, COMPLETE, ERROR}

State Transitions:
  IDLE → CHECK_VIRTUAL:     M6 triggered
  CHECK_VIRTUAL → DEPLOY_VIRTUAL:   T90-99 requested
  CHECK_VIRTUAL → RETRACT_VIRTUAL:  Physical after virtual
  CHECK_VIRTUAL → PHYSICAL_MOVE:    T1-89 requested  
  DEPLOY_VIRTUAL → COMPLETE:        Virtual tool applied
  RETRACT_VIRTUAL → PHYSICAL_MOVE:  Virtual cleared
  PHYSICAL_MOVE → MEASURE:          Tool needs height
  PHYSICAL_MOVE → COMPLETE:         Skip measurement
  MEASURE → COMPLETE:               Height measured
  ANY → ERROR:                      Exception caught
  
Guards: #499 prevents re-entry, #445 protects G68 operations

---

## System Integration Points

### Module Dependencies (Expanded)
ScreenLoad.txt
  ├── Requires: SystemLib.lua (G68 management)
  ├── Requires: dustLib.lua (dust control)
  ├── Requires: mcRegister, mcErrorCheck modules
  ├── Provides: Global RetractVirtualTool()
  └── Provides: Global ShowToolSelectionDialog()

PLC.txt  
  ├── Requires: dustLib.lua
  ├── Requires: Global functions from ScreenLoad
  ├── Reads: All pound variables
  └── Writes: Screen properties, pound variables

M6.mcs
  ├── Requires: SystemLib.lua (G68)
  ├── Requires: dustLib.lua (for clearOverrides)
  ├── Requires: Global RetractVirtualTool()
  ├── Reads: Tool table, pound variables
  └── Writes: Pound variables, work offsets

dustLib.lua
  ├── Standalone module
  ├── Reads: Pound variables, signals
  └── Writes: OUTPUT3/4/5/6 EXCLUSIVELY

SystemLib.lua
  ├── Standalone utility library
  ├── Provides: G68 atomic operations
  └── Manages: #440-443, #445 (lock)

### System Interaction Matrix
| Component | Reads From | Writes To | Calls |
|-----------|------------|-----------|-------|
| ScreenLoad | Tool Table, Screen Props, Pound Vars | Pound Vars, Screen Props | dustLib, Global Functions |
| PLC | All Inputs, Pound Vars, Machine State | Screen Props, Pound Vars, Flags (_G) | dustLib.update(), dustLib.onProgramStop() |
| M6 Macro | Pound Vars, Tool Table, Input Signals | Pound Vars, Work Offsets, OUTPUT1/7 | RetractVirtualTool(), SystemLib.G68, dustLib.clearOverrides |
| dustLib | Pound Vars, Input Signals | OUTPUT3/4/5/6, Pound Vars | (none - library) |
| Button Scripts | (none) | (none) | dustLib functions |
| M-codes (2,30) | Pound Vars | Pound Vars, Spindle | dustLib.endOfProgram() |

### Communication Mechanisms
1. **Pound Variables**: Primary state sharing (#300-#600)
2. **Global Functions**: _G table for cross-script calls
3. **Screen Properties**: UI state synchronization
4. **Signal States**: Hardware state monitoring
5. **Flags**: Non-blocking communication (e.g., _G.needToolPrompt)

---

## Execution Flow Summary

1. STARTUP SEQUENCE
   └─> Screen Load initializes → Validate configs → Define globals → 
       Check recovery needed → Enable soft limits → Initialize dust system

2. NORMAL CUTTING WORKFLOW  
   └─> M6 T[n] → Measure (unless NO_MEASURE) → Arm spindle delay (#495) →
       Program start (state 100) → Spindle ON → PLC detects → Pause if armed →
       Resume after delay → Motion detected → Boot down (auto) → 
       Cutting → Program end (state 0) → Boot up, dust off

3. VIRTUAL TOOL WORKFLOW
   └─> M6 T90 → Return physical if loaded → Apply offsets (atomic) → 
       Activate probe → G31 operations (state 102) → Process results →
       M6 T[physical] → Enhanced retract with G68 support → Continue

4. PROBING WITH G68 ROTATION
   └─> G68 X Y R → M6 T90 → Enhanced deployment → Probing operations →
       M6 T[physical] → Detect G68 → Calculate adjustments → 
       Restore offsets → Reapply adjusted G68 → Continue

5. EMERGENCY SCENARIOS
   └─> Low air detected → Emergency shutdown → Dialogs → Restore → Re-enable
   └─> Machine disable → Secure outputs → Recovery check on re-enable
   └─> E-stop → Crash recovery → Virtual tool cleanup → State restoration

6. TOOL MANAGEMENT
   └─> Manual insertion → PLC detects → Tool selection dialog (BLOCKING ISSUE) →
       Update dropdown → Sync H offset → Ready

7. HOMING SAFETY
   └─> Movement command → Check homing → Show dialog if needed →
       HOME ALL or Ignore → Bypass tracking → Continue or block

---

## Contact & Resources

- System Logic Map: Scripts/Docs/SystemLogicMap.txt (detailed flow diagrams)
- ESS Laser Docs: Scripts/Docs/ESSLaserDocumentation.txt
- Original libraries: Scripts/Dependencies/libBackup/