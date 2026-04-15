pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

register_test() {
  TEST_CASES="$TEST_CASES $1"
  TEST_COUNT=$((TEST_COUNT + 1))
}

assert_contains() {
  file=$1
  pattern=$2
  description=$3
  grep -F -- "$pattern" "$file" >/dev/null 2>&1 || fail "$description"
}

assert_not_contains() {
  file=$1
  pattern=$2
  description=$3
  if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "$description"
  fi
}

assert_file_missing() {
  path=$1
  description=$2
  [ ! -e "$path" ] || fail "$description"
}

assert_file_exists() {
  path=$1
  description=$2
  [ -e "$path" ] || fail "$description"
}

run_cli() {
  PFCTL_LOG=$TEST_ROOT/pfctl.log \
  PFCTL_STATE_DIR=$TEST_ROOT/pfstate \
  PFCTL_HAS_HOOK=${PFCTL_HAS_HOOK:-1} \
  PFCTL_VVS_RULES_FIXTURE=${PFCTL_VVS_RULES_FIXTURE:-} \
  CRONTAB_FILE=$TEST_ROOT/crontab \
  SOCKSTAT_FIXTURE=${SOCKSTAT_FIXTURE:-} \
  IFCONFIG_FIXTURE=${IFCONFIG_FIXTURE:-} \
  TOR_DDOS_BSD_ALLOW_UNSUPPORTED=1 \
  PFCTL_CMD=pfctl \
  SOCKSTAT_CMD=sockstat \
  IFCONFIG_CMD=ifconfig \
  PATH="$STUB_DIR:$PATH" \
  "$CLI" "$@"
}
