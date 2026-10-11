#!/usr/bin/env bash
set -euo pipefail
ALBUM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALBUM_OUTPUT="$ALBUM_ROOT/build/DeveloperWorkflow/AlbumArtworkLayersSmoke"
mkdir -p "$ALBUM_OUTPUT"
python3 - "$ALBUM_ROOT" "$ALBUM_OUTPUT" <<'PY'
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/Views/Components/StoredCoverArtView.swift').read_text()
start = source.index('struct AlbumArtworkView: View {')
end = source.index('/// Artist artwork keeps', start)
fixture = (root / 'scripts/AlbumArtworkLayersSmoke.swift').read_text()
(output / 'AlbumArtworkLayersSmoke.swift').write_text(fixture.replace('/* PRODUCTION_VIEW */', source[start:end]))
PY
xcrun swiftc -swift-version 6 -parse-as-library "$ALBUM_ROOT/scripts/ArtworkSmokeBudget.swift" "$ALBUM_OUTPUT/AlbumArtworkLayersSmoke.swift" \
    -o "$ALBUM_OUTPUT/album-artwork-layers-smoke"
"$ALBUM_OUTPUT/album-artwork-layers-smoke"
