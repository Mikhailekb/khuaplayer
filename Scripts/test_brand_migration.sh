#!/bin/bash
# Regression checks use UUID preference domains and temporary support directories.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-brand-migration.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/BrandMigration.swift" \
  "$ROOT/Scripts/tests/brand_migration.swift" \
  -o "$CHECK_DIR/brand-migration-checks"
"$CHECK_DIR/brand-migration-checks"
