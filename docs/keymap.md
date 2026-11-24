# Keyboard configuration and capture preferences

[Project](../README.md) · [Architecture](agents/architecture.md) · [Validation](alpha-validation.md)

## Capture mode preferences

The capture toolbar saves the selected region, timer, and Instant Capture separately for Snapshot and Screen Recording. The timer defaults to off. Freeze Display applies to still snapshots with the timer off. When an option changes whether selection uses frozen or live content, Karuto reopens the selection overlay with the new source.

## Command registry

`ShortcutAction` is the single registry for stable action IDs, titles, scope, and default bindings. `ShortcutBinding` stores a physical key code and normalized Command/Control/Option/Shift flags. Labels use the active keyboard layout. Return and keypad Enter are normalized to the same configurable binding; repeat and modifier-only events cannot trigger actions.

| Context | Actions | Assigned defaults |
| --- | --- | --- |
| Global | Open toolbar, previous area, restore last capture, stop capture | Open toolbar: Control–Shift–2 |
| Karuto active, including overlay | Preferences, keyboard shortcuts, close Preferences, quit | Command–comma, Command–Option–comma, Command–W, Command–Q |
| Capture selection | Confirm, cancel, select last region, undo/redo annotation, Instant Capture, Freeze Display, OCR, capture mode, region, three-second timer toggle | Return, Escape, Command–R, Command–Z, Command–Shift–Z respectively for the first five actions |

With Instant Capture off, the overlay offers **Copy screenshot without saving** (Command–C) and **Save screenshot to the Save folder** (Command–S) for selected Area, Window, and Fullscreen snapshots. Both bindings can be changed or cleared. OCR and text fields keep their text-copy behavior.

Recording setup uses the configured confirm/cancel actions too. Native macOS menu navigation, text editing, file dialogs, and system shortcuts remain platform behavior; they are not additional Karuto bindings. Bare printable overlay keys do not interrupt typing dimensions. Global and application bindings require Command, Control, or Option to avoid intercepting ordinary typing.

## Persistence and validation

`KeymapConfiguration` is a versioned JSON value in UserDefaults (`keymap.v1`), keyed by action ID. Missing actions inherit their defaults, so new commands can be added without discarding existing assignments. Explicit unassignment is represented separately from a missing action. Existing legacy capture-shortcut choices migrate when no keymap is stored. Invalid persisted values fall back safely without crashing.

All current action scopes overlap during capture, so duplicate chords are rejected. `KeymapController` validates proposed changes, acquires new global registrations, then commits the configuration and updates UI/menu labels. `GlobalShortcut` retains unchanged registrations and rolls back newly acquired registrations if any addition fails. A failed edit does not overwrite saved bindings. Global registration failure can be repaired through the GUI without restarting.

## Recording and dispatch

The Preferences editor temporarily unregisters global hotkeys while recording a replacement, allowing an existing global chord to be recorded. Its event monitor consumes input before normal app dispatch. A visible Cancel Recording button allows Escape itself to be assigned. Leaving the section, closing the window, or losing focus ends recording and restores registrations; restoration errors are reported.

Carbon dispatches global actions. The application monitor dispatches application actions. The overlay monitor dispatches overlay actions. Each route checks its context and avoids duplicate handling. Native popup menus own their keys while tracking; recording setup owns confirm/cancel while modal. The menus and buttons remain usable if all bindings are cleared.

## Adding a command

Add a stable `ShortcutAction` case with metadata and a default (usually unassigned), then add its dispatch implementation in the owner of its scope. The GUI enumerates the registry, and persistence/conflict checks use it directly. Do not add independent key-code checks or button/menu key equivalents outside this registry. Add behavior coverage for the action and any new context restrictions.
