#!/bin/sh

TOR_DDOS_LIB_DIR=${TOR_DDOS_LIB_DIR:-}
if [ -z "$TOR_DDOS_LIB_DIR" ]; then
  if [ -n "${ROOT_DIR:-}" ]; then
    TOR_DDOS_LIB_DIR=$ROOT_DIR/lib
  else
    TOR_DDOS_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
  fi
fi

. "$TOR_DDOS_LIB_DIR/core.sh"
. "$TOR_DDOS_LIB_DIR/discovery.sh"
. "$TOR_DDOS_LIB_DIR/hook.sh"
. "$TOR_DDOS_LIB_DIR/runtime.sh"
. "$TOR_DDOS_LIB_DIR/status.sh"
