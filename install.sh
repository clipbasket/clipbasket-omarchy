#!/usr/bin/env bash
#
# Clipbasket for Omarchy — one-command installer.
#
#   curl -fsSL https://clipbasket.com/omarchy/install.sh | bash
#   ./install.sh                       # from a local clone
#   ./install.sh --dry-run             # print every step, change nothing
#
# Installs the Quickshell plugin into ~/.config/omarchy/plugins/, links the
# `clipbasket-omarchy` CLI onto PATH, seeds default settings, starts the
# capture daemon, and enables the bar widget.
#
# Deliberately idempotent: re-running upgrades in place and never duplicates
# anything. It does NOT touch your keybindings — Omarchy's own clipboard keeps
# SUPER + CTRL + V until you run `clipbasket-omarchy make-default`.

set -euo pipefail

readonly PLUGIN_ID="clipbasket.clipboard"
readonly REPO_URL="${CLIPBASKET_REPO_URL:-https://github.com/Clipbasket/clipbasket-omarchy.git}"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

PLUGIN_DIR="$CONFIG_HOME/omarchy/plugins/$PLUGIN_ID"
CLIPBASKET_CONFIG_DIR="$CONFIG_HOME/clipbasket"
CLIPBASKET_STATE_DIR="$STATE_HOME/clipbasket"
BIN_DIR="$HOME/.local/bin"

DRY_RUN=0
GIT_REF=""
BAR_SECTION="right"
START_DAEMON=1
ENABLE_WIDGET=1

# ---------------------------------------------------------------- output ----

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

step()  { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Print a command the way a human could paste it back in.
quoted() {
  local out="" arg
  for arg in "$@"; do
    out+="${out:+ }$(printf '%q' "$arg")"
  done
  printf '%s' "$out"
}

# Run a mutating command, or describe it under --dry-run.
run() {
  if (( DRY_RUN )); then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(quoted "$@")"
    return 0
  fi
  "$@"
}

# Same, but the caller tolerates failure.
run_soft() {
  if (( DRY_RUN )); then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(quoted "$@")"
    return 0
  fi
  "$@" || return $?
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Clipbasket for Omarchy — installer

Usage: install.sh [options]

Options:
  --dry-run            Print every action without changing anything.
  --ref <git-ref>      Install a specific branch, tag, or commit.
  --section <name>     Bar section for the widget: left, center, right.
                       (default: right)
  --no-daemon          Install without starting the capture daemon.
  --no-enable          Install without enabling the bar widget.
  -h, --help           Show this help.

Environment:
  CLIPBASKET_REPO_URL  Override the git remote to install from.
  OMARCHY_PATH         Omarchy checkout; auto-detected when unset.

After installing, run `clipbasket-omarchy doctor` to verify the setup.
EOF
}

# ------------------------------------------------------------ arguments ----

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --ref)       [[ $# -ge 2 ]] || die "--ref needs a value"; GIT_REF="$2"; shift 2 ;;
    --ref=*)     GIT_REF="${1#*=}"; shift ;;
    --section)   [[ $# -ge 2 ]] || die "--section needs a value"; BAR_SECTION="$2"; shift 2 ;;
    --section=*) BAR_SECTION="${1#*=}"; shift ;;
    --no-daemon) START_DAEMON=0; shift ;;
    --no-enable) ENABLE_WIDGET=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
done

case "$BAR_SECTION" in
  left|center|right) ;;
  *) die "--section must be left, center, or right (got: $BAR_SECTION)" ;;
esac

# ---------------------------------------------------------- preflight ------

step "Checking the environment"

if [[ "$(uname -s)" != "Linux" ]]; then
  # A dry run changes nothing, so let it preview from anywhere — that is how the
  # script gets exercised on a machine that is not an Omarchy box.
  if (( DRY_RUN )); then
    warn "Not Linux ($(uname -s)); continuing because this is a dry run."
  else
    die "Clipbasket for Omarchy runs on Linux only. \
The macOS and Windows apps live at https://clipbasket.com."
  fi
fi

if [[ "$(id -u)" == "0" ]]; then
  die "Do not run this as root. It installs into your own \$HOME."
fi

# `omarchy plugin` and `omarchy-shell` shell out to \$OMARCHY_PATH/shell/plugins
# and fail with a misleading `find: '/shell/plugins'` error when the variable is
# unset — which it is outside a full desktop session.
resolve_omarchy_path() {
  local candidate
  for candidate in \
      "${OMARCHY_PATH:-}" \
      "$DATA_HOME/omarchy" \
      "$HOME/.local/share/omarchy" \
      "/usr/share/omarchy" \
      "/usr/lib/omarchy"; do
    [[ -n "$candidate" && -d "$candidate/shell" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

if omarchy_path="$(resolve_omarchy_path)"; then
  export OMARCHY_PATH="$omarchy_path"
  ok "Omarchy found at $OMARCHY_PATH"
else
  warn "Could not locate an Omarchy checkout (looked for a directory containing shell/)."
  warn "Set OMARCHY_PATH and re-run if the plugin steps below fail."
fi

missing=()
for tool in git sqlite3 jq; do
  have "$tool" || missing+=("$tool")
done
have wl-copy || missing+=("wl-clipboard")
if (( ${#missing[@]} )); then
  warn "Missing: ${missing[*]}"
  warn "Install them with: sudo pacman -S --needed ${missing[*]}"
  warn "Continuing — \`clipbasket-omarchy doctor\` will report what is still absent."
else
  ok "sqlite3, jq, wl-clipboard, git present"
fi

for cmd in omarchy omarchy-shell; do
  have "$cmd" || warn "\`$cmd\` is not on PATH; plugin registration will be skipped."
done

# -------------------------------------------------------------- source -----

# Where the plugin files come from: the clone this script lives in, when it has
# one, otherwise a fresh clone from the remote.
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
fi

source_is_local=0
if [[ -n "$script_dir" && -f "$script_dir/manifest.json" ]]; then
  source_is_local=1
fi

step "Installing the plugin into $PLUGIN_DIR"

run mkdir -p -- "$(dirname -- "$PLUGIN_DIR")"

if (( source_is_local )) && [[ "$script_dir" != "$PLUGIN_DIR" ]]; then
  # Copy the working tree, minus git metadata. `cp -a source/. dest/` keeps the
  # destination directory itself and overwrites file-by-file, so re-running is
  # an upgrade rather than a nested copy.
  info "Copying from $script_dir"
  run mkdir -p -- "$PLUGIN_DIR"
  run rm -rf -- "$PLUGIN_DIR/.git"
  if have rsync; then
    run rsync -a --delete --exclude '.git' -- "$script_dir/" "$PLUGIN_DIR/"
  else
    run cp -a -- "$script_dir/." "$PLUGIN_DIR/"
    run rm -rf -- "$PLUGIN_DIR/.git"
  fi
  ok "Plugin files copied"
elif (( source_is_local )); then
  ok "Already running from $PLUGIN_DIR — nothing to copy"
elif [[ -d "$PLUGIN_DIR/.git" ]]; then
  info "Updating the existing clone"
  run git -C "$PLUGIN_DIR" fetch --quiet origin
  if [[ -n "$GIT_REF" ]]; then
    run git -C "$PLUGIN_DIR" checkout --quiet "$GIT_REF"
    run_soft git -C "$PLUGIN_DIR" merge --ff-only --quiet "origin/$GIT_REF" || true
  else
    run git -C "$PLUGIN_DIR" pull --ff-only --quiet
  fi
  ok "Plugin updated"
else
  if [[ -e "$PLUGIN_DIR" ]]; then
    die "$PLUGIN_DIR exists but is not a git clone. Move it aside and re-run."
  fi
  info "Cloning $REPO_URL"
  if [[ -n "$GIT_REF" ]]; then
    run git clone --quiet --branch "$GIT_REF" -- "$REPO_URL" "$PLUGIN_DIR"
  else
    run git clone --quiet -- "$REPO_URL" "$PLUGIN_DIR"
  fi
  ok "Plugin cloned"
fi

# ---------------------------------------------------------------- dirs -----

step "Creating directories"
# No data dir: the history is state (regenerable), and lives under
# XDG_STATE_HOME with the images, thumbnails and backups.
run mkdir -p -- "$CLIPBASKET_CONFIG_DIR" "$CLIPBASKET_STATE_DIR" "$BIN_DIR"
ok "config: $CLIPBASKET_CONFIG_DIR"
ok "state:  $CLIPBASKET_STATE_DIR"

# ----------------------------------------------------------------- cli -----

step "Linking the clipbasket-omarchy CLI"

cli_source="$PLUGIN_DIR/bin/clipbasket-omarchy"
cli_link="$BIN_DIR/clipbasket-omarchy"

if (( DRY_RUN )) || [[ -f "$cli_source" ]]; then
  run chmod +x -- "$cli_source"
  # A symlink is replaced wholesale so an upgrade that moved the CLI still lands
  # on the right target; a real file left by an older install is backed up.
  if [[ -e "$cli_link" && ! -L "$cli_link" ]]; then
    warn "$cli_link exists and is not a symlink; leaving it alone."
  else
    run ln -sfn -- "$cli_source" "$cli_link"
    ok "$cli_link -> $cli_source"
  fi
else
  warn "bin/clipbasket-omarchy not found in the installed plugin; skipping the CLI link."
fi

case ":${PATH}:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add it to ~/.bashrc:"
     warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ------------------------------------------------------------ settings -----

step "Seeding default settings"

settings_file="$CLIPBASKET_CONFIG_DIR/settings.json"
if [[ -f "$settings_file" ]]; then
  ok "Keeping your existing $settings_file"
elif (( DRY_RUN )); then
  printf '    %s[dry-run]%s write defaults to %s\n' "$C_DIM" "$C_RESET" "$settings_file"
elif [[ -x "$cli_source" ]]; then
  if "$cli_source" settings-init; then
    : # settings-init prints its own confirmation; saying it twice reads like a bug
  else
    warn "Could not seed settings; the panel will fall back to built-in defaults."
  fi
else
  warn "CLI unavailable; skipping settings seed (the panel uses built-in defaults)."
fi

# -------------------------------------------------------------- daemon -----

if (( START_DAEMON )); then
  step "Starting the capture daemon"

  unit_source=""
  for candidate in \
      "$PLUGIN_DIR/service/clipbasket-omarchy.service" \
      "$PLUGIN_DIR/service/clipbasket.service"; do
    [[ -f "$candidate" ]] && { unit_source="$candidate"; break; }
  done

  if [[ -n "$unit_source" ]] && have systemctl; then
    unit_name="$(basename -- "$unit_source")"
    unit_dir="$CONFIG_HOME/systemd/user"
    run mkdir -p -- "$unit_dir"
    run install -m 0644 -- "$unit_source" "$unit_dir/$unit_name"
    run systemctl --user daemon-reload
    if run_soft systemctl --user enable --now -- "$unit_name"; then
      ok "$unit_name enabled and started"
    else
      warn "systemd could not start $unit_name. Check: systemctl --user status $unit_name"
    fi
  elif [[ -x "$PLUGIN_DIR/bin/clipbasket-daemon" ]]; then
    if pgrep -f "$PLUGIN_DIR/bin/clipbasket-daemon" >/dev/null 2>&1; then
      ok "Daemon already running"
    elif run_soft setsid -f -- "$PLUGIN_DIR/bin/clipbasket-daemon" >/dev/null 2>&1; then
      ok "Daemon started"
    else
      warn "Could not start the daemon. Run it by hand to see why:"
      warn "  $PLUGIN_DIR/bin/clipbasket-daemon"
    fi
  else
    warn "No capture daemon found yet (service/ or bin/clipbasket-daemon)."
    warn "History will stay empty until it ships. Everything else is installed."
  fi
else
  info "Skipping the daemon (--no-daemon)."
fi

# ------------------------------------------------------------- omarchy -----

if (( ENABLE_WIDGET )); then
  step "Registering the plugin with Omarchy"

  if have omarchy-shell; then
    run_soft omarchy-shell shell rescanPlugins || warn "rescanPlugins failed (is the shell running?)"
    ok "Plugin list rescanned"
  else
    warn "omarchy-shell not found; skipping rescanPlugins."
  fi

  if have omarchy; then
    if run_soft omarchy plugin enable "$PLUGIN_ID" "$BAR_SECTION"; then
      ok "Bar widget enabled in the $BAR_SECTION section"
    else
      warn "\`omarchy plugin enable $PLUGIN_ID $BAR_SECTION\` failed. Run it by hand for the error."
    fi
  else
    warn "omarchy not found; enable the widget with:"
    warn "  omarchy plugin enable $PLUGIN_ID $BAR_SECTION"
  fi
else
  info "Skipping widget registration (--no-enable)."
fi

# --------------------------------------------------------------- outro -----

printf '\n'
step "Installed"
cat <<EOF

  Clipbasket is in your bar. Omarchy's built-in clipboard keeps
  ${C_BOLD}SUPER + CTRL + V${C_RESET} — Clipbasket does not take it unless you ask.

  Next steps

    ${C_BOLD}clipbasket-omarchy doctor${C_RESET}          Check everything is wired up
    ${C_BOLD}clipbasket-omarchy make-default${C_RESET}    Put Clipbasket on SUPER + CTRL + V
    ${C_BOLD}clipbasket-omarchy status${C_RESET}          See what is enabled right now

  Editing QML? Quickshell will not reload it in place — restart the shell:

    pkill -f "quickshell -n -p"
    setsid systemd-cat -t omarchy-shell -- quickshell -n -p "\$OMARCHY_PATH/shell" &

EOF

if (( DRY_RUN )); then
  printf '%sThis was a dry run — nothing on disk changed.%s\n' "$C_DIM" "$C_RESET"
fi
