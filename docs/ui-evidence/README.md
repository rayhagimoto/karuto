# Running UI evidence

[UI review criteria](../ui-review.md) · [Alpha validation](../alpha-validation.md)

These images were captured from running native AppKit windows. Individual-window captures omit the surrounding desktop and may flatten the appearance of glass/vibrancy.

- [Current capture toolbar](capture-toolbar-current.jpg): separate centered icon/label rows, padded secondary actions, thinner borders and initial fields unfocused. Production window margins are transparent; the screenshot tool uses a white matte.
- [Settings](settings.png): grouped native preferences and sidebar.
- [Preview fixture](preview-fixture.png): production preview controller displaying the local toolbar screenshot as a wide-image fixture; this is a layout check, not a live screen-capture success claim.

- [Dark-backed toolbar fixture](toolbar-dark-fixture.jpg): fixed icon/label rows and footer padding checked against a deliberately dark test matte. The black rectangular matte belongs only to the temporary review app; production panels remain clear.
- [Selection movement fixture](selection-move-fixture.jpg): actual production overlay event handlers moved a 650 × 400 selection without resizing it. The window-only screenshot shows a white matte where desktop content is visible during normal use.

- [Capture options dropdown](capture-options.jpg): running production gear menu with Instant Capture checked and Freeze Display initially unchecked. Native window capture flattens the glass against a white matte.

- [Keyboard Shortcuts settings](keymap-settings.jpg): configurable overlay commands, including confirm/cancel and both session toggles. Captured after live assignment/conflict checks and clearing the temporary toggle binding.
