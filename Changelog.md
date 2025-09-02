## 2025-09-02

- ScreenLoad: added numeric helper `num(v, default)` and replaced fragile `tonumber(...)` usages in b01, interlocks, enable handler, tool helpers, soft-limits seed to prevent exceptions when values are already numeric in this runtime.
- ScreenLoad: tightened dust auto policy to spindle-only (was spindle OR inCycle) to prevent false ON during Enable from transient inCycle.
- ScreenLoad: added one-time PV seeding before any device updates (#400=1, #402=1, #401=0; #404/#403/#411/#412=0) to ensure deterministic OFF targets at startup.
- PLC: removed immediate `AuxLib.Update(inst)` call after seeding PV defaults in `PLC_Init` to avoid enable-time races; first PLC_Tick now drives updates after UI stabilizes.
- PLC: hardened low-air check to guard against nil/zero signal handles before calling `mc.mcSignalGetState`.
- SystemLib (Dependencies): fixed a syntax error in return of `Gcode.BuildLinearMove` (newline literal) causing degraded-mode require failures.
- PLC: normalized PV reads and removed double `tonumber(...)` conversions earlier to resolve `bad argument #1 to 'tonumber'` errors.

- AuxLib: added debug logging (gated by SystemLib debug mode #4990):
  - AuxLib.Request logs device/action and resulting auto/target PVs after a request.
  - AuxLib.Update logs writes only when state changes, including signal name, ID, handle, enabled state, desired value, and read-back state.
  - Enable via `SystemLib.SetDebugMode(inst, true)` or set `#4990=1`.

- ScreenLoad: added a simple debug mode toggle (DEBUG_MODE=true) that calls `SystemLib.SetDebugMode(inst, true)` at load so diagnostics are visible in the message console.

Rationale: Keep libraries as the single source of truth for execution (IO/state). Move policy (when to run devices) and ordering (when defaults apply) into ScreenLoad/PLC. This resolves enable-time activations and UI repaint issues at the source with minimal, targeted changes.
