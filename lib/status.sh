tor_ddos_status_table_count() {
  table_name=$1
  if ! command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 0
  fi

  if output=$(tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$table_name" -T show 2>/dev/null); then
    printf '%s\n' "$output" | awk 'NF { n++ } END { print n + 0 }'
  else
    printf 'inaccessible\n'
  fi
}

tor_ddos_status_anchor_loaded() {
  if ! command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 0
  fi

  if output=$(tor_ddos_pfctl -a "$PF_ANCHOR" -sr 2>/dev/null); then
    if [ -n "$output" ]; then
      printf 'yes\n'
    else
      printf 'no\n'
    fi
  else
    printf 'inaccessible\n'
  fi
}

tor_ddos_status_print_enabled_state() {
  label=$1
  value=$2
  printf '%s: %s\n' "$label" "$value"
}

tor_ddos_status_rules_snapshot() {
  if ! command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    printf 'unavailable|\n'
    return 0
  fi

  rules_output_file=$(mktemp "${TMPDIR:-/tmp}/orport-guard-status.XXXXXX")
  if tor_ddos_pfctl -a "$PF_ANCHOR" -vvs rules >"$rules_output_file" 2>/dev/null; then
    printf 'ok|%s\n' "$rules_output_file"
  else
    : >"$rules_output_file"
    printf 'inaccessible|%s\n' "$rules_output_file"
  fi
}

tor_ddos_status_print_targets() {
  printf '\nProtected targets:\n'
  if [ -s "$TARGETS_FILE" ]; then
    while IFS='|' read -r family addr port; do
      [ -n "$family" ] || continue
      printf '  - %s %s:%s\n' "$family" "$addr" "$port"
    done <"$TARGETS_FILE"
  else
    printf '  (none)\n'
  fi
}

tor_ddos_status_suggested_command() {
  anchor_loaded=$1

  if ! tor_ddos_pf_conf_has_hook; then
    printf 'orport-guard enable\n'
  elif ! tor_ddos_root_hook_present; then
    printf 'pfctl -nf %s && pfctl -f %s\n' "$PF_CONF" "$PF_CONF"
  elif [ "$anchor_loaded" = "inaccessible" ] || [ "$anchor_loaded" = "unavailable" ]; then
    printf 'doas orport-guard status\n'
  elif [ "$anchor_loaded" = "yes" ]; then
    printf 'orport-guard refresh\n'
  else
    printf 'orport-guard apply\n'
  fi
}

tor_ddos_status_rule_hints() {
  rules_file=$1
  [ -f "$rules_file" ] || return 0

  awk '
    BEGIN {
      evals = packets = states = -1
      label = ""
    }
    /label "orport-guard protect / {
      label = $0
      sub(/^.*label "orport-guard protect /, "", label)
      sub(/".*$/, "", label)
      evals = packets = states = -1
      next
    }
    label != "" && /\[ Evaluations:/ {
      line = $0
      sub(/^.*Evaluations:[[:space:]]*/, "", line)
      evals = line + 0
      sub(/^.*Packets:[[:space:]]*/, "", line)
      packets = line + 0
      sub(/^.*States:[[:space:]]*/, "", line)
      states = line + 0
      if (evals >= 100 && packets == 0 && states == 0) {
        printf "  - protect rule for %s is being evaluated but has matched no packets or states; verify that PF sees the relay on the configured local address\n", label
      }
      label = ""
      next
    }
    label != "" && /^@/ {
      label = ""
    }
  ' "$rules_file"
}

tor_ddos_status_display_profile() {
  configured_profile=$1
  anchor_loaded=$2

  if [ "$anchor_loaded" = "yes" ]; then
    if loaded_profile=$(tor_ddos_read_loaded_profile 2>/dev/null); then
      if [ "$loaded_profile" = "$configured_profile" ]; then
        printf '%s\n' "$loaded_profile"
      else
        printf '%s (loaded; configured %s)\n' "$loaded_profile" "$configured_profile"
      fi
      return 0
    fi

    printf '%s (loaded profile unknown; stamp missing)\n' "$configured_profile"
    return 0
  fi

  printf '%s\n' "$configured_profile"
}

tor_ddos_status() {
  tor_ddos_finalize_paths
  rules_output_file=
  configured_profile=$PROFILE
  rules_snapshot=$(tor_ddos_status_rules_snapshot)
  rules_query_status=${rules_snapshot%%|*}
  rules_output_file=${rules_snapshot#*|}
  [ "$rules_output_file" = "$rules_query_status" ] && rules_output_file=
  anchor_loaded=$(tor_ddos_status_anchor_loaded)
  display_profile=$(tor_ddos_status_display_profile "$configured_profile" "$anchor_loaded")
  printf 'Anchor: %s\n' "$PF_ANCHOR"
  printf 'State dir: %s\n' "$STATE_DIR"
  printf 'Rendered anchor: %s\n' "$RENDER_FILE"
  printf 'PF config: %s\n' "$PF_CONF"
  printf 'Profile: %s\n' "$display_profile"
  if [ "$BLOCK_EXPIRE_SECONDS" -gt 0 ]; then
    if tor_ddos_cron_installed; then
      printf 'Block expiry: %ss (managed by cron)\n' "$BLOCK_EXPIRE_SECONDS"
    else
      printf 'Block expiry: %ss (lazy, on next enable/apply/refresh)\n' "$BLOCK_EXPIRE_SECONDS"
    fi
  else
    printf 'Block expiry: disabled\n'
  fi
  if tor_ddos_cron_installed; then
    tor_ddos_status_print_enabled_state "Cron installed" yes
  else
    tor_ddos_status_print_enabled_state "Cron installed" no
  fi
  if tor_ddos_pf_conf_has_hook; then
    tor_ddos_status_print_enabled_state "PF config hook" yes
  else
    tor_ddos_status_print_enabled_state "PF config hook" no
  fi
  if command -v "$PFCTL_CMD" >/dev/null 2>&1 && tor_ddos_root_hook_present; then
    tor_ddos_status_print_enabled_state "Root hook present" yes
  else
    tor_ddos_status_print_enabled_state "Root hook present" no
  fi
  printf 'Anchor loaded: %s\n' "$anchor_loaded"
  printf 'Last refresh: %s\n' "$(tor_ddos_format_last_run "$LAST_REFRESH_FILE")"
  if [ "$BLOCK_EXPIRE_SECONDS" -gt 0 ]; then
    printf 'Last expire: %s\n' "$(tor_ddos_format_last_expire_run)"
  else
    printf 'Last expire: disabled\n'
  fi
  printf 'Trust table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$TRUST_V4_TABLE")" "$(tor_ddos_status_table_count "$TRUST_V6_TABLE")"
  printf 'Block table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$BLOCK_V4_TABLE")" "$(tor_ddos_status_table_count "$BLOCK_V6_TABLE")"
  if trust_age=$(tor_ddos_trust_age_seconds 2>/dev/null); then
    printf 'Trust data age: %s\n' "$(tor_ddos_format_age "$trust_age")"
    if [ "$trust_age" -gt 604800 ]; then
      printf 'Trust data status: stale (run orport-guard refresh)\n'
    else
      printf 'Trust data status: fresh enough\n'
    fi
  else
    printf 'Trust data age: unknown (run orport-guard refresh)\n'
  fi
  tor_ddos_status_print_targets

  if [ -n "$rules_output_file" ] && [ "$rules_query_status" = ok ]; then
    hints=$(tor_ddos_status_rule_hints "$rules_output_file" 2>/dev/null || true)
    if [ -n "$hints" ]; then
      printf '\nTarget hints:\n%s' "$hints"
    fi
  fi

  if [ -n "$rules_output_file" ] && [ "$rules_query_status" = ok ]; then
    printf '\nAnchor rules:\n'
    cat "$rules_output_file"
  elif [ "$rules_query_status" = inaccessible ]; then
    printf '\nAnchor rules:\n'
    printf '  (unavailable: pfctl -a %s -vvs rules failed)\n' "$PF_ANCHOR"
  fi

  printf '\nSuggested command: '
  tor_ddos_status_suggested_command "$anchor_loaded"

  [ -n "$rules_output_file" ] && rm -f "$rules_output_file"
}
