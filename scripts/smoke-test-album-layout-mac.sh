#!/usr/bin/env bash
set -euo pipefail
LAYOUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAYOUT_OUTPUT="$LAYOUT_ROOT/build/DeveloperWorkflow/AlbumLayoutSmoke"
mkdir -p "$LAYOUT_OUTPUT"
python3 - "$LAYOUT_ROOT" "$LAYOUT_OUTPUT" <<'PY'
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/Views/Library/AlbumGridView.swift').read_text()
def block(marker, content=source):
    start = content.index(marker); opening = content.index('{', start); end = opening + 1; depth = 1
    while depth:
        depth += (content[end] == '{') - (content[end] == '}'); end += 1
    return content[start:end]
fixture = (root / 'scripts/AlbumLayoutSmoke.swift').read_text()
fixture = fixture.replace('/* PRODUCTION_OVERVIEW */', block('private var macAlbumOverview:'))
fixture = fixture.replace('/* PRODUCTION_TILE */', block('private func macAlbumTile('))
fixture = fixture.replace('/* PRODUCTION_ROW */', block('private func macAlbumListRow('))
fixture = fixture.replace('/* PRODUCTION_METRICS */', block('struct MacAlbumGridMetrics') if 'struct MacAlbumGridMetrics' in source else '')
theme = (root / 'Primuse/Views/Mac/Theme/PrimuseTheme.swift').read_text()
fixture = fixture.replace('/* PRODUCTION_SPACING */', block('enum PMSpace', theme))
(output / 'AlbumLayoutSmoke.swift').write_text(fixture)
PY
xcrun swiftc -swift-version 6 -parse-as-library "$LAYOUT_ROOT/scripts/ArtworkSmokeBudget.swift" "$LAYOUT_OUTPUT/AlbumLayoutSmoke.swift" -o "$LAYOUT_OUTPUT/album-layout-smoke"
"$LAYOUT_OUTPUT/album-layout-smoke"
