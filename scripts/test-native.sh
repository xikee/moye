#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/moye-native-tests.XXXXXX")"
xcrun swiftc "$ROOT/native/Draft.swift" "$ROOT/tests/native/main.swift" -o "$TEST_OUTPUT/draft-tests"
"$TEST_OUTPUT/draft-tests"
