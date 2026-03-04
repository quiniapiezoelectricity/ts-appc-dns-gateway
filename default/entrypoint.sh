#!/bin/sh
set -e

: "${PRIVATEIP_CIDR:=10.250.0.0/16}"
: "${TUN_IF:=gateway0}"

CONFIG="/etc/config/config.json"

die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

command -v xray >/dev/null 2>&1 || die "xray not found"
command -v ip   >/dev/null 2>&1 || die "ip not found"

[ -f "$CONFIG" ] || die "Config not found at $CONFIG — did appc-config complete successfully?"

xray -config "$CONFIG" &
PID="$!"
trap 'kill "$PID" 2>/dev/null || true' INT TERM EXIT

# Wait for TUN interface to appear (created by xray)
i=0
while [ "$i" -lt 12 ]; do
  ip link show "$TUN_IF" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || die "xray exited before TUN interface $TUN_IF appeared"
  i=$((i + 1))
  sleep 1
done
ip link show "$TUN_IF" >/dev/null 2>&1 || die "TUN interface $TUN_IF did not appear"

# Route each virtual IP CIDR into the TUN interface
REMAINING="$PRIVATEIP_CIDR"
while [ -n "$REMAINING" ]; do
  CIDR="${REMAINING%%,*}"
  [ "$REMAINING" = "$CIDR" ] && REMAINING="" || REMAINING="${REMAINING#*,}"
  case "${CIDR%/*}" in
    *:*) ip -6 route replace "$CIDR" dev "$TUN_IF" ;;
    *)   ip    route replace "$CIDR" dev "$TUN_IF" ;;
  esac
done

wait "$PID"
PID=""
trap - INT TERM EXIT
