#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
WORK_DIR="$(mktemp -d ".build/tokei-sync-integration.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
OUTPUT="$WORK_DIR/tokei-sync-integration-check"
MODULE_CACHE="$WORK_DIR/ModuleCache"
mkdir -p "$MODULE_CACHE"
swiftc -parse-as-library \
  -j 1 \
  -framework Security \
  -module-cache-path "$MODULE_CACHE" \
  Sources/Tokei/Model.swift \
  Sources/Tokei/SyncBackend.swift \
  Sources/Tokei/GitSyncBackend.swift \
  Sources/Tokei/GzipCodec.swift \
  Sources/Tokei/KeychainStore.swift \
  Sources/Tokei/WebDAVClient.swift \
  Sources/Tokei/WebDAVSyncBackend.swift \
  Sources/Tokei/SyncManager.swift \
  Tests/SyncManagerIntegrationCheck.swift \
  -o "$OUTPUT"
"$OUTPUT" "$@"
