#!/bin/sh

tor_ddos_set_defaults() {
  ROOT_DIR=${1:-$(pwd)}
  CONFIG_FILE_DEFAULT=${CONFIG_FILE_DEFAULT:-"$ROOT_DIR/etc/tor-anchor.conf"}
  STATE_DIR=${STATE_DIR:-/var/db/tor-anchor}
  PF_ANCHOR=${PF_ANCHOR:-tor-anchor}
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

tor_ddos_finalize_paths() {
  TABLE_PREFIX=$(printf '%s' "$PF_ANCHOR" | tr -c 'A-Za-z0-9' '_' | sed 's/^_*//;s/_*$//')
  [ -n "$TABLE_PREFIX" ] || TABLE_PREFIX=tor_anchor

  RENDER_FILE=${RENDER_FILE:-"$STATE_DIR/$TABLE_PREFIX-anchor.conf"}
  TARGETS_FILE=$STATE_DIR/targets.txt
  TRUST_V4_FILE=$STATE_DIR/trust-v4.txt
  TRUST_V6_FILE=$STATE_DIR/trust-v6.txt
  LAST_OUTPUT_FILE=$STATE_DIR/last-render.out

  TRUST_V4_TABLE=${TABLE_PREFIX}_trust_v4
  TRUST_V6_TABLE=${TABLE_PREFIX}_trust_v6
  BLOCK_V4_TABLE=${TABLE_PREFIX}_block_v4
  BLOCK_V6_TABLE=${TABLE_PREFIX}_block_v6
}

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

tor_ddos_pfctl() {
  "$PFCTL_CMD" "$@"
}

tor_ddos_pfctl_anchor_table() {
  anchor=$1
  table=$2
  shift 2
  "$PFCTL_CMD" -a "$anchor" -t "$table" "$@"
}

tor_ddos_pf_mutation_allowed() {
  if [ "${TOR_DDOS_BSD_ALLOW_UNSUPPORTED:-0}" = "1" ]; then
    return 0
  fi

  if [ "$(uname -s 2>/dev/null || echo unknown)" != "FreeBSD" ]; then
    tor_ddos_die "PF mutation commands are supported on FreeBSD only; set TOR_DDOS_BSD_ALLOW_UNSUPPORTED=1 for testing"
  fi

  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    tor_ddos_die "PF mutation commands must run as root"
  fi
}

tor_ddos_require_pfctl() {
  command -v "$PFCTL_CMD" >/dev/null 2>&1 || tor_ddos_die "pfctl command not found: $PFCTL_CMD"
}

tor_ddos_require_crontab() {
  command -v "$CRONTAB_CMD" >/dev/null 2>&1 || tor_ddos_die "crontab command not found: $CRONTAB_CMD"
}

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

tor_ddos_trust_age_seconds() {
  mtime_v4=
  mtime_v6=

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    mtime_v4=$(tor_ddos_file_mtime_epoch "$TRUST_V4_FILE" 2>/dev/null || true)
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    mtime_v6=$(tor_ddos_file_mtime_epoch "$TRUST_V6_FILE" 2>/dev/null || true)
  fi

  mtime=
  if [ -n "$mtime_v4" ] && [ -n "$mtime_v6" ]; then
    if [ "$mtime_v4" -le "$mtime_v6" ]; then
      mtime=$mtime_v4
    else
      mtime=$mtime_v6
    fi
  elif [ -n "$mtime_v4" ]; then
    mtime=$mtime_v4
  elif [ -n "$mtime_v6" ]; then
    mtime=$mtime_v6
  else
    return 1
  fi

  now=$(tor_ddos_now_epoch)
  if [ "$now" -lt "$mtime" ]; then
    printf '0\n'
  else
    printf '%s\n' $((now - mtime))
  fi
}

tor_ddos_effective_config_path() {
  if [ -n "${CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CONFIG_FILE"
  else
    printf '%s\n' "$CONFIG_FILE_DEFAULT"
  fi
}

tor_ddos_cli_common_args() {
  args=
  effective_config=$(tor_ddos_effective_config_path)
  if [ -n "$effective_config" ] && [ "$effective_config" != "$CONFIG_FILE_DEFAULT" ]; then
    args="$args --config $(tor_ddos_shell_quote "$effective_config")"
  fi
  if [ "$STATE_DIR" != "/var/db/tor-anchor" ]; then
    args="$args --state-dir $(tor_ddos_shell_quote "$STATE_DIR")"
  fi
  if [ "$PF_ANCHOR" != "tor-anchor" ]; then
    args="$args --anchor $(tor_ddos_shell_quote "$PF_ANCHOR")"
  fi
  if [ "$PF_CONF" != "/etc/pf.conf" ]; then
    args="$args --pf-conf $(tor_ddos_shell_quote "$PF_CONF")"
  fi
  if [ "$PROFILE" != "default" ]; then
    args="$args --profile $(tor_ddos_shell_quote "$PROFILE")"
  fi
  if [ "$BLOCK_EXPIRE_SECONDS" != "$DEFAULT_BLOCK_EXPIRE_SECONDS" ]; then
    args="$args --block-expire-seconds $(tor_ddos_shell_quote "$BLOCK_EXPIRE_SECONDS")"
  fi
  if tor_ddos_is_true "$ENABLE_IPV4" && ! tor_ddos_is_true "$ENABLE_IPV6"; then
    args="$args --ipv4-only"
  elif ! tor_ddos_is_true "$ENABLE_IPV4" && tor_ddos_is_true "$ENABLE_IPV6"; then
    args="$args --ipv6-only"
  fi
  printf '%s\n' "$(tor_ddos_trim_words "$args")"
}

tor_ddos_cron_block() {
  common_args=$(tor_ddos_cli_common_args)
  program=$(tor_ddos_shell_quote "$PROGRAM_PATH")
  if [ -n "$common_args" ]; then
    expire_cmd="$program $common_args expire"
    refresh_cmd="$program $common_args refresh"
  else
    expire_cmd="$program expire"
    refresh_cmd="$program refresh"
  fi

  cat <<EOF
# BEGIN tor-anchor
* * * * * $expire_cmd >/dev/null 2>&1
17 */6 * * * $refresh_cmd >/dev/null 2>&1
# END tor-anchor
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
    /^# BEGIN tor-anchor$/ { skip = 1; next }
    /^# END tor-anchor$/ { skip = 0; next }
    !skip { print }
  '
}

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

tor_ddos_parse_torrc_file() {
  file=$1
  awk '
    {
      sub(/#.*/, "", $0)
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 == "") next
      if ($1 == "Address" && NF >= 2) {
        address = $2
        next
      }
      if ($1 != "ORPort" || NF < 2) next
      if ($2 == "auto" || $2 == "NoListen") next
      value = $2
      if (value == "NoAdvertise") next
      if (value ~ /^\[[^]]+\]:[0-9]+$/) {
        sub(/^\[/, "", value)
        split(value, parts, /\]:/)
        print "inet6|" parts[1] "|" parts[2]
        next
      }
      if (value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) {
        split(value, parts, /:/)
        print "inet|" parts[1] "|" parts[2]
        next
      }
      if (value ~ /^[0-9]+$/) {
        if (address ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          print "inet|" address "|" value
        } else if (address ~ /:/) {
          print "inet6|" address "|" value
        } else {
          print "auto||" value
        }
      }
    }
  ' "$file"
}

tor_ddos_parse_socket_token() {
  token=$1
  port=${token##*:}
  addr=${token%:*}
  case "$addr" in
    \*|'')
      return 1
      ;;
    \[*\])
      addr=$(printf '%s' "$addr" | sed 's/^\[\(.*\)\]$/\1/')
      printf 'inet6|%s|%s\n' "$addr" "$port"
      ;;
    *:*)
      printf 'inet6|%s|%s\n' "$addr" "$port"
      ;;
    *.*)
      printf 'inet|%s|%s\n' "$addr" "$port"
      ;;
    *)
      return 1
      ;;
  esac
}

tor_ddos_discover_from_sockstat() {
  port=$1
  "$SOCKSTAT_CMD" -4 -6 -l -P tcp -p "$port" 2>/dev/null |
    awk '
      NR == 1 { next }
      {
        local = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "*:*") continue
          if ($i ~ /\]:[0-9]+$/ || $i ~ /:[0-9]+$/) {
            local = $i
          }
        }
        if (local != "") print local
      }
    ' |
    while IFS= read -r local_addr; do
      tor_ddos_parse_socket_token "$local_addr"
    done
}

tor_ddos_collect_targets() {
  targets_tmp=$1
  : >"$targets_tmp"

  if tor_ddos_targets_configured; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      tor_ddos_split_target "$target" >>"$targets_tmp"
    done <<EOF
$TARGETS
EOF

    awk -F'|' '
      NF == 3 {
        key = $1 "|" $2 "|" $3
        if (!seen[key]++) print key
      }
    ' "$targets_tmp" >"$targets_tmp.final"

    : >"$targets_tmp"
    while IFS='|' read -r family addr port; do
      [ -n "$family" ] || continue
      if [ "$family" = inet ] && ! tor_ddos_is_true "$ENABLE_IPV4"; then
        continue
      fi
      if [ "$family" = inet6 ] && ! tor_ddos_is_true "$ENABLE_IPV6"; then
        continue
      fi
      printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$targets_tmp"
    done <"$targets_tmp.final"
    return 0
  fi

  for file in $TORRC_PATHS; do
    [ -f "$file" ] || continue
    tor_ddos_parse_torrc_file "$file" >>"$targets_tmp"
  done

  unresolved_tmp=$targets_tmp.unresolved
  : >"$unresolved_tmp"
  unresolved_remaining_tmp=$targets_tmp.unresolved.remaining
  : >"$unresolved_remaining_tmp"
  resolved_tmp=$targets_tmp.resolved
  : >"$resolved_tmp"

  while IFS='|' read -r family addr port; do
    [ -n "$family" ] || continue
    if [ "$family" = auto ]; then
      printf '%s\n' "$port" >>"$unresolved_tmp"
    else
      printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$resolved_tmp"
    fi
  done <"$targets_tmp"

  sort -u "$unresolved_tmp" 2>/dev/null | while IFS= read -r port; do
    [ -n "$port" ] || continue
    if ! tor_ddos_discover_from_sockstat "$port" >>"$resolved_tmp"; then
      printf '%s\n' "$port" >>"$unresolved_remaining_tmp"
    fi
  done

  : >"$targets_tmp"
  cat "$resolved_tmp" >>"$targets_tmp"

  awk -F'|' '
    NF == 3 {
      key = $1 "|" $2 "|" $3
      if (!seen[key]++) print key
    }
  ' "$targets_tmp" >"$targets_tmp.final"

  : >"$targets_tmp"
  while IFS='|' read -r family addr port; do
    [ -n "$family" ] || continue
    if [ "$family" = inet ] && ! tor_ddos_is_true "$ENABLE_IPV4"; then
      continue
    fi
    if [ "$family" = inet6 ] && ! tor_ddos_is_true "$ENABLE_IPV6"; then
      continue
    fi
    printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$targets_tmp"
  done <"$targets_tmp.final"

  if [ ! -s "$targets_tmp" ] && [ -s "$unresolved_remaining_tmp" ]; then
    ports=$(tr '\n' ' ' <"$unresolved_remaining_tmp" | awk '{$1=$1; print}')
    tor_ddos_die "could not resolve wildcard ORPort listener(s): $ports; set explicit TARGETS or pass --target"
  fi
}

tor_ddos_fetch_trust_lists() {
  tor_ddos_require_directory "$STATE_DIR"
  : >"$TRUST_V4_FILE"
  : >"$TRUST_V6_FILE"

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_http_get "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/authorities-v4.txt" | sed '1,3d' >>"$TRUST_V4_FILE"
    tor_ddos_http_get "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/snowflake.txt" | sed '1,3d' >>"$TRUST_V4_FILE"
  fi

  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_http_get "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/authorities-v6.txt" | sed '1,3d' >>"$TRUST_V6_FILE"
    tor_ddos_http_get "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/snowflake-v6.txt" | sed '1,3d' >>"$TRUST_V6_FILE"
  fi

  for item in $EXTRA_TRUST; do
    tor_ddos_split_trust "$item" | while IFS='|' read -r family value; do
      if [ "$family" = inet ] && tor_ddos_is_true "$ENABLE_IPV4"; then
        printf '%s\n' "$value" >>"$TRUST_V4_FILE"
      fi
      if [ "$family" = inet6 ] && tor_ddos_is_true "$ENABLE_IPV6"; then
        printf '%s\n' "$value" >>"$TRUST_V6_FILE"
      fi
    done
  done

  awk 'NF { if (!seen[$0]++) print $0 }' "$TRUST_V4_FILE" >"$TRUST_V4_FILE.tmp"
  mv "$TRUST_V4_FILE.tmp" "$TRUST_V4_FILE"
  awk 'NF { if (!seen[$0]++) print $0 }' "$TRUST_V6_FILE" >"$TRUST_V6_FILE.tmp"
  mv "$TRUST_V6_FILE.tmp" "$TRUST_V6_FILE"
}

tor_ddos_write_targets_state() {
  source_file=$1
  cp "$source_file" "$TARGETS_FILE"
}

tor_ddos_render_anchor_file() {
  targets_file=$1
  output_file=$2

  tor_ddos_require_directory "$STATE_DIR"

  {
    printf '# Generated by tor-anchor\n'
    printf '# Main pf.conf must contain: anchor "%s"\n\n' "$PF_ANCHOR"
    printf 'table <%s> persist file "%s"\n' "$TRUST_V4_TABLE" "$TRUST_V4_FILE"
    printf 'table <%s> persist file "%s"\n' "$TRUST_V6_TABLE" "$TRUST_V6_FILE"
    printf 'table <%s> persist\n' "$BLOCK_V4_TABLE"
    printf 'table <%s> persist\n\n' "$BLOCK_V6_TABLE"

    for service in $EXEMPT_SERVICES; do
      tor_ddos_split_service "$service" | while IFS='|' read -r family addr port; do
        printf 'pass in quick %s proto tcp from any to %s port %s label "tor-anchor exempt %s:%s"\n' "$family" "$addr" "$port" "$addr" "$port"
      done
    done

    [ -n "$EXEMPT_SERVICES" ] && printf '\n'

    while IFS='|' read -r family addr port; do
      [ -n "$family" ] || continue
      if [ "$family" = inet ]; then
        trust_table=$TRUST_V4_TABLE
        block_table=$BLOCK_V4_TABLE
      else
        trust_table=$TRUST_V6_TABLE
        block_table=$BLOCK_V6_TABLE
      fi

      printf 'block in quick %s proto tcp from <%s> to %s port %s label "tor-anchor block %s:%s"\n' "$family" "$block_table" "$addr" "$port" "$addr" "$port"
      printf 'pass in quick %s proto tcp from <%s> to %s port %s flags S/SA keep state label "tor-anchor trust %s:%s"\n' "$family" "$trust_table" "$addr" "$port" "$addr" "$port"
      printf 'pass in quick %s proto tcp from any to %s port %s flags S/SA keep state (source-track rule, max-src-states %s, max-src-conn %s, max-src-conn-rate %s/%s, overload <%s> flush global) label "tor-anchor protect %s:%s"\n' \
        "$family" "$addr" "$port" "$MAX_SRC_STATES" "$MAX_SRC_CONN" "$MAX_SRC_CONN_RATE_COUNT" "$MAX_SRC_CONN_RATE_WINDOW" "$block_table" "$addr" "$port"
      printf '\n'
    done <"$targets_file"
  } >"$output_file"
}

tor_ddos_root_hook_present() {
  tor_ddos_pfctl -sr 2>/dev/null | grep -F "anchor \"$PF_ANCHOR\"" >/dev/null 2>&1
}

tor_ddos_pf_conf_has_hook() {
  [ -f "$PF_CONF" ] || return 1
  grep -E '^[[:space:]]*anchor[[:space:]]+"'"$PF_ANCHOR"'"([[:space:]]*#.*)?[[:space:]]*$' "$PF_CONF" >/dev/null 2>&1
}

tor_ddos_pf_conf_filter_line() {
  file=$1
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*(block|pass|match|anchor)[[:space:]]/ { print NR; exit }
  ' "$file"
}

tor_ddos_pf_conf_hook_is_positioned() {
  [ -f "$PF_CONF" ] || return 1
  awk -v anchor="$PF_ANCHOR" '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*anchor[[:space:]]+"/ {
      if ($0 ~ "^[[:space:]]*anchor[[:space:]]+\"" anchor "\"([[:space:]]*#.*)?[[:space:]]*$") {
        print "hook"
        exit
      }
      next
    }
    /^[[:space:]]*(block|pass|match|anchor)[[:space:]]/ {
      print "filter"
      exit
    }
  ' "$PF_CONF" | grep -qx 'hook'
}

tor_ddos_rewrite_pf_conf_with_hook() {
  src=$1
  dst=$2
  awk -v anchor="$PF_ANCHOR" '
    BEGIN {
      hook = "anchor \"" anchor "\""
      inserted = 0
    }
    $0 ~ "^[[:space:]]*anchor[[:space:]]+\"" anchor "\"([[:space:]]*#.*)?[[:space:]]*$" { next }
    !inserted && $0 ~ /^[[:space:]]*(block|pass|match|anchor)[[:space:]]/ {
      print hook
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        if (NR > 0) {
          print ""
        }
        print hook
      }
    }
  ' "$src" >"$dst"
}

tor_ddos_install_hook() {
  tor_ddos_pf_mutation_allowed

  [ -f "$PF_CONF" ] || tor_ddos_die "PF config file not found: $PF_CONF"

  if tor_ddos_pf_conf_hook_is_positioned; then
    tor_ddos_log "PF config already contains anchor \"$PF_ANCHOR\" in a pre-filter position in $PF_CONF"
    return 0
  fi

  tmp_file=$PF_CONF.tor-anchor.$$
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
  tor_ddos_rewrite_pf_conf_with_hook "$PF_CONF" "$tmp_file"
  mv "$tmp_file" "$PF_CONF"
  trap - EXIT HUP INT TERM

  tor_ddos_log "installed anchor \"$PF_ANCHOR\" before the first PF filter rule in $PF_CONF"
  tor_ddos_log "reload PF with: pfctl -nf $PF_CONF && pfctl -f $PF_CONF"
}

tor_ddos_apply_tables() {
  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$TRUST_V4_TABLE" -T replace -f "$TRUST_V4_FILE" >/dev/null
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$TRUST_V6_TABLE" -T replace -f "$TRUST_V6_FILE" >/dev/null
  fi
}

tor_ddos_cleanup_legacy_global_tables() {
  tor_ddos_pfctl -t "$TRUST_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$TRUST_V6_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V6_TABLE" -T kill >/dev/null 2>&1 || true
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

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V4_TABLE" -T expire "$BLOCK_EXPIRE_SECONDS" >/dev/null 2>&1 || true
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$BLOCK_V6_TABLE" -T expire "$BLOCK_EXPIRE_SECONDS" >/dev/null 2>&1 || true
  fi
}

tor_ddos_check() {
  tor_ddos_require_pfctl
  tor_ddos_prepare_anchor
  tor_ddos_check_anchor_syntax
  if tor_ddos_pf_conf_has_hook; then
    tor_ddos_validate_pf_conf
    tor_ddos_log "PF syntax OK for anchor $PF_ANCHOR and $PF_CONF"
  else
    tor_ddos_log "PF syntax OK for anchor $PF_ANCHOR"
    tor_ddos_log "PF config does not contain anchor \"$PF_ANCHOR\" in $PF_CONF yet"
  fi
}

tor_ddos_expire() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_expire_block_tables_now
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
  tor_ddos_apply_tables
  tor_ddos_expire_block_tables_now
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
    tor_ddos_die "PF root rules do not contain anchor \"$PF_ANCHOR\"; run $0 install-hook or add that hook to $PF_CONF before apply"
  fi

  tor_ddos_pfctl -a "$PF_ANCHOR" -f "$RENDER_FILE" >/dev/null
  tor_ddos_apply_tables
  tor_ddos_expire_block_tables_now
  tor_ddos_log "loaded PF anchor $PF_ANCHOR from $RENDER_FILE"
}

tor_ddos_refresh() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_cleanup_legacy_global_tables
  tor_ddos_require_directory "$STATE_DIR"
  tor_ddos_fetch_trust_lists
  tor_ddos_apply_tables
  tor_ddos_expire_block_tables_now
  tor_ddos_log "refreshed trust tables for $PF_ANCHOR"
}

tor_ddos_install_cron() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_crontab

  tmp_file=$(mktemp "${TMPDIR:-/tmp}/tor-anchor-cron.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
  existing=$(tor_ddos_crontab_list | tor_ddos_crontab_strip_block)

  {
    if [ -n "$existing" ]; then
      printf '%s\n\n' "$existing"
    fi
    tor_ddos_cron_block
  } >"$tmp_file"

  "$CRONTAB_CMD" "$tmp_file"
  trap - EXIT HUP INT TERM
  rm -f "$tmp_file"

  tor_ddos_log "installed managed cron entries for $PF_ANCHOR"
}

tor_ddos_remove_cron() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_crontab

  tmp_file=$(mktemp "${TMPDIR:-/tmp}/tor-anchor-cron.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

  tor_ddos_crontab_list | tor_ddos_crontab_strip_block >"$tmp_file"
  "$CRONTAB_CMD" "$tmp_file"
  trap - EXIT HUP INT TERM
  rm -f "$tmp_file"

  tor_ddos_log "removed managed cron entries for $PF_ANCHOR"
}

tor_ddos_render() {
  tor_ddos_prepare_anchor
  cat "$RENDER_FILE"
}

tor_ddos_status_table_count() {
  table_name=$1
  if command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    tor_ddos_pfctl_anchor_table "$PF_ANCHOR" "$table_name" -T show 2>/dev/null | awk 'NF { n++ } END { print n + 0 }'
  else
    printf '0\n'
  fi
}

tor_ddos_status_anchor_loaded() {
  if ! command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    printf 'no (pfctl unavailable)\n'
    return 0
  fi

  if tor_ddos_pfctl -a "$PF_ANCHOR" -sr >/dev/null 2>&1; then
    if [ -n "$(tor_ddos_pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)" ]; then
      printf 'yes\n'
    else
      printf 'no\n'
    fi
  else
    printf 'no\n'
  fi
}

tor_ddos_status() {
  tor_ddos_finalize_paths
  printf 'Anchor: %s\n' "$PF_ANCHOR"
  printf 'State dir: %s\n' "$STATE_DIR"
  printf 'Rendered anchor: %s\n' "$RENDER_FILE"
  printf 'PF config: %s\n' "$PF_CONF"
  printf 'Profile: %s\n' "$PROFILE"
  if [ "$BLOCK_EXPIRE_SECONDS" -gt 0 ]; then
    printf 'Block expiry: %ss (lazy, on next enable/apply/refresh)\n' "$BLOCK_EXPIRE_SECONDS"
  else
    printf 'Block expiry: disabled\n'
  fi
  printf 'PF config hook: '
  if tor_ddos_pf_conf_has_hook; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'Root hook present: '
  if command -v "$PFCTL_CMD" >/dev/null 2>&1 && tor_ddos_root_hook_present; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'Anchor loaded: %s' "$(tor_ddos_status_anchor_loaded)"
  printf 'Trust table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$TRUST_V4_TABLE")" "$(tor_ddos_status_table_count "$TRUST_V6_TABLE")"
  printf 'Block table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$BLOCK_V4_TABLE")" "$(tor_ddos_status_table_count "$BLOCK_V6_TABLE")"
  if trust_age=$(tor_ddos_trust_age_seconds 2>/dev/null); then
    printf 'Trust data age: %s\n' "$(tor_ddos_format_age "$trust_age")"
    if [ "$trust_age" -gt 604800 ]; then
      printf 'Trust data status: stale (run tor-anchor refresh)\n'
    else
      printf 'Trust data status: fresh enough\n'
    fi
  else
    printf 'Trust data age: unknown (run tor-anchor refresh)\n'
  fi
  printf '\nProtected targets:\n'
  if [ -s "$TARGETS_FILE" ]; then
    while IFS='|' read -r family addr port; do
      [ -n "$family" ] || continue
      printf '  - %s %s:%s\n' "$family" "$addr" "$port"
    done <"$TARGETS_FILE"
  else
    printf '  (none)\n'
  fi

  if command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    printf '\nAnchor rules:\n'
    tor_ddos_pfctl -a "$PF_ANCHOR" -vvs rules 2>/dev/null || true
  fi

  anchor_loaded=$(tor_ddos_status_anchor_loaded)

  printf '\nSuggested command: '
  if ! tor_ddos_pf_conf_has_hook; then
    printf 'tor-anchor enable\n'
  elif ! tor_ddos_root_hook_present; then
    printf 'pfctl -nf %s && pfctl -f %s\n' "$PF_CONF" "$PF_CONF"
  elif [ "$anchor_loaded" = "yes" ]; then
    printf 'tor-anchor refresh\n'
  else
    printf 'tor-anchor apply\n'
  fi
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
  tor_ddos_log "disabled PF anchor $PF_ANCHOR"
}
