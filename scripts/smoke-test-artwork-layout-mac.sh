#!/usr/bin/env bash
set -euo pipefail

ARTWORK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTWORK_OUTPUT="${ARTWORK_OUTPUT:-$ARTWORK_ROOT/build/DeveloperWorkflow/ArtworkLayoutSmoke}"
ARTWORK_SOURCE="${ARTWORK_SOURCE:-$ARTWORK_ROOT/Primuse/Views/Components/CachedArtworkView.swift}"
mkdir -p "$ARTWORK_OUTPUT"

# Exercise the production SwiftUI layout without launching app services or
# reading the user's library. Only the loaded cover layer is supplied by the test.
python3 - "$ARTWORK_SOURCE" "$ARTWORK_OUTPUT" <<'PY'
import sys
from pathlib import Path

source_path, output = map(Path, sys.argv[1:])
source = source_path.read_text()
body_start = source.index('    var body: some View {')
body_end = source.index('        .task(id: loadTaskIdentity)', body_start)
content_start = source.index('    private var coverContent: some View {')
content_end = source.index('\n    /// body 拆出来', content_start)
whole_start = source.index('    @ViewBuilder\n    private func wholeArtwork(')
whole_end = source.index('\n    private func appleMusicArtworkView(', whole_start)
conditional_start = source.index('extension View {')
conditional_end = source.index('\n/// Keeps rapid list scrolling', conditional_start)

fixture = '''import SwiftUI
import AppKit

typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

struct CachedArtworkLayoutFixture<Content: View>: View {
    var size: CGFloat? = nil
    var fillsProposedSize = false
    var fitsWholeArtwork = false
    var cornerRadius: CGFloat = 14
    let coverLayer: Content
'''
fixture += source[body_start:body_end] + '    }\n'
fixture += source[content_start:content_end] + '\n}\n'
fixture += '''
struct WholeArtworkFixture: View {
    let image: PlatformImage
    var size: CGFloat? = 120
    var wholeArtworkFrameAspectRatio: CGFloat? = 0.75
    var body: some View { wholeArtwork(image) }
'''
fixture += source[whole_start:whole_end] + '\n}\n'
fixture += source[conditional_start:conditional_end]
(output / 'CachedArtworkLayoutFixture.swift').write_text(fixture)
PY

{
    git -C "$ARTWORK_ROOT" rev-parse HEAD
    shasum -a 256 "$ARTWORK_SOURCE"
    xcrun swiftc --version
    sw_vers
} > "$ARTWORK_OUTPUT/environment.txt"

xcrun swiftc -swift-version 6 \
    "$ARTWORK_OUTPUT/CachedArtworkLayoutFixture.swift" \
    "$ARTWORK_ROOT/PrimuseKit/Sources/PrimuseKit/SpokenWordCoverLayout.swift" \
    "$ARTWORK_ROOT/scripts/ArtworkLayoutSmoke.swift" \
    -o "$ARTWORK_OUTPUT/artwork-layout-smoke"
"$ARTWORK_OUTPUT/artwork-layout-smoke" "$ARTWORK_OUTPUT"
