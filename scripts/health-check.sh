#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <fqdn> [backend-port]"
    echo
    echo "Example:"
    echo "  $0 vpn.example.com 8443"
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

FQDN="$1"
BACKEND_PORT="${2:-8443}"

FAILURES=0

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

echo "Pritunl Nginx proxy health check"
echo "FQDN:         $FQDN"
echo "Backend port: $BACKEND_PORT"
echo

if systemctl is-active --quiet nginx; then
    pass "Nginx service is active."
else
    fail "Nginx service is not active."
fi

if systemctl is-active --quiet pritunl; then
    pass "Pritunl service is active."
else
    fail "Pritunl service is not active."
fi

if nginx -t >/dev/null 2>&1; then
    pass "Nginx configuration syntax is valid."
else
    fail "Nginx configuration test failed."
fi

if ss -lnt | grep -qE '[:.]80[[:space:]]'; then
    pass "TCP/80 is listening."
else
    fail "TCP/80 is not listening."
fi

if ss -lnt | grep -qE '[:.]443[[:space:]]'; then
    pass "TCP/443 is listening."
else
    fail "TCP/443 is not listening."
fi

if ss -lnt | grep -qE "[:.]${BACKEND_PORT}[[:space:]]"; then
    pass "Pritunl backend port ${BACKEND_PORT} is listening."
else
    fail "Pritunl backend port ${BACKEND_PORT} is not listening."
fi

HTTP_CODE="$(
    curl -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        "http://${FQDN}/"
)" || HTTP_CODE="000"

if [[ "$HTTP_CODE" =~ ^30[1278]$ ]]; then
    pass "HTTP redirects to HTTPS."
else
    fail "HTTP returned ${HTTP_CODE}; expected redirect."
fi

HTTPS_CODE="$(
    curl -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        "https://${FQDN}/login"
)" || HTTPS_CODE="000"

if [[ "$HTTPS_CODE" == "200" ]]; then
    pass "HTTPS login page is reachable with a valid certificate."
else
    fail "HTTPS login page returned ${HTTPS_CODE}; expected 200."
fi

if [[ -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem" ]] &&
   [[ -f "/etc/letsencrypt/live/${FQDN}/privkey.pem" ]]; then
    pass "Let's Encrypt certificate files exist."
else
    fail "Let's Encrypt certificate files are missing."
fi

echo

if [[ "$FAILURES" -eq 0 ]]; then
    echo "HEALTH CHECK PASSED"
    exit 0
fi

echo "HEALTH CHECK FAILED: ${FAILURES} check(s) failed."
exit 1
