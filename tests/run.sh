#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$ROOT_DIR/tests/tmp
STUB_DIR=$ROOT_DIR/tests/stubs
FIXTURE_DIR=$ROOT_DIR/tests/fixtures
CLI=$ROOT_DIR/bin/tor-anchor

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  file=$1
  pattern=$2
  description=$3
  grep -F -- "$pattern" "$file" >/dev/null 2>&1 || fail "$description"
}

assert_not_contains() {
  file=$1
  pattern=$2
  description=$3
  if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "$description"
  fi
}

run_cli() {
  PFCTL_LOG=$TEST_ROOT/pfctl.log \
  PFCTL_STATE_DIR=$TEST_ROOT/pfstate \
  PFCTL_HAS_HOOK=${PFCTL_HAS_HOOK:-1} \
  SOCKSTAT_FIXTURE=${SOCKSTAT_FIXTURE:-} \
  TOR_DDOS_BSD_ALLOW_UNSUPPORTED=1 \
  PFCTL_CMD=pfctl \
  SOCKSTAT_CMD=sockstat \
  PATH="$STUB_DIR:$PATH" \
  "$CLI" "$@"
}

test_render_ipv4() {
  output=$TEST_ROOT/render-ipv4.out
  run_cli --state-dir "$TEST_ROOT/state1" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" render >"$output"
  assert_contains "$output" 'to 198.51.100.10 port 9001' "render should contain discovered IPv4 ORPort"
  assert_contains "$output" 'table <tor_anchor_trust_v4>' "render should contain IPv4 trust table"
  pass "render single IPv4 target"
}

test_render_dualstack_and_idempotent() {
  out1=$TEST_ROOT/render-dual-1.out
  out2=$TEST_ROOT/render-dual-2.out
  run_cli --state-dir "$TEST_ROOT/state2" --torrc "$FIXTURE_DIR/torrc-dualstack.conf" render >"$out1"
  run_cli --state-dir "$TEST_ROOT/state2" --torrc "$FIXTURE_DIR/torrc-dualstack.conf" render >"$out2"
  cmp -s "$out1" "$out2" || fail "render should be idempotent for identical input"
  assert_contains "$out1" 'to 198.51.100.11 port 443' "render should contain discovered IPv4 target from Address/ORPort"
  assert_contains "$out1" 'to 2001:db8::11 port 9001' "render should contain explicit IPv6 ORPort"
  pass "render dual-stack targets idempotently"
}

test_sockstat_fallback_and_override() {
  output=$TEST_ROOT/render-fallback.out
  SOCKSTAT_FIXTURE=$FIXTURE_DIR/sockstat-9100.txt run_cli \
    --state-dir "$TEST_ROOT/state3" \
    --torrc "$FIXTURE_DIR/torrc-missing-address.conf" \
    --target "[2001:db8::99]:9443" \
    render >"$output"
  assert_contains "$output" 'to 203.0.113.9 port 9100' "render should resolve missing Address via sockstat"
  assert_contains "$output" 'to 2001:db8::99 port 9443' "render should include explicit override target"
  pass "render with sockstat fallback and explicit override"
}

test_apply_requires_targets() {
  output=$TEST_ROOT/apply-fail.out
  if run_cli --state-dir "$TEST_ROOT/state4" --torrc "$FIXTURE_DIR/torrc-empty.conf" apply >"$output" 2>&1; then
    fail "apply should fail when no targets are available"
  fi
  assert_contains "$output" 'no protected targets were discovered or configured' "apply should explain missing targets"
  pass "apply fails safely without targets"
}

test_apply_status_refresh_disable() {
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  run_cli --state-dir "$TEST_ROOT/state5" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" apply >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f $TEST_ROOT/state5/tor_anchor-anchor.conf" "apply should load anchor"
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "apply should refresh IPv4 trust table"

  status_out=$TEST_ROOT/status.out
  run_cli --state-dir "$TEST_ROOT/state5" status >"$status_out"
  assert_contains "$status_out" "Anchor loaded: yes" "status should report loaded anchor"
  assert_contains "$status_out" "inet 198.51.100.10:9001" "status should list protected target"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" refresh >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "refresh should replace trust table"
  assert_not_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f $TEST_ROOT/state5/tor_anchor-anchor.conf" "refresh should not reload anchor"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" disable >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f /dev/null" "disable should empty the managed anchor"
  pass "apply, status, refresh, and disable"
}

test_render_ipv4
test_render_dualstack_and_idempotent
test_sockstat_fallback_and_override
test_apply_requires_targets
test_apply_status_refresh_disable

printf '1..5\n'
