#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$ROOT_DIR/tests/tmp
STUB_DIR=$ROOT_DIR/tests/stubs
FIXTURE_DIR=$ROOT_DIR/tests/fixtures
CLI=$ROOT_DIR/bin/orport-guard

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
  PFCTL_VVS_RULES_FIXTURE=${PFCTL_VVS_RULES_FIXTURE:-} \
  CRONTAB_FILE=$TEST_ROOT/crontab \
  SOCKSTAT_FIXTURE=${SOCKSTAT_FIXTURE:-} \
  IFCONFIG_FIXTURE=${IFCONFIG_FIXTURE:-} \
  TOR_DDOS_BSD_ALLOW_UNSUPPORTED=1 \
  PFCTL_CMD=pfctl \
  SOCKSTAT_CMD=sockstat \
  IFCONFIG_CMD=ifconfig \
  PATH="$STUB_DIR:$PATH" \
  "$CLI" "$@"
}

test_render_ipv4() {
  output=$TEST_ROOT/render-ipv4.out
  run_cli --state-dir "$TEST_ROOT/state1" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" render >"$output"
  assert_contains "$output" 'to 198.51.100.10 port 9001' "render should contain discovered IPv4 ORPort"
  assert_contains "$output" 'table <orport_guard_trust_v4>' "render should contain IPv4 trust table"
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

test_explicit_target_rewrites_to_local_address() {
  output=$TEST_ROOT/render-explicit-local.out
  stderr_out=$TEST_ROOT/render-explicit-local.err
  IFCONFIG_FIXTURE=$FIXTURE_DIR/ifconfig-single-v4.txt run_cli \
    --state-dir "$TEST_ROOT/state-explicit-local" \
    --target "203.0.113.165:9001" \
    render >"$output" 2>"$stderr_out"
  assert_contains "$output" 'to 192.0.2.12 port 9001' "render should rewrite a non-local target to the unique PF-visible local IPv4 address"
  assert_not_contains "$output" 'to 203.0.113.165 port 9001' "render should not keep the non-local public IPv4 target when a unique local address exists"
  assert_contains "$stderr_out" 'using local address 192.0.2.12:9001' "render should explain the NAT-aware target rewrite"
  pass "explicit target rewrites to PF-visible local address"
}

test_explicit_target_overrides_discovery() {
  output=$TEST_ROOT/render-explicit-override.out
  run_cli --state-dir "$TEST_ROOT/state-override" --torrc "$FIXTURE_DIR/torrc-dualstack.conf" --target "203.0.113.50:9100" render >"$output"
  assert_contains "$output" 'to 203.0.113.50 port 9100' "render should contain the explicit target"
  assert_not_contains "$output" 'to 198.51.100.11 port 443' "explicit target should suppress discovered IPv4 targets"
  assert_not_contains "$output" 'to 2001:db8::11 port 9001' "explicit target should suppress discovered IPv6 targets"
  pass "explicit targets override discovery"
}

test_explicit_target_fails_when_local_address_is_ambiguous() {
  output=$TEST_ROOT/render-explicit-ambiguous.out
  if IFCONFIG_FIXTURE=$FIXTURE_DIR/ifconfig-multi-v4.txt run_cli \
    --state-dir "$TEST_ROOT/state-explicit-ambiguous" \
    --target "203.0.113.165:9001" \
    render >"$output" 2>&1; then
    fail "render should fail when the PF-visible local target is ambiguous"
  fi
  assert_contains "$output" 'candidate local addresses: 192.0.2.12 192.0.2.13' "render should explain the ambiguous local IPv4 targets"
  pass "explicit target fails when the PF-visible local address is ambiguous"
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

test_wildcard_listener_falls_back_to_local_interface_address() {
  output=$TEST_ROOT/render-wildcard-ifconfig.out
  IFCONFIG_FIXTURE=$FIXTURE_DIR/ifconfig-single-v4.txt \
  SOCKSTAT_FIXTURE=$FIXTURE_DIR/sockstat-wildcard-9100.txt \
  run_cli --state-dir "$TEST_ROOT/state-wildcard-ifconfig" \
    --torrc "$FIXTURE_DIR/torrc-missing-address.conf" \
    render >"$output"
  assert_contains "$output" 'to 192.0.2.12 port 9100' "render should fall back to the unique local IPv4 address when sockstat only exposes a wildcard listener"
  pass "wildcard listener falls back to local interface address"
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
  assert_contains "$TEST_ROOT/pfctl.log" "-n -a orport-guard -f $TEST_ROOT/state-check/orport_guard-anchor.conf" "check should syntax-check the rendered anchor"
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
  assert_contains "$status_out" "Trust data status: stale (run orport-guard refresh)" "status should flag stale trust data"
  pass "status reports trust data age"
}

test_status_reports_unknown_trust_age() {
  status_out=$TEST_ROOT/status-unknown.out
  run_cli --state-dir "$TEST_ROOT/state-status-unknown" status >"$status_out"
  assert_contains "$status_out" "Trust data age: unknown (run orport-guard refresh)" "status should report unknown trust age before first refresh"
  pass "status reports missing trust snapshot"
}

test_status_reports_cron_and_run_timestamps() {
  mkdir -p "$TEST_ROOT/state-status-times"
  run_cli --state-dir "$TEST_ROOT/state-status-times" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  status_out=$TEST_ROOT/status-times.out
  run_cli --state-dir "$TEST_ROOT/state-status-times" --profile aggressive status >"$status_out"
  assert_contains "$status_out" "Cron installed: no" "status should report when managed cron is not installed"
  assert_contains "$status_out" "Last refresh: " "status should report the last refresh time"
  assert_contains "$status_out" "Last expire: " "status should report the last expire time"
  assert_not_contains "$status_out" "Last refresh: never" "status should update the refresh timestamp after apply"
  assert_not_contains "$status_out" "Last expire: never" "status should update the expire timestamp after apply"
  pass "status reports cron state and run timestamps"
}

test_install_hook_is_idempotent() {
  pf_conf=$TEST_ROOT/pf.conf
  cat >"$pf_conf" <<'EOF'
set skip on lo0
block in all
anchor "orport-guard"
pass out all
EOF

  run_cli --pf-conf "$pf_conf" install-hook >/dev/null
  assert_contains "$pf_conf" 'anchor "orport-guard"' "install-hook should add the managed anchor hook"
  hook_line=$(grep -n '^anchor "orport-guard"$' "$pf_conf" | cut -d: -f1)
  block_line=$(grep -n '^block in all$' "$pf_conf" | cut -d: -f1)
  [ "$hook_line" -lt "$block_line" ] || fail "install-hook should move the anchor before the first filter rule"

  run_cli --pf-conf "$pf_conf" install-hook >/dev/null
  hook_count=$(grep -c '^anchor "orport-guard"$' "$pf_conf")
  [ "$hook_count" -eq 1 ] || fail "install-hook should not duplicate the anchor hook"
  pass "install-hook adds or repositions the PF root hook once"
}

test_install_and_remove_cron() {
  rm -f "$TEST_ROOT/crontab"
  run_cli --state-dir "$TEST_ROOT/state-cron" --profile aggressive install-cron >/dev/null
  assert_contains "$TEST_ROOT/crontab" '# BEGIN orport-guard' "install-cron should add the managed block marker"
  assert_contains "$TEST_ROOT/crontab" '* * * * * ' "install-cron should schedule expiry every minute"
  assert_contains "$TEST_ROOT/crontab" ' expire >/dev/null 2>&1' "install-cron should schedule the expire command"
  assert_contains "$TEST_ROOT/crontab" '17 */6 * * * ' "install-cron should schedule refresh every 6 hours"
  assert_contains "$TEST_ROOT/crontab" ' refresh >/dev/null 2>&1' "install-cron should schedule the refresh command"

  before=$(grep -c '^# BEGIN orport-guard$' "$TEST_ROOT/crontab")
  run_cli --state-dir "$TEST_ROOT/state-cron" --profile aggressive install-cron >/dev/null
  after=$(grep -c '^# BEGIN orport-guard$' "$TEST_ROOT/crontab")
  [ "$before" -eq 1 ] && [ "$after" -eq 1 ] || fail "install-cron should be idempotent"

  run_cli remove-cron >/dev/null
  assert_not_contains "$TEST_ROOT/crontab" '# BEGIN orport-guard' "remove-cron should remove the managed block marker"
  pass "install-cron and remove-cron manage the crontab block"
}

test_enable_installs_reload_and_apply() {
  pf_conf=$TEST_ROOT/pf-enable.conf
  printf 'set skip on lo0\n' >"$pf_conf"
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  PFCTL_HAS_HOOK=0 run_cli --pf-conf "$pf_conf" --state-dir "$TEST_ROOT/state-enable" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" enable >/dev/null
  assert_contains "$pf_conf" 'anchor "orport-guard"' "enable should install the PF root hook when missing"
  assert_contains "$TEST_ROOT/pfctl.log" "-nf $pf_conf" "enable should syntax-check pf.conf"
  assert_contains "$TEST_ROOT/pfctl.log" "-f $pf_conf" "enable should reload pf.conf"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state-enable/orport_guard-anchor.conf" "enable should load the managed anchor"
  pass "enable installs the hook, reloads PF, and applies the anchor"
}

test_apply_status_refresh_disable() {
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  run_cli --state-dir "$TEST_ROOT/state5" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state5/orport_guard-anchor.conf" "apply should load anchor"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "apply should refresh IPv4 trust table in the anchor context"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v4 -T expire 300" "apply should lazily expire IPv4 block-table entries when configured"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v6 -T expire 300" "apply should lazily expire IPv6 block-table entries when configured"

  status_out=$TEST_ROOT/status.out
  run_cli --state-dir "$TEST_ROOT/state5" --profile aggressive status >"$status_out"
  assert_contains "$status_out" "Anchor loaded: yes" "status should report loaded anchor"
  assert_not_contains "$status_out" "Anchor loaded: yesTrust table counts:" "status should keep Anchor loaded and trust counts on separate lines"
  assert_contains "$status_out" "inet 198.51.100.10:9001" "status should list protected target"
  assert_contains "$status_out" "Block expiry: 300s (lazy, on next enable/apply/refresh)" "status should describe lazy expiry semantics"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" --profile aggressive refresh >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "refresh should replace trust table in the anchor context"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v4 -T expire 300" "refresh should lazily expire IPv4 block-table entries when configured"
  assert_not_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state5/orport_guard-anchor.conf" "refresh should not reload anchor"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" disable >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f /dev/null" "disable should empty the managed anchor"
  pass "apply, status, refresh, and disable"
}

test_status_reports_cron_managed_expiry() {
  rm -f "$TEST_ROOT/crontab"
  run_cli --state-dir "$TEST_ROOT/state-cron-status" --profile aggressive install-cron >/dev/null
  status_out=$TEST_ROOT/status-cron.out
  run_cli --state-dir "$TEST_ROOT/state-cron-status" --profile aggressive status >"$status_out"
  assert_contains "$status_out" "Cron installed: yes" "status should report when managed cron is installed"
  assert_contains "$status_out" "Block expiry: 300s (managed by cron)" "status should report cron-managed expiry when the managed crontab block is present"
  pass "status reports cron-managed expiry"
}

test_status_reports_target_mismatch_hint() {
  mkdir -p "$TEST_ROOT/state-status-hint"
  cat >"$TEST_ROOT/state-status-hint/targets.txt" <<'EOF'
inet|192.0.2.12|9001
EOF
  status_out=$TEST_ROOT/status-hint.out
  PFCTL_VVS_RULES_FIXTURE=$FIXTURE_DIR/pfctl-vvs-mismatch.txt \
  run_cli --state-dir "$TEST_ROOT/state-status-hint" status >"$status_out"
  assert_contains "$status_out" "Target hints:" "status should open a target-hints section when protect rules look mismatched"
  assert_contains "$status_out" "protect rule for 192.0.2.12:9001 is being evaluated but has matched no packets or states" "status should warn about a likely PF-visible target mismatch"
  pass "status reports target mismatch hints"
}

test_render_ipv4
test_render_dualstack_and_idempotent
test_render_aggressive_profile
test_explicit_target_rewrites_to_local_address
test_explicit_target_overrides_discovery
test_explicit_target_fails_when_local_address_is_ambiguous
test_sockstat_fallback
test_wildcard_listener_falls_back_to_local_interface_address
test_apply_requires_targets
test_check_validates_rendered_anchor
test_status_reports_trust_age
test_status_reports_unknown_trust_age
test_status_reports_cron_and_run_timestamps
test_install_hook_is_idempotent
test_install_and_remove_cron
test_enable_installs_reload_and_apply
test_apply_status_refresh_disable
test_status_reports_cron_managed_expiry
test_status_reports_target_mismatch_hint

printf '1..20\n'
