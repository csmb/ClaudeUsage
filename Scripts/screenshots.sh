#!/usr/bin/env bash
#
# Generates the marketing screenshots in screenshots/.
#
# Runs the app once per scenario x appearance with --demo, which paints a
# neutral backdrop, fills the popover with synthetic data, captures itself, and
# quits. The system appearance is flipped between passes so the real menu bar
# matches the popover, and restored when we're done.
#
# Requires: Screen Recording permission for the built "Claude Usage" binary
# (the app opens the right System Settings pane and exits 3 if it's missing).
#
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
OUT="$REPO/screenshots"

SCENARIOS=(healthy mixed heavy)
MODES=(dark light)

# Narrow by naming modes and/or scenarios, in any order and any combination:
#   ./Scripts/screenshots.sh                 everything
#   ./Scripts/screenshots.sh light           the light pass only
#   ./Scripts/screenshots.sh heavy           one scenario, both appearances
#   ./Scripts/screenshots.sh heavy dark      one image set
pick_modes=()
pick_scenarios=()
for arg in "$@"; do
  case "$arg" in
    dark|light)          pick_modes+=("$arg") ;;
    healthy|mixed|heavy) pick_scenarios+=("$arg") ;;
    *) echo "Unknown argument: $arg (want dark|light|healthy|mixed|heavy)" >&2; exit 2 ;;
  esac
done
[[ ${#pick_modes[@]}     -gt 0 ]] && MODES=("${pick_modes[@]}")
[[ ${#pick_scenarios[@]} -gt 0 ]] && SCENARIOS=("${pick_scenarios[@]}")

# Note on light mode: macOS tints the menu bar from the desktop *wallpaper*,
# not from the system appearance. With a dark wallpaper the menu bar keeps its
# white glyphs even in Light mode, and the light shots come out mismatched.
# Set a light wallpaper before running the light pass.

# --- system appearance -------------------------------------------------------

current_dark() {
  [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)" == "Dark" ]]
}

set_dark() {  # $1 = true|false
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1"
  sleep 1.2   # let the menu bar redraw before we capture it
}

if current_dark; then ORIGINAL=true; else ORIGINAL=false; fi

restore() {
  set_dark "$ORIGINAL" || true
  # Put the user's installed app back the way we found it.
  if [[ -d "/Applications/Claude Usage.app" ]] && ! pgrep -f "/Applications/Claude Usage.app/Contents/MacOS" >/dev/null; then
    open -a "/Applications/Claude Usage.app" || true
  fi
}
trap restore EXIT

# --- build -------------------------------------------------------------------

echo "==> Building"
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build >/dev/null
BUILD_DIR=$(xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -showBuildSettings 2>/dev/null \
  | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')
APP="$BUILD_DIR/Claude Usage.app/Contents/MacOS/Claude Usage"
[[ -x "$APP" ]] || { echo "No build product at $APP" >&2; exit 1; }

# Two status items in the menu bar would make the shots confusing.
pkill -f "/Applications/Claude Usage.app/Contents/MacOS" 2>/dev/null || true

mkdir -p "$OUT"

# --- capture -----------------------------------------------------------------

for mode in "${MODES[@]}"; do
  [[ "$mode" == "dark" ]] && set_dark true || set_dark false
  for scenario in "${SCENARIOS[@]}"; do
    echo "==> $scenario / $mode"
    set +e
    # The -key value pairs land in NSUserDefaults' argument domain: they
    # override the real preferences for this launch only and are never written
    # to disk. Without them the Settings shot inherits whatever the developer
    # happens to have configured, and a panel of greyed-out toggles makes the
    # feature look broken.
    "$APP" --demo "$scenario" --appearance "$mode" --shots "$OUT" --settings \
      -notificationsEnabled 1 -notify75 1 -notify90 1 -notify95 0 -pollIntervalOverride 0
    status=$?
    set -e
    if [[ $status -eq 3 ]]; then
      echo "Grant Screen Recording to \"Claude Usage\", then re-run this script." >&2
      exit 3
    fi
  done
done

echo "==> Wrote $(ls -1 "$OUT"/*.png | wc -l | tr -d ' ') images to $OUT"
