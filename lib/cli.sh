tor_ddos_mark_option_used() {
  CLI_USED_OPTIONS="$CLI_USED_OPTIONS $1"
}

tor_ddos_option_used() {
  case " $CLI_USED_OPTIONS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

tor_ddos_allow_command_options() {
  command_name=$1
  shift
  allowed_options=" $* "

  for option_name in \
    config \
    state-dir \
    anchor \
    pf-conf \
    profile \
    block-expire-seconds \
    render-file \
    torrc \
    target \
    trust \
    service \
    ipv4-only \
    ipv6-only
  do
    if tor_ddos_option_used "$option_name"; then
      case "$allowed_options" in
        *" $option_name "*) ;;
        *)
          tor_ddos_die "option --$option_name is not supported for $command_name"
          ;;
      esac
    fi
  done
}

tor_ddos_validate_command_options() {
  case "$1" in
    enable|apply)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor pf-conf profile block-expire-seconds render-file \
        torrc target trust service ipv4-only ipv6-only
      ;;
    check|render)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor pf-conf profile block-expire-seconds render-file \
        torrc target trust service ipv4-only ipv6-only
      ;;
    refresh)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor block-expire-seconds trust ipv4-only ipv6-only
      ;;
    expire)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor block-expire-seconds
      ;;
    status)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor pf-conf
      ;;
    install-hook)
      tor_ddos_allow_command_options "$1" \
        config anchor pf-conf
      ;;
    install-cron)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor profile block-expire-seconds ipv4-only ipv6-only
      ;;
    remove-cron)
      tor_ddos_allow_command_options "$1"
      ;;
    update)
      tor_ddos_allow_command_options "$1"
      ;;
    disable)
      tor_ddos_allow_command_options "$1" \
        config state-dir anchor
      ;;
  esac
}
