#!/bin/bash
# Verify repeat and sharing decisions without a player, peer, clipboard or UI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-video-context-policy.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/VideoContextPolicy.swift" \
  "$ROOT/Scripts/tests/video_context_policy.swift" \
  -o "$CHECK_DIR/video-context-policy-checks"
"$CHECK_DIR/video-context-policy-checks"
