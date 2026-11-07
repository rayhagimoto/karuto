# Alpha UI review

[Project](../README.md) · UI research

## Acceptance criteria

A build passing tests is not sufficient for UI acceptance. Inspect the running app at native scale and compare it to the research reference. Use actual capture artifacts for preview checks.

- Capture toolbar: translucent rounded surfaces without a decorative outline, with an evenly inset mode-selection tile, consistent icon size, balanced vertical padding, regular-weight labels, aligned dimensions panel, no clipped controls.
- Keyboard focus: opening capture must not focus an empty numeric field or intercept unrelated typing into it. Tab navigation and dimension editing remain available.
- Actions: compact, consistent styling; visible disabled states; no stock raised buttons floating over arbitrary desktop content.
- Preview: thumbnail is the main content, preserves aspect ratio, and does not waste most of the panel on letterboxing. Copy/save/reveal/dismiss actions use consistent compact icon treatments with accessible names and tooltips.
- Settings: stable window size, readable grouped controls, consistent spacing and native keyboard behavior. Opening settings from selection must dismiss the higher-level selection overlays.
- Recording controls: same color, spacing and action treatment as capture; clear stop/cancel distinction.

## User feedback incorporated

The initial generic settings launch did not meet the requested interface. Later photos showed cramped toolbar icons, an overly bright selection block and border, an intrusive dimension-field focus ring, detached stock buttons, and a preview with a large empty letterbox. These are implementation defects to correct, not limitations to excuse by calling the app an alpha.

Reference settings imagery in the research is not a reliable latest-version pixel reference. Settings is a native adaptation. Deferred OCR/editor/cloud controls are omitted rather than shown as nonfunctional copies.

## Glass refinement

The user rejected the first solid-charcoal correction as still too heavy. The intended reference is dark translucent glass with muted labels and a subtle, evenly inset selection tile. The broad second instruction bar is not part of the reference hierarchy and should be reduced to a subordinate compact control group. Native blur must remain readable over bright content. Opening the toolbar must never automatically select dimension text; ordinary user-initiated text editing remains supported.

Saved images in `ui-evidence/` show the running interface at the time they were captured. Window-only images can omit surrounding desktop/vibrancy context; user-supplied screen photos are also used to assess the composited appearance. Preview verification may use a local fixture through the production preview controller when Screen Recording permission is unavailable; that is not evidence of a successful live capture.

## Alignment, input and rendering corrections

Mode icons and labels now use separate constrained views, with a fixed icon row and one common label baseline. Footer content has 12-point horizontal and 6-point vertical insets. Surfaces use native NSGlassEffectView on macOS 26 and newer, with a native visual-effect fallback on older supported versions. No painted charcoal tint or decorative border is added. Production panel backgrounds remain clear; the dark rectangular background used for edge inspection exists only in the temporary review harness.

Selection artwork is a retained Core Animation layer tree with implicit animations disabled. Unchanged displays and text do not get rewritten. Mouse release commits the final geometry. A 1% alpha backing prevents the transparent selection interior from losing mouse input to underlying windows. See [performance evidence](selection-performance.md).

The selected mode uses a subtle custom tile and brighter icon/label. Native button-cell pressed/toggle highlighting remains disabled. The user’s annotated feedback identifies unequal tile-to-panel gaps: the side inset is the reference, and top and bottom must match it. Removing the tile was an overly broad interpretation of that feedback.

## Equal tile inset verification

The inherited `NSButton.alignmentRectInsets` extended the custom button frames above their Auto Layout alignment rectangles. The first measured layout had a 5-point left/bottom inset but only 0–1 points above the tile, depending on its icon. `CaptureModeButton` now returns zero alignment insets, so its actual frame matches its constrained frame. An offscreen harness using the production `makeToolbar` layout verified a 500 × 64 mode surface, six 80 × 54 button frames at y=5, and exactly 5 points on the top, bottom, first left edge, and last right edge. All labels share the same row and font baseline. The custom selected tile radius is 11 points, concentric with the 16-point surface radius and 5-point inset. No visible test window was opened for these measurements.

## Preferences and keymap visual system

Preferences uses a transparent 900 × 680 window with a native glass content surface, a 220-point sidebar, and 28-point content margins. Typography uses the system font without custom kerning: 24-point page titles, 13-point controls/body, and 12-point secondary text. Navigation rows are 44 points; keymap rows are 56 points with 32-point controls and wrapped action labels. Native glass provides its own edge treatment. Recording setup uses the same style in a 500 × 620 panel.

The overlay retains its verified 80 × 54 mode tiles and equal 5-point inset. Its footer uses measured system-font text centering, and its native menu uses a 14-point system font. Controls are hosted inside each native glass view’s contentView. See [Apple’s native glass view](https://developer.apple.com/documentation/appkit/nsglasseffectview).

Preferences is intentionally visible to ScreenshotX capture and selectable as a window. Capture controls, overlays, and previews remain excluded; the exception is a live window-ID allowlist, not a process-wide inclusion.

## Toolbar movement and menu placement

The toolbar has no dedicated drag handle. A primary-button pan anywhere in its view hierarchy moves the panel; native delayed event delivery preserves ordinary button clicks and dimension-field editing. Dragging does not select a capture mode or trigger an action. Placement is clamped to the current monitor’s usable bounds.

The options menu is measured before presentation and has a 320-point minimum width. Its top-left screen anchor is calculated from the gear button, the menu’s height, and the monitor’s visible frame: open below when it fits, otherwise above; if neither fits, use the larger space. Horizontal positioning is clamped too. The native menu retains its normal keyboard navigation, checkmarks, and key equivalents.
