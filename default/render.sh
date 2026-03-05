#!/bin/sh
set -e

: "${PRIVATEIP_CIDR:=10.250.0.0/16}"
: "${TUN_IF:=gateway0}"
: "${DNS_UPSTREAM:=https://cloudflare-dns.com/dns-query,https://dns.google/dns-query}"
: "${DNS_BOOTSTRAP:=1.1.1.1:53,[2606:4700:4700::1111]:53,8.8.8.8:53,[2001:4860:4860::8888]:53}"
: "${LOGLEVEL:=warning}"
: "${DNSPROXY_CUSTOM:-}"
: "${GATEWAY_CUSTOM:-}"

TEMPLATE="/etc/template/config.template.json"
CONFIG="/etc/config/config.json"
mkdir -p "$(dirname "$CONFIG")"

die() { echo "[render] ERROR: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- FakeDNS pools + strategy ---

HAS_IPV4=0
HAS_IPV6=0
POOLS="[]"
REMAINING="$PRIVATEIP_CIDR"

while [ -n "$REMAINING" ]; do
  CIDR="${REMAINING%%,*}"
  [ "$REMAINING" = "$CIDR" ] && REMAINING="" || REMAINING="${REMAINING#*,}"

  PREFIX="${CIDR#*/}"
  IP_ADDR="${CIDR%/*}"
  [ "$PREFIX" != "$CIDR" ] || die "Invalid CIDR (missing prefix): $CIDR"

  case "$PREFIX" in
    ''|*[!0-9]*) die "Invalid prefix in CIDR: $CIDR" ;;
  esac

  case "$IP_ADDR" in
    *:*) HAS_IPV6=1; FAMILY_BITS=128 ;;
    *)   HAS_IPV4=1; FAMILY_BITS=32  ;;
  esac

  [ "$PREFIX" -ge 0 ] 2>/dev/null && [ "$PREFIX" -le "$FAMILY_BITS" ] 2>/dev/null \
    || die "Prefix out of range for address family: $CIDR"

  HOSTBITS=$((FAMILY_BITS - PREFIX))
  if [ "$HOSTBITS" -gt 16 ]; then
    POOL_SIZE=65535
  else
    CAP=1; I=0
    while [ "$I" -lt "$HOSTBITS" ]; do CAP=$((CAP * 2)); I=$((I + 1)); done
    POOL_SIZE=$((CAP - 1))
    [ "$POOL_SIZE" -gt 65535 ] && POOL_SIZE=65535
  fi

  POOLS=$(jq -n --argjson pools "$POOLS" \
                --arg     cidr  "$CIDR"  \
                --argjson size  "$POOL_SIZE" \
                '$pools + [{"ipPool": $cidr, "poolSize": $size}]')
done

[ "$HAS_IPV4" -eq 1 ] || [ "$HAS_IPV6" -eq 1 ] || die "No valid CIDRs found in PRIVATEIP_CIDR"

if [ "$HAS_IPV4" -eq 1 ] && [ "$HAS_IPV6" -eq 1 ]; then
  STRATEGY="UseIP"
elif [ "$HAS_IPV6" -eq 1 ]; then
  STRATEGY="UseIPv6"
else
  STRATEGY="UseIPv4"
fi

# --- dnsproxy config ---

DNSPROXY_CONFIG="/etc/config/dnsproxy.yaml"

if [ -n "$DNSPROXY_CUSTOM" ] && [ -f "$DNSPROXY_CONFIG" ]; then
  echo "[render] dnsproxy config: preserving existing (DNSPROXY_CUSTOM is set)"
else
  DNSPROXY_VERBOSE=false
  [ "$LOGLEVEL" = "debug" ] && DNSPROXY_VERBOSE=true
  printf 'listen-addrs:\n  - "127.0.0.1"\nlisten-ports:\n  - 5335\n' > "$DNSPROXY_CONFIG"
  printf 'verbose: %s\ncache: true\ncache-optimistic: true\nupstream-mode: parallel\n' "$DNSPROXY_VERBOSE" >> "$DNSPROXY_CONFIG"

  printf 'bootstrap:\n' >> "$DNSPROXY_CONFIG"
  REMAINING="$DNS_BOOTSTRAP"
  while [ -n "$REMAINING" ]; do
    ENTRY="${REMAINING%%,*}"
    [ "$REMAINING" = "$ENTRY" ] && REMAINING="" || REMAINING="${REMAINING#*,}"
    ENTRY=$(printf '%s' "$ENTRY" | tr -d ' \t')
    [ -z "$ENTRY" ] && continue
    printf '  - "%s"\n' "$ENTRY" >> "$DNSPROXY_CONFIG"
  done

  printf 'fallback:\n' >> "$DNSPROXY_CONFIG"
  REMAINING="$DNS_BOOTSTRAP"
  while [ -n "$REMAINING" ]; do
    ENTRY="${REMAINING%%,*}"
    [ "$REMAINING" = "$ENTRY" ] && REMAINING="" || REMAINING="${REMAINING#*,}"
    ENTRY=$(printf '%s' "$ENTRY" | tr -d ' \t')
    [ -z "$ENTRY" ] && continue
    printf '  - "%s"\n' "$ENTRY" >> "$DNSPROXY_CONFIG"
  done

  printf 'upstream:\n' >> "$DNSPROXY_CONFIG"

  DNS_COUNT=0
  REMAINING="$DNS_UPSTREAM"
  while [ -n "$REMAINING" ]; do
    ENTRY="${REMAINING%%,*}"
    [ "$REMAINING" = "$ENTRY" ] && REMAINING="" || REMAINING="${REMAINING#*,}"
    ENTRY=$(printf '%s' "$ENTRY" | tr -d ' \t')
    [ -z "$ENTRY" ] && continue
    printf '  - "%s"\n' "$ENTRY" >> "$DNSPROXY_CONFIG"
    DNS_COUNT=$((DNS_COUNT + 1))
  done

  [ "$DNS_COUNT" -gt 0 ] || die "DNS_UPSTREAM produced no entries"
  echo "[render] dnsproxy config written: ${DNS_COUNT} upstream(s)"
fi

# --- Render config ---

if [ -n "$GATEWAY_CUSTOM" ] && [ -f "$CONFIG" ]; then
  echo "[render] Gateway config: preserving existing (GATEWAY_CUSTOM is set)"
else
  [ -f "$TEMPLATE" ] || die "Template not found: $TEMPLATE"

  jq --argjson pools    "$POOLS"    \
     --arg     strategy "$STRATEGY" \
     --arg     tunif    "$TUN_IF"   \
     --arg     loglevel "$LOGLEVEL" \
     '.fakedns = $pools |
      .dns.queryStrategy = $strategy |
      (.outbounds[] | select(.tag == "direct")).settings.domainStrategy = $strategy |
      (.inbounds[]  | select(.protocol == "tun")).settings.name = $tunif |
      .log.loglevel = $loglevel' \
     "$TEMPLATE" > "$CONFIG"

  echo "[render] Config written: CIDRs=${PRIVATEIP_CIDR}, strategy=${STRATEGY}, TUN=${TUN_IF}"
fi
