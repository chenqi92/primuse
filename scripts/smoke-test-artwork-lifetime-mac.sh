#!/usr/bin/env bash
set -euo pipefail

ARTWORK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTWORK_OUTPUT="$ARTWORK_ROOT/build/DeveloperWorkflow/ArtworkLifetimeSmoke"
mkdir -p "$ARTWORK_OUTPUT"

# Exercise the production disappear handler and displayed-image selection in
# a native lazy grid. Source IO and animation are deliberately outside this
# component-lifetime test; it must never start AppServices or the user's library.
python3 - "$ARTWORK_ROOT" "$ARTWORK_OUTPUT" <<'PY'
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
source = (root / 'Primuse/Views/Components/CachedArtworkView.swift').read_text()
def block(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
fixture = (root / 'scripts/ArtworkLifetimeSmoke.swift').read_text()
fixture = fixture.replace('/* PRODUCTION_DISAPPEAR */', block('.onDisappear {'))
visibility = '.onScrollVisibilityChange(threshold:'
fixture = fixture.replace('/* PRODUCTION_VISIBILITY */', block(visibility) if visibility in source else '')
if 'private var decodedArtworkState' in source:
    state = '@State private var decodedArtworkState = DecodedArtworkState()\n'
    state += block('private var image:') + '\n@MainActor @Observable\n'
    state += block('fileprivate final class DecodedArtworkState')
else:
    state = '@State private var image: PlatformImage?'
fixture = fixture.replace('/* PRODUCTION_IMAGE_STATE */', state)
fixture = fixture.replace('/* PRODUCTION_DISPLAYED_IMAGE */', block('private var displayedImage:'))
helper = 'private func releaseStaticArtwork()'
fixture = fixture.replace('/* PRODUCTION_RELEASE */', block(helper) if helper in source else '')
(output / 'ArtworkLifetimeSmoke.swift').write_text(fixture)
PY

xcrun swiftc -swift-version 6 -parse-as-library "$ARTWORK_ROOT/scripts/ArtworkSmokeBudget.swift" "$ARTWORK_OUTPUT/ArtworkLifetimeSmoke.swift" \
    -o "$ARTWORK_OUTPUT/artwork-lifetime-smoke"
"$ARTWORK_OUTPUT/artwork-lifetime-smoke"
