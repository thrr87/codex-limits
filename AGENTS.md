# Project instructions

## User-facing copy

- Write every visible UI string in natural English.
- Prefer short, concrete wording that tells the user what the number means or what they can do next.
- Avoid AI terminology, analytics jargon, statistical labels, hype, canned coaching, and anthropomorphic language.
- Do not expose internal reasoning, implementation notes, TODOs, test data, or debug text in the interface.
- Review all visible text before completing any UI change.

## Visual design

- Use native SwiftUI controls, system typography, semantic colors, and macOS materials.
- Build the burn-down visualization with Apple Swift Charts; do not add a third-party chart dependency.
- Show the remaining percentage only once inside the popover. The separate menu-bar value remains the compact always-visible reading.
- Show a percentage axis and a time axis with restrained grid lines so every trajectory has a clear scale.
- Differentiate forecast series with both color and line style; never rely on color alone.
- Draw the observed usage curve, a straight target path from 100% to the safety buffer, the current projection, the historical projection, and a clear `Now` marker.
- Keep the safety forecast in the calculation layer; communicate its conclusion through the pace status instead of another chart series or band.

## Product boundaries

- Keep the app entirely passive.
- Do not request notification permission or send system notifications.
- Keep the app purely analytical: observe actual usage and explain whether the current pace is sustainable.
- Do not add manual usage modes, planned breaks, schedules, calendars, or intensity profiles.
- Enable launch at login by default and expose a single `Launch at login` toggle in settings.
- Refresh usage on launch, wake, panel open, and every 10 minutes in the background.
- Provide a manual `Refresh` action in the panel.
- Keep the last successful value when refresh fails and show its age in plain English.
