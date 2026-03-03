#!/bin/sh
set -e

: "${PRIVATEIP_CIDR:=10.250.0.0/16}"
: "${TUN_IF:=gateway0}"

TEMPLATE="/etc/template/config.template.json"
CONFIG="/etc/config/config.json"

# ---------- helpers ----------
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup() {
  if [ -n "${PID:-}" ] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
  fi
}

require_cmd sed
require_cmd xray
require_cmd ip

# Parse CIDR components
PREFIX="${PRIVATEIP_CIDR#*/}"
[ "$PREFIX" != "$PRIVATEIP_CIDR" ] || die "PRIVATEIP_CIDR must be CIDR, like 10.250.0.0/16"

case "$PREFIX" in
  ''|*[!0-9]*) die "Invalid CIDR prefix in PRIVATEIP_CIDR: /$PREFIX" ;;
esac
[ "$PREFIX" -ge 0 ] 2>/dev/null || die "Invalid CIDR prefix: /$PREFIX"
[ "$PREFIX" -le 32 ] 2>/dev/null || die "Invalid CIDR prefix: /$PREFIX"

HOSTBITS=$((32 - PREFIX))
# Runtime default poolSize is 65535; poolSize must be <= pool address count.
MAX_DEFAULT=65535
if [ "$HOSTBITS" -gt 16 ]; then
  # Any larger pool is capped by the runtime's effective default.
  MAX_ALLOWED="$MAX_DEFAULT"
else
  CAPACITY=1
  I=0
  while [ "$I" -lt "$HOSTBITS" ]; do
    CAPACITY=$((CAPACITY * 2))
    I=$((I + 1))
  done
  MAX_ALLOWED=$((CAPACITY - 1))
fi
[ "$MAX_ALLOWED" -ge 1 ] || die "CIDR has no usable capacity: $PRIVATEIP_CIDR"

# If user provides PRIVATEIP_POOLSIZE, clamp it; otherwise compute a sane default.
if [ -n "${PRIVATEIP_POOLSIZE:-}" ]; then
  case "$PRIVATEIP_POOLSIZE" in
    ''|*[!0-9]*) die "PRIVATEIP_POOLSIZE must be an integer" ;;
  esac

  # Clamp to [1, min(65535, capacity-1)]
  LIMIT="$MAX_ALLOWED"
  [ "$LIMIT" -gt "$MAX_DEFAULT" ] && LIMIT="$MAX_DEFAULT"

  if [ "$PRIVATEIP_POOLSIZE" -lt 1 ]; then
    PRIVATEIP_POOLSIZE=1
  elif [ "$PRIVATEIP_POOLSIZE" -gt "$LIMIT" ]; then
    PRIVATEIP_POOLSIZE="$LIMIT"
  fi
else
  # Default: min(65535, capacity-1) (so /16 -> 65535; /20 -> 4095; etc.)
  PRIVATEIP_POOLSIZE="$MAX_ALLOWED"
  [ "$PRIVATEIP_POOLSIZE" -gt "$MAX_DEFAULT" ] && PRIVATEIP_POOLSIZE="$MAX_DEFAULT"
fi

echo "Starting gateway with PRIVATEIP_CIDR=${PRIVATEIP_CIDR}, TUN_IF=${TUN_IF}, PRIVATEIP_POOLSIZE=${PRIVATEIP_POOLSIZE}."

# ---------- render config ----------
[ -f "$TEMPLATE" ] || die "Missing template: $TEMPLATE"
mkdir -p "$(dirname "$CONFIG")"

sed -e "s|\${PRIVATEIP_CIDR}|$PRIVATEIP_CIDR|g" \
    -e "s|\${PRIVATEIP_POOLSIZE}|$PRIVATEIP_POOLSIZE|g" \
    -e "s|\${TUN_IF}|$TUN_IF|g" \
    "$TEMPLATE" > "$CONFIG"

# ---------- start gateway process ----------
xray -config "$CONFIG" &
PID="$!"
trap 'cleanup' INT TERM EXIT

# Wait for tun interface to appear (created by gateway process)
i=0
while [ "$i" -lt 12 ]; do
  if ip link show "$TUN_IF" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    die "gateway process exited before TUN interface $TUN_IF appeared"
  fi
  i=$((i + 1))
  sleep 1
done

ip link show "$TUN_IF" >/dev/null 2>&1 || die "TUN interface $TUN_IF did not appear"

# Route private CIDR into the tun interface (idempotent)
ip route replace "$PRIVATEIP_CIDR" dev "$TUN_IF"

wait "$PID"
PID=""
trap - INT TERM EXIT
