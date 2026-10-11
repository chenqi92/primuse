#!/usr/bin/env bash
set -euo pipefail
DECODE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECODE_OUTPUT="$DECODE_ROOT/build/DeveloperWorkflow/ArtworkDecodeSmoke"
mkdir -p "$DECODE_OUTPUT"
python3 - "$DECODE_ROOT" "$DECODE_OUTPUT" <<'PY'
import sys, re
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/Views/Components/CachedArtworkView.swift').read_text()
def block(marker):
    start = source.index(marker); opening = source.index('{', start); end = opening + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
parts = [block('private enum Bucket:'), block('private nonisolated static func bucket(for'), block('private nonisolated static func decode(')]
parts += re.findall(r'    private nonisolated static let (?:thumb|card|full)MaxPixel: Int = \d+', source)
fixture = (root / 'scripts/ArtworkDecodeSmoke.swift').read_text()
fixture = fixture.replace('/* PRODUCTION_POLICY */', '\n'.join(parts))
call = 'bucket(for: points, displayScale: scale)' if 'displayScale: CGFloat' in parts[1] else 'bucket(for: points)'
fixture = fixture.replace('/* BUCKET_CALL */', call)
animation_call = 'Self.bucket(for: size, displayScale: 2)' if 'displayScale: CGFloat' in parts[1] else 'Self.bucket(for: size)'
animation_parts = parts[:2] + parts[3:] + ['private var bucket: Bucket { ' + animation_call + ' }', block('private var animationMaximumPixelSize:')]
fixture = fixture.replace('/* PRODUCTION_ANIMATION_POLICY */', '\n'.join(animation_parts))
fixture = fixture.replace('/* PRODUCTION_BUCKET */', parts[0].replace('private enum', 'enum'))
fixture = fixture.replace('/* PRODUCTION_FALLBACK */', block('private func cachedLowerResolutionImage('))
fixture = fixture.replace('/* PRODUCTION_INVALIDATION */', block('static func invalidateCache(for fileName:'))
fixture = fixture.replace('/* PRODUCTION_SONG_INVALIDATION */', block('static func invalidateCache(forSongs'))
(output / 'ArtworkDecodeSmoke.swift').write_text(fixture)
PY
xcrun swiftc -swift-version 6 -parse-as-library "$DECODE_ROOT/scripts/ArtworkSmokeBudget.swift" "$DECODE_OUTPUT/ArtworkDecodeSmoke.swift" -o "$DECODE_OUTPUT/artwork-decode-smoke"
"$DECODE_OUTPUT/artwork-decode-smoke"
