#!/bin/sh

tor_ddos_set_defaults() {
  ROOT_DIR=${1:-$(pwd)}
  CONFIG_FILE_DEFAULT=${CONFIG_FILE_DEFAULT:-"$ROOT_DIR/etc/tor-anchor.conf"}
  STATE_DIR=${STATE_DIR:-/var/db/tor-anchor}
  PF_ANCHOR=${PF_ANCHOR:-tor-anchor}
  ENABLE_IPV4=${ENABLE_IPV4:-1}
  ENABLE_IPV6=${ENABLE_IPV6:-1}
  TARGETS=${TARGETS:-}
  EXTRA_TRUST=${EXTRA_TRUST:-}
  EXEMPT_SERVICES=${EXEMPT_SERVICES:-}
  TORRC_PATHS=${TORRC_PATHS:-"/usr/local/etc/tor/torrc /usr/local/etc/tor/torrc.d/*.conf /etc/tor/torrc /etc/tor/torrc.d/*.conf"}
  PFCTL_CMD=${PFCTL_CMD:-pfctl}
  SOCKSTAT_CMD=${SOCKSTAT_CMD:-sockstat}
  MAX_SRC_STATES=${MAX_SRC_STATES:-8}
  MAX_SRC_CONN=${MAX_SRC_CONN:-8}
  MAX_SRC_CONN_RATE_COUNT=${MAX_SRC_CONN_RATE_COUNT:-9}
  MAX_SRC_CONN_RATE_WINDOW=${MAX_SRC_CONN_RATE_WINDOW:-60}
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

tor_ddos_pfctl() {
  "$PFCTL_CMD" "$@"
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
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    tor_ddos_split_target "$target" >>"$targets_tmp"
  done <<EOF
$TARGETS
EOF

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

tor_ddos_apply_tables() {
  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_pfctl -t "$TRUST_V4_TABLE" -T replace -f "$TRUST_V4_FILE" >/dev/null
  fi
  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_pfctl -t "$TRUST_V6_TABLE" -T replace -f "$TRUST_V6_FILE" >/dev/null
  fi
}

tor_ddos_apply() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_require_directory "$STATE_DIR"

  targets_tmp=$STATE_DIR/targets.tmp
  tor_ddos_collect_targets "$targets_tmp"
  if [ ! -s "$targets_tmp" ]; then
    tor_ddos_die "no protected targets were discovered or configured; use --target or set TARGETS"
  fi

  tor_ddos_fetch_trust_lists
  tor_ddos_write_targets_state "$targets_tmp"
  tor_ddos_render_anchor_file "$targets_tmp" "$RENDER_FILE"

  if ! tor_ddos_root_hook_present; then
    tor_ddos_die "PF root rules do not contain anchor \"$PF_ANCHOR\"; add that hook to pf.conf before apply"
  fi

  tor_ddos_pfctl -a "$PF_ANCHOR" -f "$RENDER_FILE" >/dev/null
  tor_ddos_apply_tables
  tor_ddos_log "loaded PF anchor $PF_ANCHOR from $RENDER_FILE"
}

tor_ddos_refresh() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl
  tor_ddos_require_directory "$STATE_DIR"
  tor_ddos_fetch_trust_lists
  tor_ddos_apply_tables
  tor_ddos_log "refreshed trust tables for $PF_ANCHOR"
}

tor_ddos_render() {
  tor_ddos_require_directory "$STATE_DIR"
  targets_tmp=$STATE_DIR/targets.tmp
  tor_ddos_collect_targets "$targets_tmp"
  tor_ddos_fetch_trust_lists
  tor_ddos_write_targets_state "$targets_tmp"
  tor_ddos_render_anchor_file "$targets_tmp" "$RENDER_FILE"
  cat "$RENDER_FILE"
}

tor_ddos_status_table_count() {
  table_name=$1
  if command -v "$PFCTL_CMD" >/dev/null 2>&1; then
    tor_ddos_pfctl -t "$table_name" -T show 2>/dev/null | awk 'NF { n++ } END { print n + 0 }'
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
  printf 'Root hook present: '
  if command -v "$PFCTL_CMD" >/dev/null 2>&1 && tor_ddos_root_hook_present; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'Anchor loaded: %s' "$(tor_ddos_status_anchor_loaded)"
  printf 'Trust table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$TRUST_V4_TABLE")" "$(tor_ddos_status_table_count "$TRUST_V6_TABLE")"
  printf 'Block table counts: IPv4=%s IPv6=%s\n' "$(tor_ddos_status_table_count "$BLOCK_V4_TABLE")" "$(tor_ddos_status_table_count "$BLOCK_V6_TABLE")"
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
}

tor_ddos_disable() {
  tor_ddos_pf_mutation_allowed
  tor_ddos_require_pfctl

  tor_ddos_pfctl -a "$PF_ANCHOR" -f /dev/null >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$TRUST_V4_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$TRUST_V6_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V4_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V6_TABLE" -T kill >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V4_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_pfctl -t "$BLOCK_V6_TABLE" -T flush >/dev/null 2>&1 || true
  tor_ddos_log "disabled PF anchor $PF_ANCHOR"
}
