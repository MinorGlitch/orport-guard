tor_ddos_pf_conf_hook_regex() {
  printf '^[[:space:]]*anchor[[:space:]]+"%s"([[:space:]]*#.*)?[[:space:]]*$\n' "$PF_ANCHOR"
}

tor_ddos_root_hook_present() {
  tor_ddos_pfctl -sr 2>/dev/null | grep -F "anchor \"$PF_ANCHOR\"" >/dev/null 2>&1
}

tor_ddos_pf_conf_has_hook() {
  hook_regex=$(tor_ddos_pf_conf_hook_regex)
  [ -f "$PF_CONF" ] || return 1
  grep -E "$hook_regex" "$PF_CONF" >/dev/null 2>&1
}

tor_ddos_pf_conf_hook_is_positioned() {
  hook_regex=$(tor_ddos_pf_conf_hook_regex)
  [ -f "$PF_CONF" ] || return 1
  awk -v hook_regex="$hook_regex" '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*anchor[[:space:]]+"/ {
      if ($0 ~ hook_regex) {
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
  hook_regex=$(tor_ddos_pf_conf_hook_regex)
  awk -v anchor="$PF_ANCHOR" -v hook_regex="$hook_regex" '
    BEGIN {
      hook = "anchor \"" anchor "\""
      inserted = 0
    }
    $0 ~ hook_regex { next }
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

  tmp_file=$(mktemp "${PF_CONF}.orport-guard.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
  cp -p "$PF_CONF" "$tmp_file"
  tor_ddos_rewrite_pf_conf_with_hook "$PF_CONF" "$tmp_file"
  mv "$tmp_file" "$PF_CONF"
  trap - EXIT HUP INT TERM

  tor_ddos_log "installed anchor \"$PF_ANCHOR\" before the first PF filter rule in $PF_CONF"
  tor_ddos_log "reload PF with: pfctl -nf $PF_CONF && pfctl -f $PF_CONF"
}
