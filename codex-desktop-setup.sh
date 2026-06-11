#!/usr/bin/env bash
#
# codex-desktop-setup.sh — One-shot setup for Codex Desktop on Linux (Debian/Ubuntu).
#
# Reproduces the full working setup:
#   - build deps (apt + Rust) and a fresh build/install of the .deb
#   - Sparkle "Oops" fix applied to the build source (idempotent)
#   - Computer Use UI enabled + ydotool input backend + AT-SPI + window targeting
#   - Browser Use (bundled, comes with the package)
#   - Codex CLI installed/updated to latest at /usr/local
#   - CODEX_CLI_PATH pinned for GUI launches (fixes "Unable to locate Codex CLI binary")
#   - warm-start handoff disabled (so closing the app really quits)
#
# Safe to re-run. Tested on Ubuntu 26.04. Requires sudo for apt/dpkg/npm -g.
#
# Usage:
#   bash codex-desktop-setup.sh                 # clone fresh + full setup
#   REPO_DIR=~/sites/codex-desktop-linux bash codex-desktop-setup.sh   # use existing checkout
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Tunables (override via env)
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/ilysenko/codex-desktop-linux.git}"
REPO_DIR="${REPO_DIR:-$HOME/sites/codex-desktop-linux}"
CLI_PREFIX="${CLI_PREFIX:-/usr/local}"               # codex CLI install prefix -> $CLI_PREFIX/bin/codex
CODEX_CLI_PATH_VALUE="${CODEX_CLI_PATH_VALUE:-$CLI_PREFIX/bin/codex}"

ENABLE_COMPUTER_USE_UI="${ENABLE_COMPUTER_USE_UI:-1}"  # in-app Computer Use UI
INSTALL_YDOTOOL="${INSTALL_YDOTOOL:-1}"                 # input backend for Computer Use
ENABLE_ATSPI="${ENABLE_ATSPI:-1}"                       # accessibility tree for Computer Use
SETUP_WINDOW_TARGETING="${SETUP_WINDOW_TARGETING:-1}"   # GNOME window-control extension (needs relogin)
DISABLE_WARM_START="${DISABLE_WARM_START:-1}"           # closing the app fully quits it
UPDATE_CODEX_CLI="${UPDATE_CODEX_CLI:-1}"               # install/update @openai/codex@latest
DISABLE_MULTI_INSTANCE="${DISABLE_MULTI_INSTANCE:-0}"   # set to 1 to strip the "New Window" multi-instance .desktop action

# Optional linux-features to enable (space-separated). Empty = none.
# Built into the app at build time (these patch the ASAR/staging).
LINUX_FEATURES="${LINUX_FEATURES:-remote-mobile-control remote-control-ui open-target-discovery appshots codex-wrapper-updater}"

# Optional: also update the Codex CLI on a remote SSH host you control.
#   DO_REMOTE=1 REMOTE_HOST=192.168.113.2 bash codex-desktop-setup.sh
DO_REMOTE="${DO_REMOTE:-0}"
REMOTE_HOST="${REMOTE_HOST:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn ]${NC} $*"; }
die()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not root (the script calls sudo where needed)."
command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (apt). For other distros use 'make bootstrap-native'."

# ---------------------------------------------------------------------------
# 1. Get the source
# ---------------------------------------------------------------------------
if [ -f "$REPO_DIR/Makefile" ] && [ -f "$REPO_DIR/install.sh" ]; then
  info "Using existing checkout: $REPO_DIR"
else
  info "Cloning $REPO_URL -> $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# 2. Apply the Sparkle autodownload "Oops" fix (idempotent)
#    No-op stub for setAutomaticBackgroundDownloadsEnabled on the Linux updater
#    manager. See PR: github.com/ilysenko/codex-desktop-linux/pull/447
# ---------------------------------------------------------------------------
BRIDGE="scripts/lib/linux-update-bridge-patch.js"
if [ -f "$BRIDGE" ]; then
  if grep -q 'setAutomaticBackgroundDownloadsEnabled:()=>{},getIsUpdateReady' "$BRIDGE"; then
    info "Sparkle fix already present (or merged upstream)."
  elif grep -q 'return{manager:{getIsUpdateReady:()=>s&&t,' "$BRIDGE"; then
    sed -i 's/return{manager:{getIsUpdateReady:()=>s&&t,/return{manager:{setAutomaticBackgroundDownloadsEnabled:()=>{},getIsUpdateReady:()=>s\&\&t,/' "$BRIDGE"
    info "Applied Sparkle autodownload no-op stub."
  else
    warn "Sparkle anchor not found in $BRIDGE — upstream may have changed; continuing."
  fi
else
  warn "$BRIDGE not found; skipping Sparkle patch."
fi

# ---------------------------------------------------------------------------
# 3. Build dependencies (apt + Rust toolchain)
# ---------------------------------------------------------------------------
info "Installing build dependencies..."
bash scripts/install-deps.sh
export PATH="$HOME/.cargo/bin:$PATH"

# ---------------------------------------------------------------------------
# 4. Enable Computer Use UI (persistent settings, read at build + runtime)
# ---------------------------------------------------------------------------
SETTINGS_DIR="$HOME/.config/codex-desktop"
SETTINGS="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" "$ENABLE_COMPUTER_USE_UI" "$DISABLE_WARM_START" <<'PY'
import json, sys
path, cu, warm = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
try:
    data = json.load(open(path))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
if cu:   data["codex-linux-computer-use-ui-enabled"] = True
if warm: data["codex-linux-warm-start-enabled"] = False
json.dump(data, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("settings.json:", json.dumps(data))
PY
info "Wrote $SETTINGS"

# ---------------------------------------------------------------------------
# 4b. Enable optional linux-features (built into the ASAR at build time).
# ---------------------------------------------------------------------------
if [ -n "${LINUX_FEATURES// /}" ]; then
  info "Enabling linux-features: $LINUX_FEATURES"
  python3 - "$REPO_DIR/linux-features/features.json" $LINUX_FEATURES <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2:]
try:
    data = json.load(open(path))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
enabled = data.get("enabled") if isinstance(data.get("enabled"), list) else []
for f in want:
    if f not in enabled: enabled.append(f)
data["enabled"] = enabled
json.dump(data, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("features.json enabled:", enabled)
PY
fi

# ---------------------------------------------------------------------------
# 5. Build, package, install (.deb). Bake Computer Use UI into the build.
# ---------------------------------------------------------------------------
info "Building app from fresh upstream DMG (this downloads the DMG + compiles)..."
CU_ENV=()
[ "$ENABLE_COMPUTER_USE_UI" = "1" ] && CU_ENV=(CODEX_LINUX_ENABLE_COMPUTER_USE_UI=1)
env "${CU_ENV[@]}" make build-app-fresh
env "${CU_ENV[@]}" make package
make install
info "Package installed."

# ---------------------------------------------------------------------------
# 5b. Disable the "New Window" multi-instance .desktop action (annoying).
#     Normal launches are already single-instance; this just removes the
#     right-click "New Window" entry that spawns a separate instance.
# ---------------------------------------------------------------------------
if [ "$DISABLE_MULTI_INSTANCE" = "1" ]; then
  DESKTOP_FILE="/usr/share/applications/codex-desktop.desktop"
  if [ -f "$DESKTOP_FILE" ] && grep -q 'Desktop Action new-window' "$DESKTOP_FILE"; then
    info "Removing the multi-instance 'New Window' action from $DESKTOP_FILE ..."
    sudo awk '
      /^\[Desktop Action new-window\]$/ { skip=1; next }
      /^\[/ { skip=0 }
      skip { next }
      /^Actions=/ { gsub(/new-window;/, ""); print; next }
      { print }
    ' "$DESKTOP_FILE" | sudo tee "$DESKTOP_FILE.tmp" >/dev/null && sudo mv "$DESKTOP_FILE.tmp" "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null 2>&1 && sudo update-desktop-database /usr/share/applications 2>/dev/null || true
  else
    info "No multi-instance action to remove."
  fi
fi

# ---------------------------------------------------------------------------
# 6. Codex CLI: install/update to latest at $CLI_PREFIX
# ---------------------------------------------------------------------------
if [ "$UPDATE_CODEX_CLI" = "1" ]; then
  NPM_BIN="$(command -v npm || true)"
  [ -n "$NPM_BIN" ] || NPM_BIN="$REPO_DIR/codex-app/resources/node-runtime/bin/npm"
  [ -n "$NPM_BIN" ] || NPM_BIN="/opt/codex-desktop/resources/node-runtime/bin/npm"
  if [ -x "$NPM_BIN" ] || command -v "$NPM_BIN" >/dev/null 2>&1; then
    info "Installing @openai/codex@latest into $CLI_PREFIX ..."
    sudo "$NPM_BIN" install -g --prefix "$CLI_PREFIX" @openai/codex@latest
    "$CLI_PREFIX/bin/codex" --version >/dev/null 2>&1 && info "Codex CLI: $("$CLI_PREFIX/bin/codex" --version | head -1)"
  else
    warn "No npm found; skipping CLI install. The app can auto-install it on first run."
  fi
fi

# ---------------------------------------------------------------------------
# 7. Pin CODEX_CLI_PATH for GUI launches (fixes 'Unable to locate Codex CLI binary')
#    GUI/.desktop launches get a minimal PATH without /usr/local/bin.
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/environment.d"
printf 'CODEX_CLI_PATH=%s\n' "$CODEX_CLI_PATH_VALUE" > "$HOME/.config/environment.d/codex-desktop.conf"
info "Wrote ~/.config/environment.d/codex-desktop.conf (CODEX_CLI_PATH=$CODEX_CLI_PATH_VALUE)"
# Apply to the current session too (new GUI launches inherit it without relogin).
systemctl --user set-environment "CODEX_CLI_PATH=$CODEX_CLI_PATH_VALUE" 2>/dev/null || true
command -v dbus-update-activation-environment >/dev/null 2>&1 && \
  dbus-update-activation-environment --systemd CODEX_CLI_PATH 2>/dev/null || true

# ---------------------------------------------------------------------------
# 8. ydotool input backend for Computer Use
# ---------------------------------------------------------------------------
if [ "$INSTALL_YDOTOOL" = "1" ]; then
  info "Installing ydotool + enabling input backend..."
  sudo apt-get install -y ydotool || warn "ydotool install failed; Computer Use can still use uinput/portal."
  sudo usermod -aG input "$USER" || true
  systemctl --user daemon-reload 2>/dev/null || true
  # Unit name differs across distros; try the common ones.
  systemctl --user enable --now ydotool.service 2>/dev/null \
    || systemctl --user enable --now ydotoold.service 2>/dev/null \
    || warn "Could not enable a ydotool user service automatically."
  info "ydotool set up (input-group change applies after next login)."
fi

# ---------------------------------------------------------------------------
# 9. AT-SPI accessibility (element-aware Computer Use actions)
# ---------------------------------------------------------------------------
if [ "$ENABLE_ATSPI" = "1" ] && command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null \
    && info "AT-SPI accessibility enabled." \
    || warn "Could not set toolkit-accessibility (non-GNOME?)."
fi

# ---------------------------------------------------------------------------
# 10. GNOME window-targeting extension (optional; needs relogin to activate)
# ---------------------------------------------------------------------------
CU_BIN="/opt/codex-desktop/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux"
if [ "$SETUP_WINDOW_TARGETING" = "1" ] && [ -x "$CU_BIN" ]; then
  info "Staging Computer Use window-targeting GNOME extension..."
  "$CU_BIN" setup-window-targeting >/dev/null 2>&1 || warn "setup-window-targeting reported issues (often just 'needs relogin')."
fi

# ---------------------------------------------------------------------------
# 11. Expose Computer Use tools to the agent via a config.toml MCP server.
#     The bundled computer-use *plugin* is dropped from the runtime-regenerated
#     marketplace, so its tools never reach the agent. Registering the backend
#     directly as an MCP server works — BUT it must NOT be named "computer-use"
#     (the app treats that as a managed plugin name and strips it on launch).
#     A neutral name like "desktop_control" survives and exposes all 16 tools
#     (screenshot/click/type_text/list_windows/activate_window/...).
# ---------------------------------------------------------------------------
CODEX_CONFIG="$HOME/.codex/config.toml"
CU_MCP_CMD="/opt/codex-desktop/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux"
if [ "$ENABLE_COMPUTER_USE_UI" = "1" ] && [ -x "$CU_MCP_CMD" ]; then
  mkdir -p "$HOME/.codex"; touch "$CODEX_CONFIG"
  if grep -q '^\[mcp_servers.desktop_control\]' "$CODEX_CONFIG"; then
    info "desktop_control MCP server already in config.toml."
  else
    info "Registering desktop_control (Computer Use backend) MCP server in config.toml ..."
    { printf '\n[mcp_servers.desktop_control]\nenabled = true\ncommand = "%s"\nargs = ["mcp"]\nstartup_timeout_sec = 120\n' "$CU_MCP_CMD"; } >> "$CODEX_CONFIG"
  fi
  info "Tools appear under server 'desktop_control' in a NEW thread after relaunch."

  # Persist agent guidance: launch GUI apps detached, else they close instantly
  # (the shell tool tears down the child process group when the command returns).
  AGENTS_MD="$HOME/.codex/AGENTS.md"
  touch "$AGENTS_MD"
  if grep -q 'CODEX-DESKTOP-LINUX: detached app launch' "$AGENTS_MD"; then
    info "AGENTS.md detached-launch guidance already present."
  else
    info "Adding detached-launch guidance to ~/.codex/AGENTS.md ..."
    cat >> "$AGENTS_MD" <<'AGENTS'

# Desktop control: launching apps (Codex Desktop Linux Computer Use)
<!-- CODEX-DESKTOP-LINUX: detached app launch -->
- When you launch a GUI app in order to control it with the `desktop_control` tools, ALWAYS start it detached so it survives the shell command returning. Use one of (most robust first):
  - `gio launch /usr/share/applications/<app>.desktop`
  - `systemd-run --user --scope -- <command>`
  - `setsid -f <command>`
- A plain `<app> &` or a direct foreground launch is torn down with the shell process group, so the window opens and then closes immediately. After the app is up, drive it with `desktop_control` (activate_window, click, type_text, screenshot, etc.).
AGENTS
  fi
fi

# ---------------------------------------------------------------------------
# 12. Optional: update Codex CLI on a remote SSH host
# ---------------------------------------------------------------------------
if [ "$DO_REMOTE" = "1" ] && [ -n "$REMOTE_HOST" ]; then
  info "Updating Codex CLI on remote $REMOTE_HOST ..."
  ssh -o ConnectTimeout=10 "$REMOTE_HOST" \
    'npm install -g --prefix /usr/local @openai/codex@latest && /usr/local/bin/codex --version' \
    || warn "Remote update failed (check SSH access / npm on $REMOTE_HOST)."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
info "Setup complete. ✅"
echo "  • Launch from your application menu: 'Codex Desktop' (or run: codex-desktop)"
echo "  • Recommended: log out and back in once so the 'input' group + environment.d apply everywhere."
echo "  • Browser Use native host is registered automatically with the package."
if [ "$SETUP_WINDOW_TARGETING" = "1" ]; then
  echo "  • Computer Use window targeting activates after the next login."
fi
