#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <fqdn> <known-valid-username>"
    echo
    echo "Example:"
    echo "  $0 vpn.example.com admin.user"
}

if [[ $# -ne 2 ]]; then
    usage
    exit 2
fi

FQDN="$1"
KNOWN_USER="$2"

TEST_USER="THIS-USER-SHOULD-NOT-EXIST-$(date +%s)"
BAD_PASSWORD="DefinitelyWrongPassword-$(date +%s)-X!"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

NONEXISTENT_BODY="$TMP_DIR/nonexistent.json"
EXISTING_BODY="$TMP_DIR/existing.json"

echo "Testing Pritunl authentication-response normalization..."
echo "FQDN:       $FQDN"
echo "Known user: $KNOWN_USER"
echo

NONEXISTENT_CODE="$(
    curl -sS \
        -o "$NONEXISTENT_BODY" \
        -w '%{http_code}' \
        "https://${FQDN}/auth/session" \
        -H 'Content-Type: application/json' \
        --data "{\"username\":\"${TEST_USER}\",\"password\":\"${BAD_PASSWORD}\"}"
)"

EXISTING_CODE="$(
    curl -sS \
        -o "$EXISTING_BODY" \
        -w '%{http_code}' \
        "https://${FQDN}/auth/session" \
        -H 'Content-Type: application/json' \
        --data "{\"username\":\"${KNOWN_USER}\",\"password\":\"${BAD_PASSWORD}\"}"
)"

echo "Nonexistent-user HTTP status: $NONEXISTENT_CODE"
echo "Existing-user HTTP status:    $EXISTING_CODE"
echo

if [[ "$NONEXISTENT_CODE" != "401" || "$EXISTING_CODE" != "401" ]]; then
    echo "FAIL: Expected HTTP 401 for both invalid authentication attempts."
    exit 1
fi

if cmp -s "$NONEXISTENT_BODY" "$EXISTING_BODY"; then
    echo "PASS: Authentication response bodies are byte-for-byte identical."
    echo
    sha256sum "$NONEXISTENT_BODY" "$EXISTING_BODY"
    exit 0
fi

echo "FAIL: Authentication response bodies differ."
echo
echo "Nonexistent-user response:"
cat "$NONEXISTENT_BODY"
echo
echo
echo "Existing-user response:"
cat "$EXISTING_BODY"
echo
exit 1
