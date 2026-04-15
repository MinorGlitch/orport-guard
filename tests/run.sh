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

test_render_aggressive_profile() {
  output=$TEST_ROOT/render-aggressive.out
  run_cli --state-dir "$TEST_ROOT/state-aggr" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive render >"$output"
  assert_contains "$output" 'max-src-states 4, max-src-conn 4, max-src-conn-rate 7/1' "aggressive profile should lower thresholds"
  pass "render aggressive profile"
}

test_explicit_target_overrides_discovery() {
  output=$TEST_ROOT/render-explicit-override.out
  run_cli --state-dir "$TEST_ROOT/state-override" --torrc "$FIXTURE_DIR/torrc-dualstack.conf" --target "203.0.113.50:9100" render >"$output"
  assert_contains "$output" 'to 203.0.113.50 port 9100' "render should contain the explicit target"
  assert_not_contains "$output" 'to 198.51.100.11 port 443' "explicit target should suppress discovered IPv4 targets"
  assert_not_contains "$output" 'to 2001:db8::11 port 9001' "explicit target should suppress discovered IPv6 targets"
  pass "explicit targets override discovery"
}

test_sockstat_fallback() {
  output=$TEST_ROOT/render-fallback.out
  SOCKSTAT_FIXTURE=$FIXTURE_DIR/sockstat-9100.txt run_cli \
    --state-dir "$TEST_ROOT/state3" \
    --torrc "$FIXTURE_DIR/torrc-missing-address.conf" \
    render >"$output"
  assert_contains "$output" 'to 203.0.113.9 port 9100' "render should resolve missing Address via sockstat"
  pass "render with sockstat fallback"
}

test_apply_requires_targets() {
  output=$TEST_ROOT/apply-fail.out
  if run_cli --state-dir "$TEST_ROOT/state4" --torrc "$FIXTURE_DIR/torrc-empty.conf" apply >"$output" 2>&1; then
    fail "apply should fail when no targets are available"
  fi
  assert_contains "$output" 'no protected targets were discovered or configured' "apply should explain missing targets"
  pass "apply fails safely without targets"
}

test_check_validates_rendered_anchor() {
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state-check" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" check >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-n -a tor-anchor -f $TEST_ROOT/state-check/tor_anchor-anchor.conf" "check should syntax-check the rendered anchor"
  pass "check validates the rendered anchor"
}

test_status_reports_trust_age() {
  mkdir -p "$TEST_ROOT/state-status-age"
  : >"$TEST_ROOT/state-status-age/trust-v4.txt"
  : >"$TEST_ROOT/state-status-age/trust-v6.txt"
  TZ=UTC touch -t 202001010000 "$TEST_ROOT/state-status-age/trust-v4.txt" "$TEST_ROOT/state-status-age/trust-v6.txt"
  status_out=$TEST_ROOT/status-age.out
  run_cli --state-dir "$TEST_ROOT/state-status-age" status >"$status_out"
  assert_contains "$status_out" "Trust data age:" "status should report trust data age when trust files exist"
  assert_contains "$status_out" "Trust data status: stale (run tor-anchor refresh)" "status should flag stale trust data"
  pass "status reports trust data age"
}

test_status_reports_unknown_trust_age() {
  status_out=$TEST_ROOT/status-unknown.out
  run_cli --state-dir "$TEST_ROOT/state-status-unknown" status >"$status_out"
  assert_contains "$status_out" "Trust data age: unknown (run tor-anchor refresh)" "status should report unknown trust age before first refresh"
  pass "status reports missing trust snapshot"
}

test_install_hook_is_idempotent() {
  pf_conf=$TEST_ROOT/pf.conf
  cat >"$pf_conf" <<'EOF'
set skip on lo0
block in all
anchor "tor-anchor"
pass out all
EOF

  run_cli --pf-conf "$pf_conf" install-hook >/dev/null
  assert_contains "$pf_conf" 'anchor "tor-anchor"' "install-hook should add the managed anchor hook"
  hook_line=$(grep -n '^anchor "tor-anchor"$' "$pf_conf" | cut -d: -f1)
  block_line=$(grep -n '^block in all$' "$pf_conf" | cut -d: -f1)
  [ "$hook_line" -lt "$block_line" ] || fail "install-hook should move the anchor before the first filter rule"

  run_cli --pf-conf "$pf_conf" install-hook >/dev/null
  hook_count=$(grep -c '^anchor "tor-anchor"$' "$pf_conf")
  [ "$hook_count" -eq 1 ] || fail "install-hook should not duplicate the anchor hook"
  pass "install-hook adds or repositions the PF root hook once"
}

test_enable_installs_reload_and_apply() {
  pf_conf=$TEST_ROOT/pf-enable.conf
  printf 'set skip on lo0\n' >"$pf_conf"
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  PFCTL_HAS_HOOK=0 run_cli --pf-conf "$pf_conf" --state-dir "$TEST_ROOT/state-enable" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" enable >/dev/null
  assert_contains "$pf_conf" 'anchor "tor-anchor"' "enable should install the PF root hook when missing"
  assert_contains "$TEST_ROOT/pfctl.log" "-nf $pf_conf" "enable should syntax-check pf.conf"
  assert_contains "$TEST_ROOT/pfctl.log" "-f $pf_conf" "enable should reload pf.conf"
  assert_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f $TEST_ROOT/state-enable/tor_anchor-anchor.conf" "enable should load the managed anchor"
  pass "enable installs the hook, reloads PF, and applies the anchor"
}

test_apply_status_refresh_disable() {
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  run_cli --state-dir "$TEST_ROOT/state5" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f $TEST_ROOT/state5/tor_anchor-anchor.conf" "apply should load anchor"
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "apply should refresh IPv4 trust table"
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_block_v4 -T expire 300" "apply should lazily expire IPv4 block-table entries when configured"
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_block_v6 -T expire 300" "apply should lazily expire IPv6 block-table entries when configured"

  status_out=$TEST_ROOT/status.out
  run_cli --state-dir "$TEST_ROOT/state5" --profile aggressive status >"$status_out"
  assert_contains "$status_out" "Anchor loaded: yes" "status should report loaded anchor"
  assert_contains "$status_out" "inet 198.51.100.10:9001" "status should list protected target"
  assert_contains "$status_out" "Block expiry: 300s (lazy, on next enable/apply/refresh)" "status should describe lazy expiry semantics"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" --profile aggressive refresh >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "refresh should replace trust table"
  assert_contains "$TEST_ROOT/pfctl.log" "-t tor_anchor_block_v4 -T expire 300" "refresh should lazily expire IPv4 block-table entries when configured"
  assert_not_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f $TEST_ROOT/state5/tor_anchor-anchor.conf" "refresh should not reload anchor"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" disable >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a tor-anchor -f /dev/null" "disable should empty the managed anchor"
  pass "apply, status, refresh, and disable"
}

test_render_ipv4
test_render_dualstack_and_idempotent
test_render_aggressive_profile
test_explicit_target_overrides_discovery
test_sockstat_fallback
test_apply_requires_targets
test_check_validates_rendered_anchor
test_status_reports_trust_age
test_status_reports_unknown_trust_age
test_install_hook_is_idempotent
test_enable_installs_reload_and_apply
test_apply_status_refresh_disable

printf '1..12\n'
