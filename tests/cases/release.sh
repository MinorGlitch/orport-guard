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

register_test test_build_release_bundle
