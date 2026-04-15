test_build_release_bundle() {
  dist_dir=$TEST_ROOT/dist
  output=$TEST_ROOT/build-release.out
  "$ROOT_DIR/scripts/build-release.sh" "$dist_dir" >"$output"
  assert_file_exists "$dist_dir/orport-guard" "build-release should emit a standalone release script"
  assert_file_exists "$dist_dir/orport-guard.conf.example" "build-release should emit a sample config"
  assert_file_exists "$dist_dir/SHA256SUMS" "build-release should emit checksums"
  assert_not_contains "$dist_dir/orport-guard" '. "$ROOT_DIR/lib/pf.sh"' "bundled release script should not source repo library files"
  assert_not_contains "$dist_dir/orport-guard" '. "$ROOT_DIR/lib/cli.sh"' "bundled release script should not source repo CLI helpers"
  sh -n "$dist_dir/orport-guard" || fail "bundled release script should pass sh -n"
  pass "build-release emits a standalone bundle"
}

test_release_update_replaces_standalone_script() {
  install_dir=$TEST_ROOT/update-install
  dist_dir=$TEST_ROOT/update-dist
  mkdir -p "$install_dir"

  "$ROOT_DIR/scripts/build-release.sh" "$dist_dir" >/dev/null
  cp "$dist_dir/orport-guard" "$install_dir/orport-guard"
  chmod +x "$install_dir/orport-guard"

  cat >"$TEST_ROOT/new-release.sh" <<'EOF'
#!/bin/sh
echo "updated artifact"
EOF
  chmod +x "$TEST_ROOT/new-release.sh"

  output=$TEST_ROOT/update-command.out
  CURL_DOWNLOAD_FILE=$TEST_ROOT/new-release.sh \
  PATH="$STUB_DIR:$PATH" \
  "$install_dir/orport-guard" update >"$output" 2>&1

  assert_contains "$output" "updated $install_dir/orport-guard from https://github.com/MinorGlitch/orport-guard/releases/latest/download/orport-guard" "update should report the release artifact replacement"
  assert_contains "$install_dir/orport-guard" 'echo "updated artifact"' "update should replace the current standalone script with the downloaded artifact"
  pass "update replaces the standalone release artifact"
}

test_release_update_reports_when_current() {
  install_dir=$TEST_ROOT/update-current
  dist_dir=$TEST_ROOT/update-current-dist
  mkdir -p "$install_dir"

  "$ROOT_DIR/scripts/build-release.sh" "$dist_dir" >/dev/null
  cp "$dist_dir/orport-guard" "$install_dir/orport-guard"
  chmod +x "$install_dir/orport-guard"

  output=$TEST_ROOT/update-current.out
  CURL_DOWNLOAD_FILE=$install_dir/orport-guard \
  PATH="$STUB_DIR:$PATH" \
  "$install_dir/orport-guard" update >"$output" 2>&1

  assert_contains "$output" "already up to date: $install_dir/orport-guard" "update should report when the standalone script already matches the latest artifact"
  pass "update reports when already current"
}

register_test test_build_release_bundle
register_test test_release_update_replaces_standalone_script
register_test test_release_update_reports_when_current
