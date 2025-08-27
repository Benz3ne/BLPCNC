# BLPCNC Scripts Changelog

All notable changes to the BLPCNC Mach4 script system will be documented in this file.

## [Current] - 2025-08-27

### System Architecture Overview

The BLPCNC system consists of several integrated script modules organized into functional categories:

### System Scripts
- **PLC.txt**: Core system logic controller (1130 lines)
  - Machine state monitoring and control
  - Tool management with automatic detection and prompting
  - Dust collection automation system
  - Air pressure monitoring with safety shutoffs
  - Homing status indicators
  - Work offset monitoring
  - Soft limits management
  - Touch probe and laser deployment controls
  - Production/debug mode switching

- **ScreenLoad.txt**: Screen initialization and UI setup
- **SetToolButton.txt**: Tool selection interface management
- **SystemLogicMap.txt**: System logic documentation
- **TargetMove.txt**: Motion control utilities

### Probing System
- **ProbeCommon.lua**: Shared probing utilities library (108 lines)
  - Configuration management
  - Safety gates and validation
  - Sentinel probe wrappers
  - Soft-limit helpers
  - Profile I/O functions
  - Motion and timing utilities
  - Logging and cleanup functions

- **-ZProbe.txt**: Z-axis touch probing
- **FindAngle.txt**: Angular alignment probing
- **InsideCenter.txt**: Internal center finding
- **InsideCorner.txt**: Internal corner probing  
- **OutsideCenter.txt**: External center finding
- **ProbeBore.txt**: Bore measurement probing
- **ProbeBoss.txt**: Boss measurement probing
- **ProbeXY.txt**: XY coordinate probing
- **Probe_Scripts_Consolidation_Plan.md**: Probing system architecture plan
- **probe_refactor_plan.md**: Refactoring roadmap

### Laser Control System
- **LaserCuttingWizard.txt**: Laser cutting automation
- **LaserRasterWizard.txt**: Laser raster/engraving operations

### Dust Collection System
- **DustBootAuto.txt**: Automatic dust boot control (12 lines)
  - Toggles between auto/manual modes for dust boot
  - Updates UI indicators
  - Manages pound variable states

- **DustBootManual.txt**: Manual dust boot override
- **DustCollectAuto.txt**: Automatic dust collection control
- **DustCollectManual.txt**: Manual dust collection override

### Debug & Documentation
- **Debug.txt**: System debugging utilities
- **DebugButtonEnvironment.txt**: Debug environment setup
- **ESSLaserDocumentation.txt**: ESS laser system documentation

### Key Features Implemented

#### Tool Management System
- Automatic tool detection via sensor (Input #17)
- Tool change prompting with physical tool selection
- Virtual tool support (T90+ probe, T91 laser)
- Tool height offset synchronization (G43/G49)
- Tool presence monitoring with safety interlocks

#### Dust Collection Automation
- Spindle-synchronized dust collection
- Automatic boot deployment/retraction
- Manual override capabilities
- Emergency safety shutoffs
- M6 tool change protection

#### Safety Systems
- Air pressure monitoring (Input #6) with machine disable
- Emergency stop handling with laser shutoff
- Soft limits monitoring and indicators
- Homing requirement enforcement
- Feed hold on critical faults

#### Probing Infrastructure
- Standardized probing library (ProbeCommon.lua)
- Multiple probe types (center, corner, bore, boss, angle)
- Sentinel value validation
- Probe deployment automation
- Safety validation and travel limits

#### User Interface Integration
- Dynamic button state updates
- LED status indicators  
- Tab-aware refreshing
- Production/debug mode switching
- Real-time feedback and error messages

### Configuration Management
- Profile-based parameter storage
- Persistent DRO values
- Work offset monitoring (G54-G59)
- Machine state persistence
- Tool table integration

### Architecture Notes
- Modular design with shared utilities
- Event-driven state monitoring
- Graceful error handling
- Performance-optimized updates
- Thread-safe operations

---

*This changelog documents the current state of the BLPCNC script system as of 2025-08-27. All scripts work together to provide integrated CNC control with advanced automation features.*