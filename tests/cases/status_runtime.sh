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
  run_cli --state-dir "$TEST_ROOT/state-status-times" status >"$status_out"
  assert_contains "$status_out" "Profile: aggressive" "status should read the loaded profile stamp after apply"
  assert_contains "$status_out" "Cron installed: no" "status should report when managed cron is not installed"
  assert_contains "$status_out" "Last refresh: " "status should report the last refresh time"
  assert_contains "$status_out" "Last expire: " "status should report the last expire time"
  assert_not_contains "$status_out" "Last refresh: never" "status should update the refresh timestamp after apply"
  assert_not_contains "$status_out" "Last expire: never" "status should update the expire timestamp after apply"
  assert_file_missing "$TEST_ROOT/state-status-times/status-rules.out" "status should not leave a cached rules artifact in the state dir"
  pass "status reports cron state and run timestamps"
}

test_status_reports_missing_profile_stamp() {
  mkdir -p "$TEST_ROOT/state-status-stamp-missing"
  run_cli --state-dir "$TEST_ROOT/state-status-stamp-missing" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  rm -f "$TEST_ROOT/state-status-stamp-missing/loaded-profile.txt"
  status_out=$TEST_ROOT/status-stamp-missing.out
  run_cli --state-dir "$TEST_ROOT/state-status-stamp-missing" status >"$status_out"
  assert_contains "$status_out" "loaded profile unknown; stamp missing" "status should surface a missing loaded-profile stamp instead of guessing from PF rules"
  pass "status reports missing profile stamp"
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
  assert_not_contains "$TEST_ROOT/crontab" '--pf-conf ' "install-cron should not embed irrelevant PF config flags into scheduled refresh/expire commands"

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
  assert_contains "$TEST_ROOT/state-enable/loaded-profile.txt" "default" "enable should record the loaded profile explicitly"
  pass "enable installs the hook, reloads PF, and applies the anchor"
}

test_enable_collapses_pf_no_changes_noise() {
  pf_conf=$TEST_ROOT/pf-enable-no-changes.conf
  printf 'set skip on lo0\n' >"$pf_conf"
  output=$TEST_ROOT/enable-no-changes.out

  PFCTL_REPLACE_NO_CHANGES=1 run_cli --pf-conf "$pf_conf" --state-dir "$TEST_ROOT/state-enable-no-changes" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" enable >"$output" 2>&1

  assert_contains "$output" "trust tables: IPv4 unchanged, IPv6 unchanged" "enable should summarize unchanged trust tables clearly"
  assert_not_contains "$output" "no changes." "enable should not leak raw duplicate pfctl no-changes output"
  pass "enable summarizes unchanged trust tables once"
}

test_apply_status_refresh_disable() {
  mkdir -p "$TEST_ROOT/pfstate"
  : >"$TEST_ROOT/pfctl.log"

  run_cli --state-dir "$TEST_ROOT/state5" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state5/orport_guard-anchor.conf" "apply should load anchor"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "apply should refresh IPv4 trust table in the anchor context"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v4 -T expire 300" "apply should lazily expire IPv4 block-table entries when configured"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v6 -T expire 300" "apply should lazily expire IPv6 block-table entries when configured"
  assert_contains "$TEST_ROOT/state5/loaded-profile.txt" "aggressive" "apply should persist the loaded profile stamp"

  status_out=$TEST_ROOT/status.out
  run_cli --state-dir "$TEST_ROOT/state5" status >"$status_out"
  assert_contains "$status_out" "Anchor loaded: yes" "status should report loaded anchor"
  assert_not_contains "$status_out" "Anchor loaded: yesTrust table counts:" "status should keep Anchor loaded and trust counts on separate lines"
  assert_contains "$status_out" "Profile: aggressive (loaded; configured default)" "status should report the loaded profile stamp when it differs from the configured profile"
  assert_contains "$status_out" "inet 198.51.100.10:9001" "status should list protected target"
  assert_contains "$status_out" "Block expiry: 300s (lazy, on next enable/apply/refresh)" "status should describe lazy expiry semantics"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" refresh >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_trust_v4 -T replace -f $TEST_ROOT/state5/trust-v4.txt" "refresh should replace trust table in the anchor context"
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -t orport_guard_block_v4 -T expire 300" "refresh should lazily expire IPv4 block-table entries when configured"
  assert_not_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f $TEST_ROOT/state5/orport_guard-anchor.conf" "refresh should not reload anchor"

  : >"$TEST_ROOT/pfctl.log"
  run_cli --state-dir "$TEST_ROOT/state5" disable >/dev/null
  assert_contains "$TEST_ROOT/pfctl.log" "-a orport-guard -f /dev/null" "disable should empty the managed anchor"
  assert_file_missing "$TEST_ROOT/state5/loaded-profile.txt" "disable should remove the loaded-profile stamp"
  pass "apply, status, refresh, and disable"
}

test_status_reports_cron_managed_expiry() {
  rm -f "$TEST_ROOT/crontab"
  run_cli --state-dir "$TEST_ROOT/state-cron-status" --profile aggressive install-cron >/dev/null
  status_out=$TEST_ROOT/status-cron.out
  run_cli --state-dir "$TEST_ROOT/state-cron-status" status >"$status_out"
  assert_contains "$status_out" "Cron installed: yes" "status should report when managed cron is installed"
  assert_contains "$status_out" "Block expiry: 300s (managed by cron)" "status should report cron-managed expiry when the managed crontab block is present"
  pass "status reports cron-managed expiry"
}

test_status_reports_target_mismatch_hint() {
  run_cli --state-dir "$TEST_ROOT/state-status-hint" --torrc "$FIXTURE_DIR/torrc-ipv4.conf" --profile aggressive apply >/dev/null
  cat >"$TEST_ROOT/state-status-hint/targets.txt" <<'EOF'
inet|192.0.2.12|9001
EOF
  status_out=$TEST_ROOT/status-hint.out
  PFCTL_VVS_RULES_FIXTURE=$FIXTURE_DIR/pfctl-vvs-mismatch.txt \
  run_cli --state-dir "$TEST_ROOT/state-status-hint" status >"$status_out"
  assert_contains "$status_out" "Profile: aggressive (loaded; configured default)" "status should report the stamped loaded profile when it differs from the configured profile"
  assert_contains "$status_out" "Target hints:" "status should open a target-hints section when protect rules look mismatched"
  assert_contains "$status_out" "protect rule for 192.0.2.12:9001 is being evaluated but has matched no packets or states" "status should warn about a likely PF-visible target mismatch"
  pass "status reports target mismatch hints"
}

test_expire_failure_is_reported() {
  mkdir -p "$TEST_ROOT/state-expire-fail"
  output=$TEST_ROOT/expire-fail.out
  if PFCTL_FAIL_EXPIRE=1 run_cli --state-dir "$TEST_ROOT/state-expire-fail" expire >"$output" 2>&1; then
    fail "expire should fail when pfctl expiry fails"
  fi
  assert_contains "$output" "failed to expire block-table entries for orport-guard" "expire should surface the PF expiry failure"
  status_out=$TEST_ROOT/status-expire-fail.out
  run_cli --state-dir "$TEST_ROOT/state-expire-fail" status >"$status_out"
  assert_contains "$status_out" "Last expire: failed " "status should report the last expire attempt as failed"
  pass "expire failure is reported"
}

test_trust_fetch_failure_preserves_existing_cache() {
  state_dir=$TEST_ROOT/state-trust-fetch-fail
  mkdir -p "$state_dir"
  printf 'sentinel-v4\n' >"$state_dir/trust-v4.txt"
  printf 'sentinel-v6\n' >"$state_dir/trust-v6.txt"
  output=$TEST_ROOT/trust-fetch-fail.out
  if CURL_FAIL_URL_SUBSTRING=authorities-v4.txt run_cli --state-dir "$state_dir" refresh >"$output" 2>&1; then
    fail "refresh should fail when a trust-list fetch fails"
  fi
  assert_contains "$output" "failed to fetch IPv4 trust list: authorities-v4.txt" "refresh should surface the failed trust-list download"
  assert_contains "$state_dir/trust-v4.txt" "sentinel-v4" "failed trust refresh should leave the previous IPv4 cache in place"
  assert_contains "$state_dir/trust-v6.txt" "sentinel-v6" "failed trust refresh should leave the previous IPv6 cache in place"
  pass "trust fetch failure preserves existing cache"
}

register_test test_status_reports_trust_age
register_test test_status_reports_unknown_trust_age
register_test test_status_reports_cron_and_run_timestamps
register_test test_status_reports_missing_profile_stamp
register_test test_install_hook_is_idempotent
register_test test_install_and_remove_cron
register_test test_enable_installs_reload_and_apply
register_test test_enable_collapses_pf_no_changes_noise
register_test test_apply_status_refresh_disable
register_test test_status_reports_cron_managed_expiry
register_test test_status_reports_target_mismatch_hint
register_test test_expire_failure_is_reported
register_test test_trust_fetch_failure_preserves_existing_cache
