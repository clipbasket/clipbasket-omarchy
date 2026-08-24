# Installing Clipbasket for Omarchy

Free, no account, no licence key, nothing to compile, and nothing to run as
root. The whole install is one Omarchy command.

## Requirements

- Omarchy 4.0 or newer (Quickshell 0.3.1+)
- `sqlite3`, `wl-clipboard`, `jq`, `git`

```sh
pacman -S --needed sqlite wl-clipboard jq git
```

`jq` is not optional: the panel reads history through it, and the CLI derives
default settings from `settings.schema.json` with it.

## Install

```sh
omarchy plugin add https://github.com/clipbasket/clipbasket-omarchy --enable
```

That is all of it. Omarchy clones the repo into
`~/.config/omarchy/plugins/clipbasket.clipboard/`, validates the manifest, and
enables the plugin over shell IPC. It never runs code from the plugin — there is
no install script here, and nothing in this repository asks you to pipe a
download into a shell.

Add `--yes` to skip the confirmation prompts, which is the path for scripts:

```sh
omarchy plugin add https://github.com/clipbasket/clipbasket-omarchy --enable --yes
```

Without `--enable` the plugin lands disabled so you can read the code first —
it is your machine and this is unsandboxed QML and bash. Enable it when you are
ready:

```sh
omarchy plugin enable clipbasket.clipboard right
```

### What you get, and what starts

1. **The bar pill**, in the `right` section unless you name another.
2. **The capture service.** `Service.qml` starts two `wl-paste --watch`
   processes inside `omarchy-shell` the moment the plugin loads. They record
   every copy to SQLite and are killed by the kernel when the shell exits
   (`setpriv --pdeathsig TERM`), so capture runs exactly as long as your shell
   does. There is no daemon to install and no systemd unit of ours on your
   system.
3. **Nothing else.** No settings file is written until you change a setting —
   the panel falls back to the defaults in `settings.schema.json`. No keybinding
   is touched: Omarchy's own clipboard keeps `SUPER + CTRL + V` until you
   explicitly ask otherwise.

The database, image store and settings directory are created on first use.

### The CLI

`bin/clipbasket-omarchy` ships inside the plugin and is not linked onto your
PATH: a plugin folder may not contain symlinks (the validator refuses them), and
the install runs no script that could make one elsewhere. Run it from the plugin
directory:

```sh
cd ~/.config/omarchy/plugins/clipbasket.clipboard
bin/clipbasket-omarchy doctor
```

The rest of this document writes that as `bin/clipbasket-omarchy`, assuming you
have `cd`'d there. If you want it on your PATH, that is your call to make in your
own dotfiles — put a wrapper in `~/.local/bin`, not a symlink inside the plugin.

## Verify

```sh
bin/clipbasket-omarchy doctor
```

Every line is `PASS`, `FAIL`, `WARN`, or `INFO`, and every `FAIL` names the
command that fixes it. The command exits non-zero if anything failed, so it is
safe to use in a script. This is the first thing to run — and to paste — when
something is not working.

`bin/clipbasket-omarchy status` is the short version: what is installed, what is
running, and which key opens the panel.

## Making Clipbasket the default clipboard

Flip **Use Clipbasket for Super+Ctrl+V** in the panel's settings page, or run the
command the toggle runs:

```sh
bin/clipbasket-omarchy make-default
```

This is the only command that edits your Hyprland config, and here is exactly
what it does:

1. **Backs up** `~/.config/hypr/bindings.lua` to
   `~/.local/state/clipbasket/backups/bindings.lua.<timestamp>`. Two runs in the
   same second get separate backups.
2. **Removes any existing Clipbasket block**, then appends exactly one:

   ```lua
   -- >>> clipbasket — managed by `bin/clipbasket-omarchy make-default`. Do not edit by
   -- hand; `bin/clipbasket-omarchy restore-default` deletes this block verbatim.
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
bin/clipbasket-omarchy make-default --key "SUPER + V"
```

Running `make-default` twice produces a byte-identical file. Running it with a
different `--key` replaces the block rather than adding a second one.

## Undoing it

```sh
bin/clipbasket-omarchy restore-default
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
omarchy plugin update clipbasket.clipboard
```

It fetches, shows you a diff, and fast-forwards. An installed plugin is an
ordinary git checkout, so `git -C ~/.config/omarchy/plugins/clipbasket.clipboard
pull` does the same thing if you prefer.

Then restart the shell — Quickshell does not reload QML that is already in
memory, and its file watcher does not cover the plugin directory:

```sh
pkill -f "quickshell -n -p"
setsid systemd-cat -t omarchy-shell -- quickshell -n -p "$OMARCHY_PATH/shell" &
```

Your settings and history are untouched by an upgrade — both live outside the
plugin directory.

## Uninstalling

```sh
cd ~/.config/omarchy/plugins/clipbasket.clipboard
bin/clipbasket-omarchy restore-default   # hand SUPER + CTRL + V back first
omarchy plugin remove clipbasket.clipboard
```

Order matters: `restore-default` needs the CLI, and the CLI lives in the
directory you are about to delete. The capture watchers die with the plugin —
they are children of the shell, not of anything you have to remember to stop.

Your history and settings survive on purpose. Delete them too if you want:

```sh
rm -rf ~/.local/share/clipbasket ~/.config/clipbasket ~/.local/state/clipbasket
```

## Where everything lives

| Path | What |
|---|---|
| `~/.config/omarchy/plugins/clipbasket.clipboard/` | The plugin |
| `~/.config/clipbasket/settings.json` | Settings |
| `~/.local/state/clipbasket/clips.db` | Clip history (SQLite) |
| `~/.local/state/clipbasket/images/`, `thumbs/` | Copied images and their thumbnails |
| `~/.local/state/clipbasket/backups/` | `bindings.lua` backups |
| `~/.local/state/clipbasket/make-default.json` | What `make-default` changed |
| `~/.config/hypr/bindings.lua` | Your keybindings — only the marked block is ours |

Override the settings, database, and bindings paths with `CLIPBASKET_SETTINGS`,
`CLIPBASKET_DB`, and `CLIPBASKET_BINDINGS` respectively. `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `XDG_STATE_HOME` are honoured throughout.

## Troubleshooting

**Nothing appears in the bar.** The shell has not reloaded. Run
`omarchy-shell shell rescanPlugins`, then restart the shell as shown under
Upgrading.

**`find: '/shell/plugins': No such file or directory`.** `OMARCHY_PATH` is unset.
Export it, or run the command from a full desktop session. The CLI resolves it
itself; a bare `omarchy plugin …` will not.

**The panel is empty.** The capture watchers are not running — most often
because the shell has not been restarted since the plugin was added.
`bin/clipbasket-omarchy doctor` counts them and says which of the two is missing.
History starts from the moment capture starts; it cannot recover copies made
before that.

**`SUPER + CTRL + V` does nothing after `make-default`.** Hyprland has the block
in the file but has not loaded it. Run `hyprctl reload`, or log out and back in.
`doctor` distinguishes these two cases explicitly.

**Both overlays open at once.** `omarchy.clipboard` is still enabled. Run
`omarchy plugin disable omarchy.clipboard`, or re-run `make-default` without
`--keep-omarchy-clipboard`.
