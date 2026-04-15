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

tor_ddos_pick_single_line() {
  awk '
    NF {
      count++
      if (count == 1) first = $0
    }
    END {
      if (count == 1) {
        print first
      } else {
        exit 1
      }
    }
  '
}

tor_ddos_local_interface_addresses() {
  family=$1
  command -v "$IFCONFIG_CMD" >/dev/null 2>&1 || return 1

  "$IFCONFIG_CMD" 2>/dev/null |
    awk -v want="$family" '
      /^[^[:space:]].*:$/ {
        iface = $1
        sub(/:$/, "", iface)
        next
      }
      want == "inet" && $1 == "inet" {
        addr = $2
        if (iface ~ /^lo[0-9]*$/ || addr ~ /^127\./) next
        print addr
      }
      want == "inet6" && $1 == "inet6" {
        addr = $2
        sub(/%.*$/, "", addr)
        if (iface ~ /^lo[0-9]*$/ || addr == "::1" || addr ~ /^fe80:/) next
        print addr
      }
    ' |
    awk 'NF { if (!seen[$0]++) print $0 }'
}

tor_ddos_is_local_address() {
  family=$1
  addr=$2
  tor_ddos_local_interface_addresses "$family" 2>/dev/null | grep -Fx -- "$addr" >/dev/null 2>&1
}

tor_ddos_sockstat_target_addresses() {
  family=$1
  port=$2
  tor_ddos_discover_from_sockstat "$port" 2>/dev/null |
    awk -F'|' -v want="$family" '$1 == want && NF == 3 { print $2 }' |
    awk 'NF { if (!seen[$0]++) print $0 }'
}

tor_ddos_local_target_candidates() {
  family=$1
  port=$2
  {
    tor_ddos_sockstat_target_addresses "$family" "$port" 2>/dev/null || true
    tor_ddos_local_interface_addresses "$family" 2>/dev/null || true
  } | awk 'NF { if (!seen[$0]++) print $0 }'
}

tor_ddos_pf_visible_address_for_target() {
  family=$1
  port=$2

  if candidate=$(tor_ddos_sockstat_target_addresses "$family" "$port" | tor_ddos_pick_single_line 2>/dev/null); then
    printf '%s\n' "$candidate"
    return 0
  fi

  if candidate=$(tor_ddos_local_interface_addresses "$family" | tor_ddos_pick_single_line 2>/dev/null); then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

tor_ddos_discover_from_local_interfaces() {
  port=$1
  found=0

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    if addr=$(tor_ddos_local_interface_addresses inet | tor_ddos_pick_single_line 2>/dev/null); then
      printf 'inet|%s|%s\n' "$addr" "$port"
      found=1
    fi
  fi

  if tor_ddos_is_true "$ENABLE_IPV6"; then
    if addr=$(tor_ddos_local_interface_addresses inet6 | tor_ddos_pick_single_line 2>/dev/null); then
      printf 'inet6|%s|%s\n' "$addr" "$port"
      found=1
    fi
  fi

  [ "$found" -eq 1 ]
}

tor_ddos_canonicalize_targets() {
  input_file=$1
  output_file=$2
  : >"$output_file"

  while IFS='|' read -r family addr port; do
    [ -n "$family" ] || continue

    if tor_ddos_is_local_address "$family" "$addr"; then
      printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$output_file"
      continue
    fi

    if candidate=$(tor_ddos_pf_visible_address_for_target "$family" "$port" 2>/dev/null); then
      if [ "$candidate" != "$addr" ]; then
        tor_ddos_log "notice: target $addr:$port is not PF-visible on this host; using local address $candidate:$port"
      fi
      printf '%s|%s|%s\n' "$family" "$candidate" "$port" >>"$output_file"
      continue
    fi

    candidates=$(tor_ddos_local_target_candidates "$family" "$port" 2>/dev/null | tr '\n' ' ' | awk '{$1=$1; print}')
    if [ -n "$candidates" ]; then
      tor_ddos_die "target $addr:$port is not a local $family address PF will see; candidate local addresses: $candidates"
    fi

    printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$output_file"
  done <"$input_file"
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

    : >"$targets_tmp.filtered"
    while IFS='|' read -r family addr port; do
      [ -n "$family" ] || continue
      if [ "$family" = inet ] && ! tor_ddos_is_true "$ENABLE_IPV4"; then
        continue
      fi
      if [ "$family" = inet6 ] && ! tor_ddos_is_true "$ENABLE_IPV6"; then
        continue
      fi
      printf '%s|%s|%s\n' "$family" "$addr" "$port" >>"$targets_tmp.filtered"
    done <"$targets_tmp.final"
    tor_ddos_canonicalize_targets "$targets_tmp.filtered" "$targets_tmp"
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
      if ! tor_ddos_discover_from_local_interfaces "$port" >>"$resolved_tmp"; then
        printf '%s\n' "$port" >>"$unresolved_remaining_tmp"
      fi
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

  tor_ddos_canonicalize_targets "$targets_tmp.final" "$targets_tmp"

  if [ ! -s "$targets_tmp" ] && [ -s "$unresolved_remaining_tmp" ]; then
    ports=$(tr '\n' ' ' <"$unresolved_remaining_tmp" | awk '{$1=$1; print}')
    tor_ddos_die "could not resolve wildcard ORPort listener(s): $ports; set explicit TARGETS or pass --target"
  fi
}

tor_ddos_fetch_trust_source() {
  url=$1
  output_file=$2
  fetched_file=$(mktemp "${TMPDIR:-/tmp}/orport-guard-fetch.XXXXXX")

  if ! tor_ddos_http_get "$url" >"$fetched_file"; then
    rm -f "$fetched_file"
    return 1
  fi

  sed '1,3d' "$fetched_file" >>"$output_file"
  rm -f "$fetched_file"
}

tor_ddos_finalize_trust_file() {
  source_file=$1
  output_file=$2
  deduped_file=$source_file.dedup

  awk 'NF { if (!seen[$0]++) print $0 }' "$source_file" >"$deduped_file"
  mv "$deduped_file" "$output_file"
}

tor_ddos_fetch_trust_lists() {
  tor_ddos_require_directory "$STATE_DIR"
  trust_v4_tmp=$(mktemp "${TMPDIR:-/tmp}/orport-guard-trust-v4.XXXXXX")
  trust_v6_tmp=$(mktemp "${TMPDIR:-/tmp}/orport-guard-trust-v6.XXXXXX")
  trap 'rm -f "$trust_v4_tmp" "$trust_v6_tmp" "$trust_v4_tmp.dedup" "$trust_v6_tmp.dedup"' EXIT HUP INT TERM
  : >"$trust_v4_tmp"
  : >"$trust_v6_tmp"

  if tor_ddos_is_true "$ENABLE_IPV4"; then
    tor_ddos_fetch_trust_source "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/authorities-v4.txt" "$trust_v4_tmp" ||
      tor_ddos_die "failed to fetch IPv4 trust list: authorities-v4.txt"
    tor_ddos_fetch_trust_source "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/snowflake.txt" "$trust_v4_tmp" ||
      tor_ddos_die "failed to fetch IPv4 trust list: snowflake.txt"
  fi

  if tor_ddos_is_true "$ENABLE_IPV6"; then
    tor_ddos_fetch_trust_source "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/authorities-v6.txt" "$trust_v6_tmp" ||
      tor_ddos_die "failed to fetch IPv6 trust list: authorities-v6.txt"
    tor_ddos_fetch_trust_source "https://raw.githubusercontent.com/Enkidu-6/tor-relay-lists/main/snowflake-v6.txt" "$trust_v6_tmp" ||
      tor_ddos_die "failed to fetch IPv6 trust list: snowflake-v6.txt"
  fi

  for item in $EXTRA_TRUST; do
    tor_ddos_split_trust "$item" | while IFS='|' read -r family value; do
      if [ "$family" = inet ] && tor_ddos_is_true "$ENABLE_IPV4"; then
        printf '%s\n' "$value" >>"$trust_v4_tmp"
      fi
      if [ "$family" = inet6 ] && tor_ddos_is_true "$ENABLE_IPV6"; then
        printf '%s\n' "$value" >>"$trust_v6_tmp"
      fi
    done
  done

  tor_ddos_finalize_trust_file "$trust_v4_tmp" "$TRUST_V4_FILE"
  tor_ddos_finalize_trust_file "$trust_v6_tmp" "$TRUST_V6_FILE"
  trap - EXIT HUP INT TERM
  rm -f "$trust_v4_tmp" "$trust_v6_tmp"
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
    printf '# Generated by orport-guard\n'
    printf '# Main pf.conf must contain: anchor "%s"\n\n' "$PF_ANCHOR"
    printf 'table <%s> persist file "%s"\n' "$TRUST_V4_TABLE" "$TRUST_V4_FILE"
    printf 'table <%s> persist file "%s"\n' "$TRUST_V6_TABLE" "$TRUST_V6_FILE"
    printf 'table <%s> persist\n' "$BLOCK_V4_TABLE"
    printf 'table <%s> persist\n\n' "$BLOCK_V6_TABLE"

    for service in $EXEMPT_SERVICES; do
      tor_ddos_split_service "$service" | while IFS='|' read -r family addr port; do
        printf 'pass in quick %s proto tcp from any to %s port %s label "orport-guard exempt %s:%s"\n' "$family" "$addr" "$port" "$addr" "$port"
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

      printf 'block in quick %s proto tcp from <%s> to %s port %s label "orport-guard block %s:%s"\n' "$family" "$block_table" "$addr" "$port" "$addr" "$port"
      printf 'pass in quick %s proto tcp from <%s> to %s port %s flags S/SA keep state label "orport-guard trust %s:%s"\n' "$family" "$trust_table" "$addr" "$port" "$addr" "$port"
      printf 'pass in quick %s proto tcp from any to %s port %s flags S/SA keep state (source-track rule, max-src-states %s, max-src-conn %s, max-src-conn-rate %s/%s, overload <%s> flush global) label "orport-guard protect %s:%s"\n' \
        "$family" "$addr" "$port" "$MAX_SRC_STATES" "$MAX_SRC_CONN" "$MAX_SRC_CONN_RATE_COUNT" "$MAX_SRC_CONN_RATE_WINDOW" "$block_table" "$addr" "$port"
      printf '\n'
    done <"$targets_file"
  } >"$output_file"
}
