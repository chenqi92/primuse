#!/usr/bin/env bash
set -euo pipefail

BOOK_LAYOUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOK_LAYOUT_OUTPUT="${BOOK_LAYOUT_OUTPUT:-$BOOK_LAYOUT_ROOT/build/DeveloperWorkflow/AudiobookLayoutSmoke}"
BOOK_LAYOUT_SOURCE="${BOOK_LAYOUT_SOURCE:-$BOOK_LAYOUT_ROOT/Primuse/Views/NowPlaying/AudiobookPlayerDesign.swift}"
mkdir -p "$BOOK_LAYOUT_OUTPUT"

python3 - "$BOOK_LAYOUT_SOURCE" "$BOOK_LAYOUT_OUTPUT" <<'PY'
from pathlib import Path
import sys

source_path, output = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('struct AudiobookHeroRowLayout: Layout {')
end = source.index('// MARK: - Chapter column', start)
(output / 'Layout.swift').write_text('import SwiftUI\n' + source[start:end])
PY

xcrun swiftc -swift-version 6 \
    -module-cache-path "$BOOK_LAYOUT_ROOT/build/DeveloperWorkflow/macOS/ModuleCache.noindex" \
    "$BOOK_LAYOUT_OUTPUT/Layout.swift" \
    "$BOOK_LAYOUT_ROOT/Scripts/AudiobookLayoutSmoke.swift" \
    -o "$BOOK_LAYOUT_OUTPUT/audiobook-layout-smoke"
"$BOOK_LAYOUT_OUTPUT/audiobook-layout-smoke"
