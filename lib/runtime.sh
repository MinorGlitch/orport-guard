tor_ddos_replace_anchor_table() {
  family_label=$1
  table_name=$2
  table_file=$3

  output=$(tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$table_name" -T replace -f "$table_file" 2>&1) ||
    tor_ddos_die "failed to refresh $family_label trust table for $PF_ANCHOR"

  normalized_output=$(printf '%s\n' "$output" | awk 'NF')
  if [ -z "$normalized_output" ]; then
    printf '%s refreshed\n' "$family_label"
    return 0
  fi

  if printf '%s\n' "$normalized_output" | awk '$0 != "no changes." { exit 1 }'; then
    printf '%s unchanged\n' "$family_label"
    return 0
  fi

  printf '%s refreshed\n' "$family_label"
}

tor_ddos_apply_tables() {
  table_statuses=
  separator=

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    table_statuses="${table_statuses}${separator}$(tor_ddos_replace_anchor_table "IPv4" "$TRUST_V4_TABLE" "$TRUST_V4_FILE")"
    separator=', '
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    table_statuses="${table_statuses}${separator}$(tor_ddos_replace_anchor_table "IPv6" "$TRUST_V6_TABLE" "$TRUST_V6_FILE")"
  fi

  [ -n "$table_statuses" ] && tor_ddos_log "trust tables: $table_statuses"
}

tor_ddos_cleanup_legacy_global_tables() {
  tor_ddos_pfctl -t "$TRUST_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$TRUST_V6_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V6_TABLE" -T kill >/dev/null 2>&1 || true
}

tor_ddos_record_refresh_and_expire() {
  tor_ddos_touch_file "$LAST_REFRESH_FILE"
  if ! tor_ddos_expire_block_tables_now; then
    tor_ddos_log "warning: failed to expire block-table entries for $PF_ANCHOR"
  fi
}

tor_ddos_write_crontab_file() {
  content=$1
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/orport-guard-cron.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
  printf '%s\n' "$content" >"$tmp_file"
  "$CRONTAB_CMD" "$tmp_file"
  trap - EXIT HUP INT TERM
  rm -f "$tmp_file"
}

tor_ddos_prepare_anchor() {
  tor_ddos_require_directory "$STATE_DIR"

  targets_tmp=$STATE_DIR/targets.tmp
  tor_ddos_collect_targets "$targets_tmp"
  if [ ! -s "$targets_tmp" ]; then
    tor_ddos_die "no protected targets were discovered or configured; use --target or set TARGETS"
  fi

  tor_ddos_fetch_trust_lists
  tor_ddos_write_targets_state "$targets_tmp"
  tor_ddos_render_anchor_file "$targets_tmp" "$RENDER_FILE"
}

tor_ddos_prepare_anchor_in_temporary_state() {
  preserve_render_file=$1
  original_state_dir=$STATE_DIR
  original_render_file=$RENDER_FILE
  original_default_render_file=$original_state_dir/$TABLE_PREFIX-anchor.conf

  temp_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/orport-guard-state.XXXXXX")
  STATE_DIR=$temp_state_dir
  if [ "$preserve_render_file" = 1 ] && [ "$original_render_file" != "$original_default_render_file" ]; then
    RENDER_FILE=$original_render_file
  else
    RENDER_FILE=
  fi
  tor_ddos_finalize_paths
  if ! tor_ddos_prepare_anchor; then
    rm -rf "$temp_state_dir"
    return 1
  fi
  TOR_DDOS_TEMP_STATE_DIR=$temp_state_dir
}

tor_ddos_check_anchor_syntax() {
  tor_ddos_pfctl -n -a "$PF_ANCHOR" -f "$RENDER_FILE" >/dev/null
}

tor_ddos_validate_pf_conf() {
  tor_ddos_pfctl -nf "$PF_CONF" >/dev/null
}

tor_ddos_reload_pf_conf() {
  tor_ddos_pfctl -f "$PF_CONF" >/dev/null
}

tor_ddos_expire_block_tables_now() {
  [ "$BLOCK_EXPIRE_SECONDS" -gt 0 ] || return 0

  expire_failed=0
  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V4_TABLE" -T expire "$BLOCK_EXPIRE_SECONDS" >/dev/null 2>&1 || expire_failed=1
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V6_TABLE" -T expire "$BLOCK_EXPIRE_SECONDS" >/dev/null 2>&1 || expire_failed=1
  fi
  if [ "$expire_failed" -eq 0 ]; then
    tor_ddos_touch_file "$LAST_EXPIRE_FILE"
    rm -f "$LAST_EXPIRE_FAILURE_FILE"
    return 0
  fi

  tor_ddos_touch_file "$LAST_EXPIRE_FAILURE_FILE"
  return 1
}

tor_ddos_check() {
  tor_ddos_require_pfctl
  tor_ddos_prepare_anchor_in_temporary_state 0
  temp_state_dir=$TOR_DDOS_TEMP_STATE_DIR
  trap 'rm -rf "$temp_state_dir"' EXIT HUP INT TERM
  tor_ddos_check_anchor_syntax
  if tor_ddos_pf_conf_has_hook; then
    tor_ddos_validate_pf_conf
    tor_ddos_log "PF syntax OK for anchor $PF_ANCHOR and $PF_CONF"
  else
    tor_ddos_log "PF syntax OK for anchor $PF_ANCHOR"
    tor_ddos_log "PF config does not contain anchor \"$PF_ANCHOR\" in $PF_CONF yet"
  fi
  rm -rf "$temp_state_dir"
  trap - EXIT HUP INT TERM
}

tor_ddos_expire() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_expire_block_tables_now || tor_ddos_die "failed to expire block-table entries for $PF_ANCHOR"
  if [ "$BLOCK_EXPIRE_SECONDS" -gt 0 ]; then
    tor_ddos_log "expired block-table entries older than ${BLOCK_EXPIRE_SECONDS}s for $PF_ANCHOR"
  else
    tor_ddos_log "block-table expiry disabled for $PF_ANCHOR"
  fi
}

tor_ddos_enable() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_cleanup_legacy_global_tables
  tor_ddos_prepare_anchor
  tor_ddos_check_anchor_syntax

  if ! tor_ddos_pf_conf_has_hook; then
    tor_ddos_install_hook
  fi

  tor_ddos_validate_pf_conf
  tor_ddos_reload_pf_conf
  tor_ddos_pfctl -a "$PF_ANCHOR" -f "$RENDER_FILE" >/dev/null
  tor_ddos_write_loaded_profile
  tor_ddos_apply_tables
  tor_ddos_record_refresh_and_expire
  tor_ddos_log "enabled PF anchor $PF_ANCHOR from $RENDER_FILE"
}

tor_ddos_apply() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_cleanup_legacy_global_tables
  tor_ddos_prepare_anchor

  if ! tor_ddos_root_hook_present; then
    if tor_ddos_pf_conf_has_hook; then
      tor_ddos_die "PF root rules do not contain anchor \"$PF_ANCHOR\" yet; reload $PF_CONF with pfctl -nf $PF_CONF && pfctl -f $PF_CONF"
    fi
    tor_ddos_die "PF root rules do not contain anchor \"$PF_ANCHOR\"; run $0 enable for the first install, or add that hook to $PF_CONF before apply"
  fi

  tor_ddos_pfctl -a "$PF_ANCHOR" -f "$RENDER_FILE" >/dev/null
  tor_ddos_write_loaded_profile
  tor_ddos_apply_tables
  tor_ddos_record_refresh_and_expire
  tor_ddos_log "loaded PF anchor $PF_ANCHOR from $RENDER_FILE"
}

tor_ddos_refresh() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_cleanup_legacy_global_tables
  tor_ddos_require_directory "$STATE_DIR"
  tor_ddos_fetch_trust_lists
  tor_ddos_apply_tables
  tor_ddos_record_refresh_and_expire
  tor_ddos_log "refreshed trust tables for $PF_ANCHOR"
}

tor_ddos_install_cron() {
  tor_ddos_crontab_mutation_allowed
  tor_ddos_require_crontab

  existing=$(tor_ddos_crontab_list | tor_ddos_crontab_strip_block)
  new_crontab=$(
    {
      if [ -n "$existing" ]; then
        printf '%s\n\n' "$existing"
      fi
      tor_ddos_cron_block
    }
  )
  tor_ddos_write_crontab_file "$new_crontab"

  tor_ddos_log "installed managed cron entries for $PF_ANCHOR (expire every minute, refresh every 6 hours)"
}

tor_ddos_remove_cron() {
  tor_ddos_crontab_mutation_allowed
  tor_ddos_require_crontab

  stripped_crontab=$(tor_ddos_crontab_list | tor_ddos_crontab_strip_block)
  tor_ddos_write_crontab_file "$stripped_crontab"

  tor_ddos_log "removed managed cron entries for $PF_ANCHOR"
}

tor_ddos_render() {
  original_state_dir=$STATE_DIR
  tor_ddos_prepare_anchor_in_temporary_state 1
  temp_state_dir=$TOR_DDOS_TEMP_STATE_DIR
  trap 'rm -rf "$temp_state_dir"' EXIT HUP INT TERM
  rewritten_render_file=$temp_state_dir/render-preview.out
  sed \
    -e "s|$temp_state_dir/trust-v4.txt|$original_state_dir/trust-v4.txt|g" \
    -e "s|$temp_state_dir/trust-v6.txt|$original_state_dir/trust-v6.txt|g" \
    "$RENDER_FILE" >"$rewritten_render_file"
  if [ "$RENDER_FILE" != "$temp_state_dir/$TABLE_PREFIX-anchor.conf" ]; then
    cp "$rewritten_render_file" "$RENDER_FILE"
  fi
  cat "$rewritten_render_file"
  rm -rf "$temp_state_dir"
  trap - EXIT HUP INT TERM
}

tor_ddos_disable() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl

  tor_ddos_pfctl -a "$PF_ANCHOR" -f /dev/null >/dev/null 2>&1 || true
  tor_ddos_cleanup_legacy_global_tables
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$TRUST_V4_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$TRUST_V6_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V6_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V4_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V6_TABLE" -T flush >/dev/null 2>&1 || true
  rm -f "$LOADED_PROFILE_FILE"
  tor_ddos_log "disabled PF anchor $PF_ANCHOR"
}

tor_ddos_update() {
  quoted_argv=${1:-}

  if tor_ddos_is_source_tree_invocation; then
    tor_ddos_die "update only supports the standalone release artifact; use scripts/build-release.sh locally or run the downloaded release script"
  fi

  tor_ddos_reexec_update_with_privileges_if_needed "$quoted_argv"

  program_dir=$(dirname -- "$PROGRAM_PATH")
  tmp_file=$(mktemp "$program_dir/.orport-guard.update.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

  update_url=$RELEASE_BASE_URL/orport-guard
  tor_ddos_download_file "$update_url" "$tmp_file" ||
    tor_ddos_die "failed to download update from $update_url"

  sh -n "$tmp_file" >/dev/null 2>&1 ||
    tor_ddos_die "downloaded update failed shell syntax validation"

  chmod +x "$tmp_file"

  if cmp -s "$tmp_file" "$PROGRAM_PATH"; then
    rm -f "$tmp_file"
    trap - EXIT HUP INT TERM
    tor_ddos_log "already up to date: $PROGRAM_PATH"
    return 0
  fi

  mv "$tmp_file" "$PROGRAM_PATH"
  trap - EXIT HUP INT TERM
  tor_ddos_log "updated $PROGRAM_PATH from $update_url"
}
