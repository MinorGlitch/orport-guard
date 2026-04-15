tor_ddos_set_defaults() {
  ROOT_DIR=${1:-$(pwd)}
  CONFIG_FILE_DEFAULT=${CONFIG_FILE_DEFAULT:-"$ROOT_DIR/etc/orport-guard.conf"}
  STATE_DIR=${STATE_DIR:-/var/db/orport-guard}
  PF_ANCHOR=${PF_ANCHOR:-orport-guard}
  PF_CONF=${PF_CONF:-/etc/pf.conf}
  PROFILE=${PROFILE:-default}
  ENABLE_IPV4=${ENABLE_IPV4:-1}
  ENABLE_IPV6=${ENABLE_IPV6:-1}
  TARGETS=${TARGETS:-}
  EXTRA_TRUST=${EXTRA_TRUST:-}
  EXEMPT_SERVICES=${EXEMPT_SERVICES:-}
  TORRC_PATHS=${TORRC_PATHS:-"/usr/local/etc/tor/torrc /usr/local/etc/tor/torrc.d/*.conf /etc/tor/torrc /etc/tor/torrc.d/*.conf"}
  PFCTL_CMD=${PFCTL_CMD:-pfctl}
  SOCKSTAT_CMD=${SOCKSTAT_CMD:-sockstat}
  CRONTAB_CMD=${CRONTAB_CMD:-crontab}
  IFCONFIG_CMD=${IFCONFIG_CMD:-ifconfig}
  RELEASE_BASE_URL=${RELEASE_BASE_URL:-https://github.com/MinorGlitch/orport-guard/releases/latest/download}
  DEFAULT_MAX_SRC_STATES=8
  DEFAULT_MAX_SRC_CONN=8
  DEFAULT_MAX_SRC_CONN_RATE_COUNT=9
  DEFAULT_MAX_SRC_CONN_RATE_WINDOW=60
  DEFAULT_BLOCK_EXPIRE_SECONDS=300

  MAX_SRC_STATES=${MAX_SRC_STATES:-$DEFAULT_MAX_SRC_STATES}
  MAX_SRC_CONN=${MAX_SRC_CONN:-$DEFAULT_MAX_SRC_CONN}
  MAX_SRC_CONN_RATE_COUNT=${MAX_SRC_CONN_RATE_COUNT:-$DEFAULT_MAX_SRC_CONN_RATE_COUNT}
  MAX_SRC_CONN_RATE_WINDOW=${MAX_SRC_CONN_RATE_WINDOW:-$DEFAULT_MAX_SRC_CONN_RATE_WINDOW}
  BLOCK_EXPIRE_SECONDS=${BLOCK_EXPIRE_SECONDS:-$DEFAULT_BLOCK_EXPIRE_SECONDS}
}

# Paths and naming

tor_ddos_finalize_paths() {
  TABLE_PREFIX=$(printf '%s' "$PF_ANCHOR" | tr -c 'A-Za-z0-9' '_' | sed 's/^_*//;s/_*$//')
  [ -n "$TABLE_PREFIX" ] || TABLE_PREFIX=orport_guard

  RENDER_FILE=${RENDER_FILE:-"$STATE_DIR/$TABLE_PREFIX-anchor.conf"}
  TARGETS_FILE=$STATE_DIR/targets.txt
  TRUST_V4_FILE=$STATE_DIR/trust-v4.txt
  TRUST_V6_FILE=$STATE_DIR/trust-v6.txt
  LAST_REFRESH_FILE=$STATE_DIR/last-refresh.stamp
  LAST_EXPIRE_FILE=$STATE_DIR/last-expire.stamp
  LAST_EXPIRE_FAILURE_FILE=$STATE_DIR/last-expire.failed
  LOADED_PROFILE_FILE=$STATE_DIR/loaded-profile.txt

  TRUST_V4_TABLE=${TABLE_PREFIX}_trust_v4
  TRUST_V6_TABLE=${TABLE_PREFIX}_trust_v6
  BLOCK_V4_TABLE=${TABLE_PREFIX}_block_v4
  BLOCK_V6_TABLE=${TABLE_PREFIX}_block_v6
}

# Logging and shell helpers

tor_ddos_log() {
  printf '%s\n' "$*" >&2
}

tor_ddos_die() {
  tor_ddos_log "error: $*"
  exit 1
}

tor_ddos_is_true() {
  case "${1:-0}" in
    1|yes|YES|true|TRUE|on|ON) return 0 ;;
  esac
  return 1
}

tor_ddos_trim_words() {
  printf '%s\n' "$*" | awk '{$1=$1; print}'
}

tor_ddos_require_directory() {
  [ -d "$1" ] || mkdir -p "$1"
}

tor_ddos_safe_source() {
  file=$1
  [ -f "$file" ] || return 0
  sh -n "$file" >/dev/null 2>&1 || tor_ddos_die "config syntax check failed: $file"
  # shellcheck source=/dev/null
  . "$file"
}

tor_ddos_load_config() {
  file=$1
  [ -z "$file" ] && return 0
  [ -f "$file" ] || return 0
  tor_ddos_safe_source "$file"
}

tor_ddos_targets_configured() {
  [ -n "$(tor_ddos_trim_words "$TARGETS")" ]
}

tor_ddos_profile_matches() {
  expected_states=$1
  expected_conn=$2
  expected_rate_count=$3
  expected_rate_window=$4

  [ "$MAX_SRC_STATES" = "$expected_states" ] &&
    [ "$MAX_SRC_CONN" = "$expected_conn" ] &&
    [ "$MAX_SRC_CONN_RATE_COUNT" = "$expected_rate_count" ] &&
    [ "$MAX_SRC_CONN_RATE_WINDOW" = "$expected_rate_window" ]
}

# Profile and config state

tor_ddos_apply_profile() {
  case "$PROFILE" in
    default|'')
      ;;
    aggressive)
      [ "$MAX_SRC_STATES" = "$DEFAULT_MAX_SRC_STATES" ] && MAX_SRC_STATES=4
      [ "$MAX_SRC_CONN" = "$DEFAULT_MAX_SRC_CONN" ] && MAX_SRC_CONN=4
      [ "$MAX_SRC_CONN_RATE_COUNT" = "$DEFAULT_MAX_SRC_CONN_RATE_COUNT" ] && MAX_SRC_CONN_RATE_COUNT=7
      [ "$MAX_SRC_CONN_RATE_WINDOW" = "$DEFAULT_MAX_SRC_CONN_RATE_WINDOW" ] && MAX_SRC_CONN_RATE_WINDOW=1
      ;;
    *)
      tor_ddos_die "invalid profile: $PROFILE"
      ;;
  esac

  case "$BLOCK_EXPIRE_SECONDS" in
    ''|*[!0-9]*)
      tor_ddos_die "BLOCK_EXPIRE_SECONDS must be a non-negative integer"
      ;;
  esac
}

tor_ddos_detect_effective_profile() {
  if tor_ddos_profile_matches 8 8 9 60; then
    printf 'default\n'
    return 0
  fi

  if tor_ddos_profile_matches 4 4 7 1; then
    printf 'aggressive\n'
    return 0
  fi

  printf 'custom\n'
}

tor_ddos_write_loaded_profile() {
  printf '%s\n' "$(tor_ddos_detect_effective_profile)" >"$LOADED_PROFILE_FILE"
}

tor_ddos_read_loaded_profile() {
  [ -f "$LOADED_PROFILE_FILE" ] || return 1
  profile=$(sed -n '1p' "$LOADED_PROFILE_FILE")
  case "$profile" in
    default|aggressive|custom)
      printf '%s\n' "$profile"
      ;;
    *)
      return 1
      ;;
  esac
}

# PF and privilege checks

tor_ddos_pfctl() {
  "$PFCTL_CMD" "$@"
}

tor_ddos_pfctl_anchor_table() {
  anchor=$1
  table=$2
  shift 2
  "$PFCTL_CMD" -a "$anchor" -t "$table" "$@"
}

tor_ddos_is_source_tree_invocation() {
  [ -f "$ROOT_DIR/lib/pf.sh" ] &&
    [ -f "$ROOT_DIR/bin/orport-guard" ] &&
    [ "$PROGRAM_PATH" = "$ROOT_DIR/bin/$PROGRAM_NAME" ]
}

tor_ddos_is_root() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ]
}

tor_ddos_privilege_helper() {
  if command -v doas >/dev/null 2>&1; then
    printf 'doas\n'
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    printf 'sudo\n'
    return 0
  fi
  return 1
}

tor_ddos_command_needs_privileges() {
  case "$1" in
    enable|check|apply|refresh|expire|status|install-hook|install-cron|remove-cron|disable)
      return 0
      ;;
  esac
  return 1
}

tor_ddos_reexec_with_privileges_if_needed() {
  command_name=$1
  quoted_argv=$2

  [ "${TOR_DDOS_BSD_ALLOW_UNSUPPORTED:-0}" = "1" ] && return 0
  tor_ddos_command_needs_privileges "$command_name" || return 0
  tor_ddos_is_root && return 0

  if [ "${TOR_DDOS_ALREADY_ESCALATED:-0}" = "1" ]; then
    tor_ddos_die "$command_name still lacks privileges after trying doas/sudo"
  fi

  helper=$(tor_ddos_privilege_helper) ||
    tor_ddos_die "$command_name needs privileged access; rerun with doas or sudo"

  tor_ddos_log "$command_name needs privileged access; re-running via $helper"
  eval "exec env TOR_DDOS_ALREADY_ESCALATED=1 $helper $(tor_ddos_shell_quote "$PROGRAM_PATH") $quoted_argv"
}

tor_ddos_program_path_writable() {
  [ -w "$PROGRAM_PATH" ] && return 0
  program_dir=$(dirname -- "$PROGRAM_PATH")
  [ -w "$program_dir" ]
}

tor_ddos_reexec_update_with_privileges_if_needed() {
  quoted_argv=$1

  [ "${TOR_DDOS_BSD_ALLOW_UNSUPPORTED:-0}" = "1" ] && return 0
  tor_ddos_program_path_writable && return 0
  tor_ddos_is_root && return 0

  if [ "${TOR_DDOS_ALREADY_ESCALATED:-0}" = "1" ]; then
    tor_ddos_die "update still cannot replace $PROGRAM_PATH after trying doas/sudo"
  fi

  helper=$(tor_ddos_privilege_helper) ||
    tor_ddos_die "update cannot replace $PROGRAM_PATH; rerun with doas or sudo"

  tor_ddos_log "update needs write access to $PROGRAM_PATH; re-running via $helper"
  eval "exec env TOR_DDOS_ALREADY_ESCALATED=1 $helper $(tor_ddos_shell_quote "$PROGRAM_PATH") $quoted_argv"
}

tor_ddos_pf_mutation_allowed() {
  if [ "${TOR_DDOS_BSD_ALLOW_UNSUPPORTED:-0}" = "1" ]; then
    return 0
  fi

  if [ "$(uname -s 2>/dev/null || echo unknown)" != "FreeBSD" ]; then
    tor_ddos_die "PF mutation commands are supported on FreeBSD only; set TOR_DDOS_BSD_ALLOW_UNSUPPORTED=1 for testing"
  fi

  if ! tor_ddos_is_root; then
    tor_ddos_die "PF mutation commands must run as root"
  fi
}

tor_ddos_require_pfctl() {
  command -v "$PFCTL_CMD" >/dev/null 2>&1 || tor_ddos_die "pfctl command not found: $PFCTL_CMD"
}

tor_ddos_require_crontab() {
  command -v "$CRONTAB_CMD" >/dev/null 2>&1 || tor_ddos_die "crontab command not found: $CRONTAB_CMD"
}

tor_ddos_require_root() {
  if ! tor_ddos_is_root; then
    tor_ddos_die "this command must run as root"
  fi
}

tor_ddos_download_file() {
  url=$1
  destination=$2

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" >"$destination"
    return 0
  fi

  if command -v fetch >/dev/null 2>&1; then
    fetch -qo "$destination" "$url"
    return 0
  fi

  tor_ddos_die "neither curl nor fetch is available to download $url"
}

tor_ddos_crontab_mutation_allowed() {
  [ "${TOR_DDOS_BSD_ALLOW_UNSUPPORTED:-0}" = "1" ] && return 0
  tor_ddos_require_root
}

# Time and status formatting

tor_ddos_now_epoch() {
  date +%s
}

tor_ddos_file_mtime_epoch() {
  file=$1
  [ -f "$file" ] || return 1

  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
    return 0
  fi

  if stat -c %Y "$file" >/dev/null 2>&1; then
    stat -c %Y "$file"
    return 0
  fi

  return 1
}

tor_ddos_age_since_epoch() {
  then_epoch=$1
  now=$(tor_ddos_now_epoch)

  if [ "$then_epoch" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' $((now - then_epoch))
  fi
}

tor_ddos_touch_file() {
  file=$1
  : >"$file"
}

tor_ddos_format_age() {
  seconds=${1:-0}
  if [ "$seconds" -lt 60 ]; then
    printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    printf '%sm' $((seconds / 60))
  elif [ "$seconds" -lt 86400 ]; then
    printf '%sh' $((seconds / 3600))
  else
    printf '%sd' $((seconds / 86400))
  fi
}

tor_ddos_format_last_run() {
  file=$1
  if mtime=$(tor_ddos_file_mtime_epoch "$file" 2>/dev/null); then
    age=$(tor_ddos_age_since_epoch "$mtime")
    printf '%s ago\n' "$(tor_ddos_format_age "$age")"
  else
    printf 'never\n'
  fi
}

tor_ddos_format_last_expire_run() {
  success_mtime=$(tor_ddos_file_mtime_epoch "$LAST_EXPIRE_FILE" 2>/dev/null || true)
  failure_mtime=$(tor_ddos_file_mtime_epoch "$LAST_EXPIRE_FAILURE_FILE" 2>/dev/null || true)

  if [ -n "$failure_mtime" ] && { [ -z "$success_mtime" ] || [ "$failure_mtime" -ge "$success_mtime" ]; }; then
    age=$(tor_ddos_age_since_epoch "$failure_mtime")
    printf 'failed %s ago\n' "$(tor_ddos_format_age "$age")"
    return 0
  fi

  tor_ddos_format_last_run "$LAST_EXPIRE_FILE"
}

tor_ddos_shell_quote() {
  value=$1
  case "$value" in
    '')
      printf "''"
      ;;
    *[!A-Za-z0-9_./:-]*)
      printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

tor_ddos_build_quoted_argv() {
  quoted=
  for arg in "$@"; do
    quoted="$quoted $(tor_ddos_shell_quote "$arg")"
  done
  printf '%s\n' "$(tor_ddos_trim_words "$quoted")"
}

tor_ddos_oldest_epoch() {
  oldest=

  for epoch in "$@"; do
    [ -n "$epoch" ] || continue
    if [ -z "$oldest" ] || [ "$epoch" -lt "$oldest" ]; then
      oldest=$epoch
    fi
  done

  [ -n "$oldest" ] || return 1
  printf '%s\n' "$oldest"
}

tor_ddos_trust_age_seconds() {
  mtime_v4=
  mtime_v6=

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    mtime_v4=$(tor_ddos_file_mtime_epoch "$TRUST_V4_FILE" 2>/dev/null || true)
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    mtime_v6=$(tor_ddos_file_mtime_epoch "$TRUST_V6_FILE" 2>/dev/null || true)
  fi

  mtime=$(tor_ddos_oldest_epoch "$mtime_v4" "$mtime_v6") || return 1
  tor_ddos_age_since_epoch "$mtime"
}

tor_ddos_effective_config_path() {
  if [ -n "${CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CONFIG_FILE"
  else
    printf '%s\n' "$CONFIG_FILE_DEFAULT"
  fi
}

tor_ddos_append_cli_arg() {
  current_args=$1
  flag=$2
  value=${3:-}

  if [ -n "$value" ]; then
    printf '%s\n' "$(tor_ddos_trim_words "$current_args $flag $(tor_ddos_shell_quote "$value")")"
  else
    printf '%s\n' "$(tor_ddos_trim_words "$current_args $flag")"
  fi
}

# Cron helpers

tor_ddos_cli_cron_args() {
  args=
  effective_config=$(tor_ddos_effective_config_path)
  if [ -n "$effective_config" ] && [ "$effective_config" != "$CONFIG_FILE_DEFAULT" ]; then
    args=$(tor_ddos_append_cli_arg "$args" --config "$effective_config")
  fi
  if [ "$STATE_DIR" != "/var/db/orport-guard" ]; then
    args=$(tor_ddos_append_cli_arg "$args" --state-dir "$STATE_DIR")
  fi
  if [ "$PF_ANCHOR" != "orport-guard" ]; then
    args=$(tor_ddos_append_cli_arg "$args" --anchor "$PF_ANCHOR")
  fi
  if [ "$PROFILE" != "default" ]; then
    args=$(tor_ddos_append_cli_arg "$args" --profile "$PROFILE")
  fi
  if [ "$BLOCK_EXPIRE_SECONDS" != "$DEFAULT_BLOCK_EXPIRE_SECONDS" ]; then
    args=$(tor_ddos_append_cli_arg "$args" --block-expire-seconds "$BLOCK_EXPIRE_SECONDS")
  fi
  if tor_ddos_is_true "$ENABLE_IPV4" && ! tor_ddos_is_true "$ENABLE_IPV6"; then
    args=$(tor_ddos_append_cli_arg "$args" --ipv4-only)
  elif ! tor_ddos_is_true "$ENABLE_IPV4" && tor_ddos_is_true "$ENABLE_IPV6"; then
    args=$(tor_ddos_append_cli_arg "$args" --ipv6-only)
  fi
  printf '%s\n' "$args"
}

tor_ddos_cron_block() {
  common_args=$(tor_ddos_cli_cron_args)
  program=$(tor_ddos_shell_quote "$PROGRAM_PATH")
  if [ -n "$common_args" ]; then
    expire_cmd="$program $common_args expire"
    refresh_cmd="$program $common_args refresh"
  else
    expire_cmd="$program expire"
    refresh_cmd="$program refresh"
  fi

  cat <<EOF
# BEGIN orport-guard
* * * * * $expire_cmd >/dev/null 2>&1
17 */6 * * * $refresh_cmd >/dev/null 2>&1
# END orport-guard
EOF
}

tor_ddos_crontab_list() {
  if "$CRONTAB_CMD" -l 2>/dev/null; then
    return 0
  fi
  return 0
}

tor_ddos_crontab_strip_block() {
  awk '
    /^# BEGIN orport-guard$/ { skip = 1; next }
    /^# END orport-guard$/ { skip = 0; next }
    !skip { print }
  '
}

tor_ddos_cron_installed() {
  command -v "$CRONTAB_CMD" >/dev/null 2>&1 || return 1
  tor_ddos_crontab_list | grep -Fqx '# BEGIN orport-guard'
}

# Fetching and word-list helpers

tor_ddos_http_get() {
  url=$1

  if [ -n "${FETCH_CMD:-}" ]; then
    "$FETCH_CMD" "$url"
    return $?
  fi

  if command -v fetch >/dev/null 2>&1; then
    fetch -qo - "$url"
    return $?
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return $?
  fi

  tor_ddos_die "neither fetch nor curl is available"
}

tor_ddos_write_words_file() {
  file=$1
  shift
  {
    for item in "$@"; do
      [ -n "$item" ] && printf '%s\n' "$item"
    done
  } | awk 'NF { if (!seen[$0]++) print $0 }' >"$file"
}

tor_ddos_append_words_to_file() {
  file=$1
  shift
  for item in "$@"; do
    [ -n "$item" ] && printf '%s\n' "$item" >>"$file"
  done
}

tor_ddos_split_target() {
  target=$1
  case "$target" in
    \[*\]:*)
      addr=$(printf '%s' "$target" | sed 's/^\[\(.*\)\]:.*/\1/')
      port=$(printf '%s' "$target" | sed 's/^\[.*\]://')
      printf 'inet6|%s|%s\n' "$addr" "$port"
      ;;
    *.*:*)
      addr=${target%:*}
      port=${target##*:}
      printf 'inet|%s|%s\n' "$addr" "$port"
      ;;
    *)
      tor_ddos_die "invalid target: $target"
      ;;
  esac
}

tor_ddos_split_service() {
  tor_ddos_split_target "$1"
}

tor_ddos_split_trust() {
  item=$1
  case "$item" in
    *:*)
      printf 'inet6|%s\n' "$item"
      ;;
    *.*)
      printf 'inet|%s\n' "$item"
      ;;
    *)
      tor_ddos_die "invalid trust entry: $item"
      ;;
  esac
}
