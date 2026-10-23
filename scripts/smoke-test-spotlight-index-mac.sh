#!/usr/bin/env bash
set -euo pipefail

SPOTLIGHT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOTLIGHT_OUTPUT="$SPOTLIGHT_ROOT/build/DeveloperWorkflow/SpotlightIndexSmoke"
SPOTLIGHT_SOURCE="${SPOTLIGHT_SOURCE:-$SPOTLIGHT_ROOT/Primuse/Services/Library/SpotlightIndexService.swift}"
SPOTLIGHT_APP="$SPOTLIGHT_OUTPUT/SpotlightIndexSmoke.app"
mkdir -p "$SPOTLIGHT_APP/Contents/MacOS"

# Compile the complete service and planner with small library fixtures. The
# signed probe owns a separate Spotlight bundle and never starts AppServices.
python3 - "$SPOTLIGHT_ROOT" "$SPOTLIGHT_SOURCE" "$SPOTLIGHT_OUTPUT" <<'PY'
import plistlib
import sys
from pathlib import Path

root, source_path, output = map(Path, sys.argv[1:])
service = source_path.read_text().replace('import PrimuseKit\n', '')
service = service.replace('com.welape.yuanyin', 'org.primuse.tests.spotlight-index-smoke')
app = (root / 'Primuse/App/PrimuseApp.swift').read_text()
observer = app.index('.onChange(of: playerService.isPlaybackActive)')
pause = app.index('                    } else {', observer)
end = app.index('\n                    }', pause + 30)
pause_body = app[app.index('\n', pause) + 1:end]
fixture = (root / 'scripts/SpotlightIndexSmoke.swift').read_text()
fixture = fixture.replace('/* PRODUCTION_PLAYBACK_PAUSE */', pause_body)
(output / 'SpotlightIndexSmoke.swift').write_text(service + '\n' + fixture)
info = {
    'CFBundleIdentifier': 'org.primuse.tests.spotlight-index-smoke',
    'CFBundleExecutable': 'SpotlightIndexSmoke',
    'CFBundleName': 'SpotlightIndexSmoke',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSUIElement': True,
}
with (output / 'SpotlightIndexSmoke.app/Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
PY

xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$SPOTLIGHT_ROOT/build/DeveloperWorkflow/macOS/ModuleCache.noindex" \
    "$SPOTLIGHT_ROOT/PrimuseKit/Sources/PrimuseKit/SpotlightIndexPlanning.swift" \
    "$SPOTLIGHT_ROOT/PrimuseKit/Sources/PrimuseKit/CarPlayListRefreshPolicy.swift" \
    "$SPOTLIGHT_OUTPUT/SpotlightIndexSmoke.swift" \
    -o "$SPOTLIGHT_APP/Contents/MacOS/SpotlightIndexSmoke"
codesign --force --sign - "$SPOTLIGHT_APP"
if [[ "${SPOTLIGHT_TYPECHECK_IOS:-0}" == "1" ]]; then
    SPOTLIGHT_IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    xcrun swiftc -swift-version 6 -parse-as-library -typecheck \
        -target arm64-apple-ios18.0-simulator -sdk "$SPOTLIGHT_IOS_SDK" \
        -module-cache-path "$SPOTLIGHT_ROOT/build/DeveloperWorkflow/iOSSimulator/ModuleCache.noindex" \
        "$SPOTLIGHT_ROOT/PrimuseKit/Sources/PrimuseKit/SpotlightIndexPlanning.swift" \
        "$SPOTLIGHT_ROOT/PrimuseKit/Sources/PrimuseKit/CarPlayListRefreshPolicy.swift" \
        "$SPOTLIGHT_OUTPUT/SpotlightIndexSmoke.swift"
    echo "PASS: iOS service and background-task APIs typecheck with an iOS 18 deployment target"
fi
"$SPOTLIGHT_APP/Contents/MacOS/SpotlightIndexSmoke" "$SPOTLIGHT_OUTPUT"
