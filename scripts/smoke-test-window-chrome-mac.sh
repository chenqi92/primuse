#!/usr/bin/env bash
set -euo pipefail

CHROME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME_OUTPUT="$CHROME_ROOT/build/DeveloperWorkflow/WindowChromeSmoke"
mkdir -p "$CHROME_OUTPUT"

# Exercise the production scene declaration without starting AppServices.
python3 - "$CHROME_ROOT" "$CHROME_OUTPUT" <<'PY'
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/App/PrimuseApp.swift').read_text()
start = source.index('    @SceneBuilder\n    private func macAwareMainGroup')
end = source.index('    private func injectServices', start)
fixture = (root / 'scripts/WindowChromeSmoke.swift').read_text()
(output / 'WindowChromeSmoke.swift').write_text(
    fixture.replace('    // PRODUCTION_MAIN_WINDOW_SCENE', source[start:end].rstrip())
)
PY

xcrun swiftc -swift-version 6 -parse-as-library \
    "$CHROME_OUTPUT/WindowChromeSmoke.swift" \
    -o "$CHROME_OUTPUT/window-chrome-smoke"
"$CHROME_OUTPUT/window-chrome-smoke"
