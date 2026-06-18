# Project Brief: blau-drill — PCB Drilling Control App

## 1. Executive Summary
**blau-drill** is a single-operator desktop application designed to control a modified 3D printer for precision PCB drilling. It translates digital circuit designs into physical movements, guiding the operator through a safe, linear workflow from file loading to final drilling.

## 2. User Persona & Environment
- **Operator:** Technical owner/enthusiast. Familiar with PCB design and CNC/3D printer mechanics.
- **Environment:** Machine bench or workshop.
- **Constraints:** Desktop usage (laptop on bench), potential for gloved hands, requires high visibility from a distance (standing at the machine).

## 3. Core Visual Principles
- **Canvas-Centric:** A 2D top-down view of the PCB is the focal point, showing hole locations, drill-bit sizes, and live machine position.
- **Safety Gates:** Critical actions (jogging, drilling) are locked behind physical/software gates (e.g., "Enable Motors") to prevent hardware damage.
- **Industrial Precision:** High-contrast dark theme, monospaced data readouts, and clear color coding (Amber for active/caution, Green for success, Red for faults).

## 4. Operational User Flow
The application follows a strictly linear 5-stage process:

### Stage 1: Load & Connect
- **Hardware Handshake:** Select USB Serial Port and Baud Rate. Establish live communication.
- **File Ingest:** Support for Gerber (.gbr) and Excellon (.drl) formats.
- **Validation:** Automatic parsing of hole coordinates and bit sizes. Diagnostic feedback on file errors.

### Stage 2: Physical Alignment
- **Fiducial Selection:** Operator selects 3–4 reference marks on the canvas.
- **Motor Safety Gate:** Jogging is disabled until "Enable Motors" is toggled.
- **Interactive Jogging:** Precision X/Y/Z controls with selectable step sizes (0.1mm, 1.0mm, 10mm).
- **Coordinate Mapping:** "Capture" physical positions to compute the relationship between board and machine coordinates.
- **Quality Score:** Visual indicator (0-100%) showing alignment trustworthiness.

### Stage 3: Dry-run
- **Safety Rehearsal:** The drill head traces all hole positions at a safe height (Z-offset) with the spindle off.
- **Confirmation:** Operator verifies physical alignment against the digital preview.

### Stage 4: Active Drilling
- **Execution:** Real-time G-code streaming. Live progress tracking (Hole X of Y).
- **Automated Tool Pauses:** System pauses and prompts the operator when a bit change is required (e.g., "Swap to 0.8mm bit").
- **Safety Interruption:** Prominent "Emergency Stop" and "Abort" controls.

### Stage 5: Completion
- **Session Summary:** Total holes drilled, elapsed time, and bit change count.
- **Fault Handling:** Robust recovery paths for "Hardware Disconnected" or "CNC Fault" states.

## 5. Technical Configuration (Settings)
A dedicated configuration environment for hardware-level parameters:
- **Motion Limits:** Define maximum X, Y, and Z travel distances to prevent mechanical crashes.
- **Spindle Control:** Configurable G-code commands and PWM range (e.g., 0-255 or 0-1000) to support varied spindle controllers.
- **Auto-connect:** Toggle for establishing connection on startup.

## 6. Design System Specifications
- **Theme:** Industrial Dark Mode.
- **Primary Color:** Industrial Amber (#ffb300).
- **Typography:** Inter (UI), Monospaced (Data/Coordinates).
- **Components:** Modular sidebar controls, global header with status indicators, and a persistent bottom data bar.
