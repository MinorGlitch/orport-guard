#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$ROOT_DIR/tests/tmp
STUB_DIR=$ROOT_DIR/tests/stubs
FIXTURE_DIR=$ROOT_DIR/tests/fixtures
CLI=$ROOT_DIR/bin/orport-guard
TEST_CASES=
TEST_COUNT=0

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

. "$ROOT_DIR/tests/lib/testlib.sh"

for case_file in "$ROOT_DIR"/tests/cases/*.sh; do
  . "$case_file"
done

for test_name in $TEST_CASES; do
  "$test_name"
done

printf '1..%s\n' "$TEST_COUNT"
