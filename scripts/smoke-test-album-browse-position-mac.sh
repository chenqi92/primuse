#!/usr/bin/env bash
set -euo pipefail

BROWSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BROWSE_OUTPUT="$(printenv BROWSE_OUTPUT || true)"
BROWSE_SOURCE="$(printenv BROWSE_SOURCE || true)"
[[ -n "$BROWSE_OUTPUT" ]] || BROWSE_OUTPUT="$BROWSE_ROOT/build/DeveloperWorkflow/AlbumBrowsePositionSmoke"
[[ -n "$BROWSE_SOURCE" ]] || BROWSE_SOURCE="$BROWSE_ROOT/Primuse/Views/Library/AlbumGridView.swift"
mkdir -p "$BROWSE_OUTPUT"

# Compile the real overview/detail composition and navigation actions with
# deterministic views. No app services, playback, or user library are started.
python3 - "$BROWSE_SOURCE" "$BROWSE_OUTPUT" <<'PY'
import sys
from pathlib import Path

source_path, output = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('    @ViewBuilder\n    private var macGrid: some View {')
end = source.index('\n    private var selectedAlbum:', start)
actions_start = source.index('    private func openAlbum(_ album: Album)')
actions_end = source.index('\n    private func albumsHeader(', actions_start)
fixture = '''import SwiftUI

struct AlbumGridNavigationFixture: View {
    @State private var selectedAlbumID: String?
    let driver: AlbumBrowseDriver
    let grid: Bool
    private var selectedAlbum: Album? { selectedAlbumID.map { Album(id: $0) } }
    private var macAlbumOverview: some View { AlbumOverviewFixture(grid: grid, driver: driver) }
    var body: some View {
        macGrid
            .onAppear {
                driver.open = { openAlbum(Album(id: "opened-album")) }
                driver.close = closeAlbum
            }
    }
'''
fixture += source[start:end] + '\n' + source[actions_start:actions_end] + '\n}\n'
(output / 'AlbumGridNavigationFixture.swift').write_text(fixture)
PY

{
    git -C "$BROWSE_ROOT" rev-parse HEAD
    shasum -a 256 "$BROWSE_SOURCE"
    xcrun swiftc --version
    sw_vers
} > "$BROWSE_OUTPUT/environment.txt"

xcrun swiftc -swift-version 6 \
    "$BROWSE_OUTPUT/AlbumGridNavigationFixture.swift" \
    "$BROWSE_ROOT/Primuse/Views/Components/PMMotion.swift" \
    "$BROWSE_ROOT/scripts/AlbumBrowsePositionSmoke.swift" \
    -o "$BROWSE_OUTPUT/album-browse-position-smoke"
"$BROWSE_OUTPUT/album-browse-position-smoke" "$BROWSE_OUTPUT"
