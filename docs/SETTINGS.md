# Settings

Clipbasket for Omarchy keeps its settings in a single JSON file:

```
~/.config/clipbasket/settings.json
```

(`$XDG_CONFIG_HOME/clipbasket/settings.json` if you set that, or wherever
`CLIPBASKET_SETTINGS` points.)

Edit it in the panel's settings page, or with a text editor — nothing caches it.
[`settings.schema.json`](../settings.schema.json) in the repository root is the
authoritative contract: names, types, defaults, ranges, and the reasons behind
the settings that are deliberately absent.

There is no settings file until something writes one. Nothing seeds it at
install time, and nothing needs to: every key falls back to the default in the
schema, so a fresh install runs on defaults and the file appears the first time
you change a setting in the panel.

Write one out explicitly if you would rather start from a full file — from the
plugin directory, `~/.config/omarchy/plugins/clipbasket.clipboard/`:

```sh
bin/clipbasket-omarchy settings-init          # only if the file is missing
bin/clipbasket-omarchy settings-init --force  # overwrite with defaults
```

Defaults are derived from the schema, so they exist in exactly one place.

Keys the app does not recognise are left alone rather than stripped, so
downgrading never destroys a newer install's settings.

## The defaults

```json
{
  "closePanelAfterAction": true,
  "globalShortcut": "",
  "ignoreConfidentialCopies": true,
  "maxClips": 1000,
  "pasteSelectedClipImmediately": false
}
```

## General

### `globalShortcut` — string, read-only, default `""`

The key that opens Clipbasket. Empty means **not bound**.

On Wayland the compositor owns keybindings, so this field is a *mirror*, not a
control. The binding lives in `~/.config/hypr/bindings.lua`, between the
`-- >>> clipbasket` and `-- <<< clipbasket` markers, and
The **Use Clipbasket for Super+Ctrl+V** toggle in the settings page, and
`bin/clipbasket-omarchy make-default` behind it, write both the block and this
field together.
`restore-default` clears both.

The settings page displays it and must never write it: writing here would
desynchronise the field from the file that actually decides the binding.

It defaults to empty because a fresh install deliberately does not take a key.
Omarchy's own clipboard keeps `SUPER + CTRL + V` until you ask otherwise.

### Use Clipbasket for Super+Ctrl+V — a control, not a setting

The toggle underneath the shortcut in the settings page is the button form of
`make-default` / `restore-default`. It is deliberately **not** a key in
`settings.json`: the compositor decides what the key does, so the truth is the
managed block in `~/.config/hypr/bindings.lua` plus the marker file at
`~/.local/state/clipbasket/make-default.json`. Storing a second copy of that in
the settings file would create two answers to one question.

The panel reads its state from the marker file every time it opens, so turning
it on here and running `restore-default` in a terminal cannot disagree.

## History

### `maxClips` — integer, default `1000`, range `50`–`100000`

How many clips to keep. Most people copy 20–50 items a day, so 500 is roughly two
weeks, 1000 roughly a month, 2000 roughly two months.

Out-of-range values are clamped, not rejected — the same behaviour as the macOS
app, so a hand-edited file never fails to load.

Pinned and saved clips are exempt from the prune. Lowering this number never
deletes something you deliberately kept.

The capture service passes this to `clipbasket-capture` as `CLIPBASKET_MAX_CLIPS`
when it starts the watchers. A process's environment is fixed at spawn, so
changing this number restarts the two watchers — a copy made in that instant is
the one thing a retention change can cost you.

### `ignoreConfidentialCopies` — boolean, default `true`

Never record items marked confidential.

On Wayland that means skipping clipboard offers carrying the
`x-kde-passwordManagerHint` MIME type, and copies made while
`CLIPBOARD_STATE=sensitive`. In practice: passwords copied out of a password
manager do not land in your history.

Defaults on. A privacy default should never need to be discovered.

## Behavior

### `closePanelAfterAction` — boolean, default `true`

Hide the popup after you select or copy a clip.

The macOS app splits this into `closePanelAfterSelection` and
`closePanelAfterCopy` but keeps them in lockstep through the UI, so there is one
setting here. Both old names are accepted as aliases when reading a file written
by an older build.

Turning this off disables auto-paste, which cannot work while the panel still
holds keyboard focus.

### `pasteSelectedClipImmediately` — boolean, default `false`

After picking a clip, paste it into the focused window rather than only copying
it.

Wayland has no system-wide synthetic-input API, so this shells out to
[`wtype`](https://github.com/atx/wtype) (or `ydotool` with its daemon running).
If neither is installed the setting is unavailable, not merely off — the panel
should say so rather than silently doing nothing.

Requires `closePanelAfterAction` to be on. This constraint is ported verbatim
from the macOS app: pasting while the panel still has focus pastes into the
panel.

**Known gap: a paste that fails at runtime is silent.** The panel reports
`wtype` being *absent* — the setting reads "Install wtype to enable automatic
paste" and cannot be switched on. But if `wtype` is installed and the keystroke
itself fails, nothing is shown. By the time the paste runs the panel has closed,
which is a precondition of pasting at all, so there is no surface left to render
a warning on; the macOS app shows one because it owns a window that is still
there. Reporting it properly needs a desktop notification, which would mean a
new dependency for one error path, so it is deliberately not done rather than
overlooked. The clip is still on the clipboard in every case — a failed
auto-paste costs a Ctrl+V, not the copy.

## Settings that are not here

These exist in the macOS and Windows apps and are absent on purpose. They are not
oversights, and they are not coming.

### Theme

Omarchy owns theming. The panel is built from Omarchy's own `Style` tokens and
follows whatever theme you have active. An app-level Light/Dark/System override
would fight the desktop and produce a widget that does not match the bar it sits
in.

Change your theme in Omarchy; Clipbasket follows.

### Open at cursor on shortcut

Nothing could consume it. The popup is a layer-shell surface anchored to the bar
pill by Omarchy's own `Panel` chrome, which positions it relative to the widget,
not the pointer — the plugin has no supported way to place it at the cursor. The
toggle described an intention rather than a behaviour, so it was removed instead
of left in place looking adjustable.

### Launch at login

There is nothing to opt out of. Capture is two `wl-paste --watch` processes that
`Service.qml` starts inside `omarchy-shell` and that the kernel kills when the
shell exits, so it runs exactly when your desktop does.

This setting existed in an earlier build of this port, backed by a systemd user
unit, and it was inert: nothing read the key it wrote. The unit and the setting
were both removed rather than repaired — the shell owning capture is the correct
answer on this platform, and a second capture path writing to the same database
would be a worse bug than any gap it closed.

### Automatic update checks

The marketplace owns updates here. The update mechanism is:

```sh
omarchy plugin update clipbasket.clipboard
```

There is nothing for the app to check, and a plugin that phoned home for version
numbers on a system with a package manager would be doing the wrong thing twice.

### Accessibility / paste permission

macOS gates synthetic keystrokes behind an Accessibility grant, so the app has a
whole permission flow around it. Wayland has no equivalent: `wtype` either works
or is not installed. `bin/clipbasket-omarchy doctor` reports which.

### Licence key

Clipbasket for Omarchy is free. There is no key, no trial, no expiry, and no
check. The macOS and Windows apps are paid, which is what funds this one, and
that is the last you will hear about it from inside the product.

## For the panel implementation

The settings page binds to `settings.schema.json`. Notes worth reading before
wiring it up:

- `x-clipbasket.groups` gives the section order and titles the page should
  render: General, History, Behavior.
- `x-clipbasket.aliases` on a property lists older key names to accept when
  reading. Write only the canonical name.
- `x-clipbasket.requires` encodes cross-setting constraints
  (`pasteSelectedClipImmediately` requires `closePanelAfterAction`). Enforce them
  at write time and surface `x-clipbasket.validation[].message`.
- `x-clipbasket.requiresBinaries` lists what must be on `PATH` for a setting to
  do anything. Render those rows as unavailable with `unavailableLabel` rather
  than as a toggle that does nothing.
- `readOnly: true` means display, never write. Currently only `globalShortcut`.
- `x-clipbasket.clampOutOfRange` means clamp to `minimum`/`maximum` on read
  rather than rejecting the file.
