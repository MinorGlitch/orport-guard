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

test_render_is_read_only_on_state_dir() {
  mkdir -p "$TEST_ROOT/state-render-readonly"
  output=$TEST_ROOT/render-readonly.out
  run_cli --state-dir "$TEST_ROOT/state-render-readonly" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" render >"$output"
  assert_contains "$output" "file \"$TEST_ROOT/state-render-readonly/trust-v4.txt\"" "render should still reference the configured state-dir trust file paths in its preview output"
  assert_file_missing "$TEST_ROOT/state-render-readonly/targets.txt" "render should not persist discovered targets into the requested state dir"
  assert_file_missing "$TEST_ROOT/state-render-readonly/trust-v4.txt" "render should not persist trust data into the requested state dir"
  assert_file_missing "$TEST_ROOT/state-render-readonly/orport_guard-anchor.conf" "render should not leave a rendered anchor artifact in the requested state dir by default"
  pass "render uses temporary state only"
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
  assert_contains "$TEST_ROOT/pfctl.log" "-n -a orport-guard -f " "check should syntax-check a rendered anchor file"
  assert_contains "$TEST_ROOT/pfctl.log" "orport_guard-anchor.conf" "check should render the preview anchor using a temporary anchor path"
  pass "check validates the rendered anchor"
}

test_check_is_read_only_on_state_dir() {
  mkdir -p "$TEST_ROOT/state-check-readonly"
  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state-check-readonly" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" check >/dev/null
  assert_file_missing "$TEST_ROOT/state-check-readonly/targets.txt" "check should not persist discovered targets into the requested state dir"
  assert_file_missing "$TEST_ROOT/state-check-readonly/trust-v4.txt" "check should not persist trust data into the requested state dir"
  assert_file_missing "$TEST_ROOT/state-check-readonly/orport_guard-anchor.conf" "check should not leave a rendered anchor artifact in the requested state dir"
  pass "check uses temporary state only"
}

register_test test_render_ipv4
register_test test_render_dualstack_and_idempotent
register_test test_render_aggressive_profile
register_test test_render_is_read_only_on_state_dir
register_test test_explicit_target_rewrites_to_local_address
register_test test_explicit_target_overrides_discovery
register_test test_explicit_target_fails_when_local_address_is_ambiguous
register_test test_sockstat_fallback
register_test test_wildcard_listener_falls_back_to_local_interface_address
register_test test_apply_requires_targets
register_test test_check_validates_rendered_anchor
register_test test_check_is_read_only_on_state_dir
