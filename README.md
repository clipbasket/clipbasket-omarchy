# clipbasket-omarchy

An [Omarchy](https://omarchy.org) shell plugin for [Clipbasket](https://clipbasket.com) —
a bar widget plus a native popup panel, for Omarchy Quattro (Quickshell).

> **Status: prototype.** This currently reads Omarchy's own clipboard history as
> stand-in data. It does not yet drive Clipbasket, because the Clipbasket Linux
> port is still in progress (see `docs/linux-port-prd.md` in the app repo). The
> plugin mechanics below are proven working; the data source is a placeholder.

MIT-licensed on purpose: this is thin glue. Clipbasket itself is a separate,
closed-source application installed from the AUR — the same shape as other
Omarchy plugins that wrap proprietary apps (Proton Pass, Obsidian, Spotify).

## What it does

- A monochrome bar pill (Omarchy's own `BarIconButton`, so it themes itself).
- A popup panel built from Omarchy's `Panel` / `KeyboardPanel` / `PanelKeyCatcher`
  chrome — native anchoring, animation, theming, Esc-to-close, Tab panel-switching.
- Search, type filters (All / Text / Links / Images / Files / Saved), clip rows
  with a hover **Copy** action.
- A settings page with the options that are meaningful on Linux/Wayland;
  persisted to `~/.local/state/clipbasket-demo/settings.json`.
- Summonable by compositor keybind through the shell's IPC.

## Install (development)

```sh
git clone https://github.com/Clipbasket/clipbasket-omarchy.git \
  ~/.config/omarchy/plugins/dev.clipbasket.demo
omarchy-shell shell rescanPlugins
omarchy plugin enable dev.clipbasket.demo right
```

Optional keybind, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("CTRL + ALT + V", "Clipbasket", "omarchy-shell shell toggle dev.clipbasket.demo")
```

## Development notes

Hard-won specifics that are not documented elsewhere, discovered while building
this against Omarchy 4.0.0 / Quickshell 0.3.1:

1. **Editing QML requires a full shell restart.** `omarchy-shell shell rescanPlugins`
   registers a newly added plugin, but does **not** reload QML already in memory,
   and Quickshell's file watcher does not cover `~/.config/omarchy/plugins/`. The
   dev loop is:
   ```sh
   pkill -f "quickshell -n -p"
   setsid systemd-cat -t omarchy-shell -- quickshell -n -p "$OMARCHY_PATH/shell" &
   ```
   Symptom if you forget: runtime errors citing line numbers that no longer exist.

2. **`bar.shellQuote()` does not exist.** It is documented in Omarchy's
   `shell/plugins/bar/README.md`, but calling it throws
   `TypeError: Property 'shellQuote' ... is not a function`. Quote locally instead.

3. **Export `OMARCHY_PATH`** when driving the plugin CLI outside a full desktop
   session, or commands fail with a misleading `find: '/shell/plugins'` error.

4. **Use `\uXXXX` escapes for Nerd Font glyphs**, not literal characters. Literal
   PUA codepoints get stripped by some editors and transports, and an empty
   `text: ""` silently collapses a bar widget to zero width — an invisible widget
   with no error.

5. **Bar widgets that own a panel must expose the shape contract** the bar's
   popout coordinator expects: `open()`, `close()`, `opened`, plus
   `popoutSwitchClosing` / `closeForPopoutSwitch()` forwarded from the panel.

## Layout

| File | Purpose |
|---|---|
| `manifest.json` | Plugin declaration (`kinds: ["bar-widget"]`, entry point, bar metadata) |
| `BarWidget.qml` | The bar pill; owns the panel and forwards the shape contract |
| `Panel.qml` | The popup: clip list and settings views |
