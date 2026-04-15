test_conflicting_ip_family_flags_fail() {
  output=$TEST_ROOT/family-flags-fail.out
  if run_cli --ipv4-only --ipv6-only status >"$output" 2>&1; then
    fail "status should fail when both family restriction flags are supplied"
  fi
  assert_contains "$output" "cannot combine --" "CLI should reject contradictory family flags"
  pass "conflicting family flags fail"
}

test_trailing_args_after_command_fail() {
  output=$TEST_ROOT/trailing-args-fail.out
  if run_cli status --state-dir "$TEST_ROOT/state-trailing-args" >"$output" 2>&1; then
    fail "CLI should reject trailing arguments after the subcommand"
  fi
  assert_contains "$output" "unexpected trailing argument after status" "CLI should reject flags placed after the subcommand"
  pass "trailing args after command fail"
}

test_missing_explicit_config_fails() {
  output=$TEST_ROOT/missing-config-fail.out
  if run_cli --config "$TEST_ROOT/does-not-exist.conf" status >"$output" 2>&1; then
    fail "CLI should fail when an explicitly requested config file is missing"
  fi
  assert_contains "$output" "config file not found" "CLI should fail hard on a missing explicit config file"
  pass "missing explicit config fails"
}

test_pfctl_stub_rejects_unknown_invocations() {
  output=$TEST_ROOT/pfctl-stub-unknown.out
  if PFCTL_LOG=$TEST_ROOT/pfctl-stub.log PFCTL_STATE_DIR=$TEST_ROOT/pfstate-stub "$STUB_DIR/pfctl" --bogus >"$output" 2>&1; then
    fail "pfctl stub should fail on unsupported invocation shapes"
  fi
  assert_contains "$output" "unsupported pfctl invocation" "pfctl stub should fail loudly on unsupported invocation shapes"
  pass "pfctl stub rejects unknown invocations"
}

test_status_rejects_profile_override() {
  output=$TEST_ROOT/status-profile-flag-fail.out
  if run_cli --profile aggressive status >"$output" 2>&1; then
    fail "status should reject an explicit profile override"
  fi
  assert_contains "$output" "option --profile is not supported for status" "status should reject profile because it infers the live loaded profile"
  pass "status rejects profile override"
}

test_install_hook_rejects_runtime_target_flags() {
  output=$TEST_ROOT/install-hook-target-flag-fail.out
  if run_cli --target "198.51.100.10:9001" install-hook >"$output" 2>&1; then
    fail "install-hook should reject runtime target flags"
  fi
  assert_contains "$output" "option --target is not supported for install-hook" "install-hook should reject target flags"
  pass "install-hook rejects runtime target flags"
}

test_remove_cron_rejects_runtime_flags() {
  output=$TEST_ROOT/remove-cron-flag-fail.out
  if run_cli --state-dir "$TEST_ROOT/state-remove-cron-flag" remove-cron >"$output" 2>&1; then
    fail "remove-cron should reject unrelated runtime flags"
  fi
  assert_contains "$output" "option --state-dir is not supported for remove-cron" "remove-cron should reject runtime state flags"
  pass "remove-cron rejects runtime flags"
}

test_update_rejects_runtime_flags() {
  output=$TEST_ROOT/update-flag-fail.out
  if run_cli --state-dir "$TEST_ROOT/state-update-flag" update >"$output" 2>&1; then
    fail "update should reject unrelated runtime flags"
  fi
  assert_contains "$output" "option --state-dir is not supported for update" "update should reject runtime state flags"
  pass "update rejects runtime flags"
}

test_status_auto_escalates_via_doas() {
  rm -f "$TEST_ROOT/doas.log"
  status_out=$TEST_ROOT/status-escalated.out
  run_cli_with_escalation status >"$status_out" 2>&1
  assert_contains "$TEST_ROOT/doas.log" "$CLI status" "status should re-exec itself through doas when not already privileged"
  assert_contains "$status_out" "Anchor: orport-guard" "status should still run normally after privilege escalation"
  pass "status auto-escalates via doas"
}

test_apply_auto_escalates_via_doas() {
  rm -f "$TEST_ROOT/doas.log"
  : >"$TEST_ROOT/pfctl.log"
  TOR_DDOS_ESCALATED_ALLOW_UNSUPPORTED=1 run_cli_with_escalation \
    --state-dir "$TEST_ROOT/state-auto-escalate-apply" \
    --torrc "$FIXTURE_DIR/torrc-ipv4.conf" \
    apply >/dev/null
  assert_contains "$TEST_ROOT/doas.log" "$CLI --state-dir $TEST_ROOT/state-auto-escalate-apply --torrc $FIXTURE_DIR/torrc-ipv4.conf apply" "apply should re-exec itself through doas when not already privileged"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state-auto-escalate-apply/orport_guard-anchor.conf" "apply should still execute after privilege escalation"
  pass "apply auto-escalates via doas"
}

register_test test_conflicting_ip_family_flags_fail
register_test test_trailing_args_after_command_fail
register_test test_missing_explicit_config_fails
register_test test_pfctl_stub_rejects_unknown_invocations
register_test test_status_rejects_profile_override
register_test test_install_hook_rejects_runtime_target_flags
register_test test_remove_cron_rejects_runtime_flags
register_test test_update_rejects_runtime_flags
register_test test_status_auto_escalates_via_doas
register_test test_apply_auto_escalates_via_doas
