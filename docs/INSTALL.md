# Installing Clipbasket for Omarchy

Free, no account, no licence key, nothing to compile. The whole install is a
`git clone` plus a few Omarchy CLI calls.

## Requirements

- Omarchy 4.0 or newer (Quickshell 0.3.1+)
- `sqlite3`, `wl-clipboard`, `jq`, `git`

```sh
sudo pacman -S --needed sqlite wl-clipboard jq git
```

`jq` is not optional: the panel reads history through it, and the CLI derives
default settings from `settings.schema.json` with it.

## Install

```sh
curl -fsSL https://clipbasket.com/omarchy/install.sh | bash
```

Or from a clone, which is the same thing:

```sh
git clone https://github.com/Clipbasket/clipbasket-omarchy.git
cd clipbasket-omarchy
./install.sh
```

Preview it first if you like — a dry run prints every command it would run and
changes nothing:

```sh
./install.sh --dry-run
```

### Options

| Flag | Effect |
|---|---|
| `--dry-run` | Print every action, change nothing |
| `--ref <git-ref>` | Install a specific branch, tag, or commit |
| `--section <left\|center\|right>` | Bar section for the widget (default: `right`) |
| `--no-daemon` | Install without starting the capture daemon |
| `--no-enable` | Install without enabling the bar widget |

### What it does, in order

1. Resolves `OMARCHY_PATH` (needed by `omarchy` and `omarchy-shell`, which fail
   with a misleading `find: '/shell/plugins'` error without it) and checks the
   dependencies above, warning rather than aborting on each.
2. Copies or clones the plugin into
   `~/.config/omarchy/plugins/clipbasket.clipboard/`.
3. Creates `~/.config/clipbasket/`, `~/.local/share/clipbasket/`, and
   `~/.local/state/clipbasket/`.
4. Symlinks `~/.local/bin/clipbasket-omarchy` at the CLI in the plugin directory.
5. Seeds `~/.config/clipbasket/settings.json` with the schema defaults — **only
   if the file does not already exist.** An upgrade never touches your settings.
6. Installs and starts the capture daemon's systemd user unit, if the build ships
   one.
7. Runs `omarchy-shell shell rescanPlugins`, then
   `omarchy plugin enable clipbasket.clipboard right`.

It is idempotent. Re-running upgrades in place: the plugin directory is
refreshed, the symlink is repointed, and nothing is duplicated.

**It does not touch your keybindings.** Omarchy's own clipboard keeps
`SUPER + CTRL + V` until you explicitly ask otherwise.

## Verify

```sh
clipbasket-omarchy doctor
```

Every line is `PASS`, `FAIL`, `WARN`, or `INFO`, and every `FAIL` names the
command that fixes it. The command exits non-zero if anything failed, so it is
safe to use in a script. This is the first thing to run — and to paste — when
something is not working.

`clipbasket-omarchy status` is the short version: what is installed, what is
running, and which key opens the panel.

## Making Clipbasket the default clipboard

```sh
clipbasket-omarchy make-default
```

This is the only command that edits your Hyprland config, and here is exactly
what it does:

1. **Backs up** `~/.config/hypr/bindings.lua` to
   `~/.local/state/clipbasket/backups/bindings.lua.<timestamp>`. Two runs in the
   same second get separate backups.
2. **Removes any existing Clipbasket block**, then appends exactly one:

   ```lua
   -- >>> clipbasket — managed by `clipbasket-omarchy make-default`. Do not edit by
   -- hand; `clipbasket-omarchy restore-default` deletes this block verbatim.
   hl.unbind("SUPER + CTRL + V")
   o.bind("SUPER + CTRL + V", "Clipbasket", "omarchy-shell shell toggle clipbasket.clipboard")
   -- <<< clipbasket
   ```

   Everything outside those two markers is passed through byte for byte. Your
   file is never rewritten, reformatted, or regenerated.
3. **Disables `omarchy.clipboard`** so two overlays do not both answer the key —
   unless you pass `--keep-omarchy-clipboard`, or it was already disabled.
4. **Records what it did** in `~/.local/state/clipbasket/make-default.json`.
5. **Mirrors the bound key** into `globalShortcut` in your settings file, so the
   panel can display the shortcut without parsing Lua.
6. Runs `hyprctl reload` (skip it with `--no-reload`).

Use a different key with `--key`:

```sh
clipbasket-omarchy make-default --key "SUPER + V"
```

Running `make-default` twice produces a byte-identical file. Running it with a
different `--key` replaces the block rather than adding a second one.

## Undoing it

```sh
clipbasket-omarchy restore-default
```

1. Backs up `bindings.lua` again.
2. Deletes the block between the markers — and only that.
3. Re-enables `omarchy.clipboard` **only if step 3 of `make-default` was what
   disabled it.** If you had already turned it off yourself, it stays off. This
   is what the state file in `~/.local/state/clipbasket/` is for.
4. Clears the `globalShortcut` mirror, removes the state file, reloads Hyprland.

The result is byte-identical to the file before `make-default` ran. Safe to run
when nothing is bound — it says so and stops.

Preview either command with `--dry-run`; it prints the full file it would write.

## Upgrading

```sh
git -C ~/.config/omarchy/plugins/clipbasket.clipboard pull
omarchy-shell shell rescanPlugins
```

Then restart the shell — Quickshell does not reload QML that is already in
memory, and its file watcher does not cover the plugin directory:

```sh
pkill -f "quickshell -n -p"
setsid systemd-cat -t omarchy-shell -- quickshell -n -p "$OMARCHY_PATH/shell" &
```

Re-running `install.sh` does the same thing and repoints the CLI symlink, which
matters if a release moves it.

## Uninstalling

```sh
clipbasket-omarchy restore-default          # hand SUPER + CTRL + V back first
clipbasket-omarchy disable
rm -rf ~/.config/omarchy/plugins/clipbasket.clipboard
rm -f  ~/.local/bin/clipbasket-omarchy
```

Order matters: `restore-default` needs the CLI, and the CLI lives in the
directory you are about to delete.

Your history and settings survive on purpose. Delete them too if you want:

```sh
rm -rf ~/.local/share/clipbasket ~/.config/clipbasket ~/.local/state/clipbasket
```

## Where everything lives

| Path | What |
|---|---|
| `~/.config/omarchy/plugins/clipbasket.clipboard/` | The plugin |
| `~/.local/bin/clipbasket-omarchy` | CLI symlink |
| `~/.config/clipbasket/settings.json` | Settings |
| `~/.local/share/clipbasket/clips.db` | Clip history (SQLite) |
| `~/.local/state/clipbasket/backups/` | `bindings.lua` backups |
| `~/.local/state/clipbasket/make-default.json` | What `make-default` changed |
| `~/.config/hypr/bindings.lua` | Your keybindings — only the marked block is ours |
| `~/.config/systemd/user/clipbasket-omarchy.service` | Capture daemon unit |

Override the settings, database, and bindings paths with `CLIPBASKET_SETTINGS`,
`CLIPBASKET_DB`, and `CLIPBASKET_BINDINGS` respectively. `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `XDG_STATE_HOME` are honoured throughout.

## Troubleshooting

**Nothing appears in the bar.** The shell has not reloaded. Run
`omarchy-shell shell rescanPlugins`, then restart the shell as shown under
Upgrading.

**`find: '/shell/plugins': No such file or directory`.** `OMARCHY_PATH` is unset.
Export it, or run the command from a full desktop session. Both `install.sh` and
the CLI resolve it themselves; a bare `omarchy plugin …` will not.

**The panel is empty.** The capture daemon is not running. `clipbasket-omarchy
doctor` will say so. History starts from the moment the daemon starts — it cannot
recover copies made before it was running.

**`SUPER + CTRL + V` does nothing after `make-default`.** Hyprland has the block
in the file but has not loaded it. Run `hyprctl reload`, or log out and back in.
`doctor` distinguishes these two cases explicitly.

**Both overlays open at once.** `omarchy.clipboard` is still enabled. Run
`omarchy plugin disable omarchy.clipboard`, or re-run `make-default` without
`--keep-omarchy-clipboard`.
