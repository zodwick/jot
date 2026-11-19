#!/bin/zsh
# Builds Jot with SwiftPM and wraps the binary in a proper .app bundle.
#
#   scripts/bundle.sh                 release build → build.noindex/Jot.app
#   scripts/bundle.sh debug           debug build
#   scripts/bundle.sh --install       release build, then replace /Applications/Jot.app
#
# The output folder ends in ".noindex" so Spotlight never lists the build copy
# next to the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Jot"
OUT="build.noindex"
APP="$OUT/Jot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc sign so macOS treats it as a normal local app.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if (( INSTALL )); then
  WAS_RUNNING=0
  if pgrep -xq Jot; then
    WAS_RUNNING=1
    # Quit politely so Jot saves the page before it's replaced.
    osascript -e 'tell application id "local.jot.app" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -xq Jot || break; sleep 0.1; done
  fi
  rm -rf /Applications/Jot.app
  cp -R "$APP" /Applications/Jot.app
  # Only the installed copy should be known to Launch Services / Spotlight.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f /Applications/Jot.app
  echo "Installed /Applications/Jot.app"
  (( WAS_RUNNING )) && open /Applications/Jot.app
fi
