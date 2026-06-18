---
name: Industrial Precision Control
colors:
  surface: '#131313'
  surface-dim: '#131313'
  surface-bright: '#393939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353534'
  on-surface: '#e5e2e1'
  on-surface-variant: '#d6c4ac'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#9e8e78'
  outline-variant: '#514532'
  surface-tint: '#ffba38'
  primary: '#ffd79b'
  on-primary: '#432c00'
  primary-container: '#ffb300'
  on-primary-container: '#6b4900'
  inverse-primary: '#7e5700'
  secondary: '#40e56c'
  on-secondary: '#003912'
  secondary-container: '#02c953'
  on-secondary-container: '#004d1b'
  tertiary: '#a7ef9f'
  on-tertiary: '#003909'
  tertiary-container: '#8cd286'
  on-tertiary-container: '#185b1d'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#ffdeac'
  primary-fixed-dim: '#ffba38'
  on-primary-fixed: '#281900'
  on-primary-fixed-variant: '#604100'
  secondary-fixed: '#69ff87'
  secondary-fixed-dim: '#3ce36a'
  on-secondary-fixed: '#002108'
  on-secondary-fixed-variant: '#00531e'
  tertiary-fixed: '#acf4a4'
  tertiary-fixed-dim: '#91d78a'
  on-tertiary-fixed: '#002203'
  on-tertiary-fixed-variant: '#0c5216'
  background: '#131313'
  on-background: '#e5e2e1'
  surface-variant: '#353534'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  data-lg:
    fontFamily: JetBrains Mono
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: 0.05em
  data-md:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
  label-caps:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.1em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  gutter: 16px
  margin-edge: 24px
  control-gap: 12px
  canvas-padding: 32px
---

## Brand & Style
The design system is engineered for high-stakes industrial environments where accuracy and safety are paramount. The brand personality is **calm, reliable, and expert**, prioritizing functional clarity over aesthetic flourish. 

The design style is **Modern Industrial**, blending elements of **Minimalism** with **High-Contrast** utilitarianism. It avoids visual clutter to ensure that operators can process machine states at a glance. The interface mimics physical control panels through structured layouts and high-visibility status indicators, creating an emotional response of absolute control and safety. The central focus is the PCB Canvas, which acts as the "source of truth" for the drilling operation.

## Colors
The color palette is strictly functional, utilizing high-contrast pairings to differentiate machine states.

- **Background (#121212):** A deep charcoal that minimizes screen glare in workshop environments and provides a "void" for the PCB canvas to pop.
- **Primary (#FFB300):** Safety Amber. Used for active machinery states, warnings, and "Motors Enabled" indicators. It demands attention without signaling immediate failure.
- **Success (#00C853):** Laboratory Green. Indicates precision alignment, completed tasks, and safe-to-proceed statuses.
- **Danger (#D50000):** Emergency Red. Reserved exclusively for "Abort," "E-Stop," and critical hardware faults.
- **Board Canvas (#1B5E20):** Represents the FR4 substrate. Traces are rendered in high-vis gold, while drill holes use cyan (#00FFFF) for maximum legibility against the green substrate.

## Typography
This design system employs a dual-font strategy to separate instruction from information.

- **Inter (Sans-Serif):** Used for the UI shell, instructions, and navigation. It provides a clean, modern readability that feels professional and approachable.
- **JetBrains Mono (Monospace):** Used for all technical data, including X/Y/Z coordinates, RPM speeds, and machine logs. The fixed-width character spacing ensures that numerical values don't "jump" when updating rapidly during operation.

**Mobile Scaling:** Headlines scale down by 20% on mobile devices, while data-md remains fixed at 14px to ensure critical machine coordinates remain legible.

## Layout & Spacing
The layout uses a **Fixed Grid** model for the control panels (sidebars) and a **Fluid Canvas** for the central PCB view.

- **Central Canvas:** Takes up the maximum available space. It is surrounded by a 32px safe-zone to prevent controls from overlapping the board view.
- **Control Sidebars:** Fixed at 320px width. This ensures that jog controls and data readouts remain in a consistent physical location for muscle memory.
- **Spacing Rhythm:** Based on a 4px baseline. Most components use 16px (4 units) of internal padding to accommodate gloved-finger interactions (tactile feel).
- **Responsive Behavior:** On mobile/tablet, the sidebars collapse into bottom-drawers to keep the PCB Canvas visible at all times.

## Elevation & Depth
This design system avoids traditional shadows in favor of **Tonal Layers** and **Bold Outlines**.

- **Level 0 (Surface):** The background (#121212).
- **Level 1 (Panels):** Slightly lighter charcoal (#1E1E1E) with a 1px solid border (#333333). This defines the workspace without adding visual weight.
- **Active State (Focus):** Elements currently in focus or being "gated" use a 2px stroke of the Primary Amber color.
- **Depth:** Depth is conveyed through "inset" styling for data readouts, making the numerical values feel like they are recessed into a physical console.

## Shapes
The shape language is **Soft (0.25rem)**. 

While the system is industrial, sharp 0px corners are avoided to reduce visual fatigue and give the app a more modern, refined software feel. 
- **Buttons:** 0.25rem (4px) radius.
- **Cards/Panels:** 0.5rem (8px) radius for the container edges.
- **Jog Controls:** Circular (pill) for directional arrows to imply rotation and movement.

## Components

- **Jog Controls:** Large, tactile buttons (min-size 64x64px). They use a subtle inner-gradient to look slightly "raised" and reactive to touch.
- **Linear Stepper:** A progress bar at the top of the viewport tracking: *Load > Align > Dry-run > Drill > Done*. Completed stages turn Success Green; the active stage pulses Primary Amber.
- **Gated Action Buttons:** Critical actions (like "Start Drilling") require a long-press or a two-step "Unlock & Press" interaction to prevent accidental triggers. These are styled with diagonal "hazard" stripes in the background.
- **Status Badges:** High-contrast pills (e.g., "MOTORS LIVE", "ESTOP ENGAGED") using uppercase JetBrains Mono. They should blink at a 1Hz frequency when in a "Warning" state.
- **Input Fields:** Data entry for coordinates uses monospaced text. Fields are "dark-mode" native, with a deep background and bright borders.
- **PCB Canvas:** The substrate uses a matte texture. Drill holes are rendered as vibrant Cyan circles, which turn Green once successfully drilled.