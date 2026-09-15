#!/usr/bin/env bash
set -euo pipefail

SCROLL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCROLL_OUTPUT="$SCROLL_ROOT/build/DeveloperWorkflow/ScrollViewStyleSmoke"
mkdir -p "$SCROLL_OUTPUT"

# Compile the production class alone so the check never starts app services.
python3 - "$SCROLL_ROOT" "$SCROLL_OUTPUT" <<'PY'
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/Views/Mac/Theme/PrimuseTheme.swift').read_text()
start = source.index('@MainActor\nfinal class PMScrollViewStyle')
end = source.index('// MARK: - Force-hide NSScrollView scrollers', start)
(output / 'PMScrollViewStyle.swift').write_text('import AppKit\n' + source[start:end])
PY

xcrun swiftc -swift-version 6 \
    "$SCROLL_OUTPUT/PMScrollViewStyle.swift" \
    "$SCROLL_ROOT/scripts/ScrollViewStyleSmoke.swift" \
    -o "$SCROLL_OUTPUT/scroll-view-style-smoke"
"$SCROLL_OUTPUT/scroll-view-style-smoke"
