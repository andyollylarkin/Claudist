#!/bin/bash
# Builds Claudist and installs it into /Applications (replacing the installed copy).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh release

if pgrep -f '/Claudist.app/Contents/MacOS/Claudist' >/dev/null; then
    osascript -e 'quit app "Claudist"' || true
    for _ in $(seq 1 20); do pgrep -f '/Claudist.app/Contents/MacOS/Claudist' >/dev/null || break; sleep 0.5; done
fi

rm -rf /Applications/Claudist.app
ditto dist/Claudist.app /Applications/Claudist.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Claudist.app
echo "Installed /Applications/Claudist.app"
open /Applications/Claudist.app
