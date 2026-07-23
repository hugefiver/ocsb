#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not() {
  local desc="$1"; shift
  if ! "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "=== ocsb network test suite ==="
echo "  NOTE: Runs INSIDE sandbox with network.enable=true (filtered mode)"
echo ""

echo "--- environment ---"
assert "OCSB_NETWORK is 'filtered'" [ "${OCSB_NETWORK:-}" = "filtered" ]
echo ""

echo "--- DNS + public internet access ---"
set +e
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://httpbin.org/get 2>/dev/null)
HTTP_EXIT=$?
set -e
assert "public HTTPS command exits zero" [ "$HTTP_EXIT" -eq 0 ]
assert "curl public HTTPS returns an HTTP code" [ -n "$HTTP_CODE" ]
assert "curl public HTTPS works — implies DNS resolution (got $HTTP_CODE)" [ "$HTTP_CODE" != "000" ]
echo ""

echo "--- private range blocking ---"
assert_not "10.0.0.1 unreachable" \
  curl -s -o /dev/null --connect-timeout 3 http://10.0.0.1/ 2>/dev/null

assert_not "172.16.0.1 unreachable" \
  curl -s -o /dev/null --connect-timeout 3 http://172.16.0.1/ 2>/dev/null

assert_not "192.168.1.1 unreachable" \
  curl -s -o /dev/null --connect-timeout 3 http://192.168.1.1/ 2>/dev/null

assert_not "169.254.1.1 unreachable" \
  curl -s -o /dev/null --connect-timeout 3 http://169.254.1.1/ 2>/dev/null
echo ""

echo "--- iptables rules ---"
set +e
IPTABLES_OUTPUT=$(iptables -L OUTPUT -n 2>/dev/null)
IPTABLES_EXIT=$?
set -e
if [ "$IPTABLES_EXIT" -eq 0 ]; then
  assert "iptables has ACCEPT for 10.0.2.0/24" grep -q "10.0.2.0/24" <<< "$IPTABLES_OUTPUT"
  assert "iptables has DROP for 10.0.0.0/8" grep -q "10.0.0.0/8" <<< "$IPTABLES_OUTPUT"
else
  echo "  SKIP: iptables not available (exit $IPTABLES_EXIT; caps dropped or kernel restriction)"
fi
echo ""

echo "--- capability hardening ---"
if [ -r /proc/self/status ]; then
  _CAPEFF=""
  while IFS= read -r _line; do
    if [[ "$_line" == CapEff:* ]]; then
      _CAPEFF="${_line#CapEff:}"
      _CAPEFF="${_CAPEFF//[[:space:]]/}"
      break
    fi
  done < /proc/self/status
  assert "effective capabilities dropped to zero" [ "$_CAPEFF" = "0000000000000000" ]
else
  echo "  SKIP: /proc/self/status not readable"
fi
echo ""

echo "=== Network Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
