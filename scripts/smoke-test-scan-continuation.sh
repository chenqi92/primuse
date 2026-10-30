#!/usr/bin/env bash
set -euo pipefail

SCAN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN_OUTPUT="$(mktemp -d "${TMPDIR:-/private/tmp}/primuse-scan-continuation.XXXXXX")"
trap 'rm -rf "$SCAN_OUTPUT"' EXIT

# Exercise the production session with a controllable scheduler, without launching the app.
python3 - "$SCAN_ROOT" "$SCAN_OUTPUT" "${1:-$SCAN_ROOT/Primuse/Services/Library/ScanService.swift}" <<'PY'
import sys
from pathlib import Path
root, output, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('@MainActor\nprivate protocol ScanBackgroundContinuation')
end = source.index('/// Manages music source scanning state and tasks.', start)
session = '\n'.join(line for line in source[start:end].splitlines()
                    if not line.startswith(('#if', '#endif')))
policy = (root / 'PrimuseKit/Sources/PrimuseKit/SceneTransitionScanQuiescePolicy.swift').read_text()
context = (root / 'PrimuseKit/Sources/PrimuseKit/Models/SourceSyncState.swift').read_text()
start = context.index('public enum BaiduSnapshotExecutionContext:')
end = context.index('\n}', start) + 2
shared = 'import Foundation\n' + context[start:end] + '\n' + policy + '\n'
fixtures = (root / 'scripts/ScanContinuedProcessingSmoke.swift').read_text()
(output / 'Smoke.swift').write_text(shared + session + '\n' + fixtures)
(output / 'Native.swift').write_text(
    shared + 'import BackgroundTasks\nfunc plog(_ message: String) {}\n' + session)
PY

xcrun swiftc -swift-version 6 -parse-as-library "$SCAN_OUTPUT/Smoke.swift" -o "$SCAN_OUTPUT/smoke"
"$SCAN_OUTPUT/smoke"

# Also check the adapter against the real iOS SDK; the host test uses API doubles.
xcrun swiftc -swift-version 6 -typecheck -target arm64-apple-ios18.0 \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" "$SCAN_OUTPUT/Native.swift"
