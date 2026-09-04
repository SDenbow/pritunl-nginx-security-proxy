#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  sudo ./rollback.sh --backup-dir /root/pritunl-nginx-backup-YYYYMMDD-HHMMSS
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo
    echo "==> $*"
}

BACKUP_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-dir)
            [[ $# -ge 2 ]] || die "--backup-dir requires a value."
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ $EUID -eq 0 ]] || die "This script must be run as root."
[[ -n "$BACKUP_DIR" ]] || die "--backup-dir is required."
[[ -d "$BACKUP_DIR" ]] || die "Backup directory not found: $BACKUP_DIR"

MANIFEST="$BACKUP_DIR/rollback.env"
[[ -f "$MANIFEST" ]] || die "Rollback manifest not found: $MANIFEST"

for cmd in pritunl systemctl ss curl cp rm ln nginx; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue

    case "$key" in
        ROLLBACK_MANIFEST_VERSION|FQDN|BACKEND_PORT|ORIGINAL_REVERSE_PROXY|ORIGINAL_REDIRECT_SERVER|ORIGINAL_SERVER_SSL|ORIGINAL_SERVER_PORT|ORIGINAL_NGINX_INSTALLED|ORIGINAL_NGINX_ACTIVE|ORIGINAL_NGINX_ENABLED|ORIGINAL_NGINX_SITE_AVAILABLE|ORIGINAL_NGINX_SITE_ENABLED|ORIGINAL_CERTBOT_RENEWAL)
            printf -v "$key" '%s' "$value"
            ;;
        *)
            die "Unexpected key in rollback manifest: $key"
            ;;
    esac
done < "$MANIFEST"

[[ "${ROLLBACK_MANIFEST_VERSION:-}" == "2" ]] \
    || die "Unsupported or incomplete rollback manifest version. Version 2 is required."

required_vars=(
    FQDN
    BACKEND_PORT
    ORIGINAL_REVERSE_PROXY
    ORIGINAL_REDIRECT_SERVER
    ORIGINAL_SERVER_SSL
    ORIGINAL_SERVER_PORT
    ORIGINAL_NGINX_INSTALLED
    ORIGINAL_NGINX_ACTIVE
    ORIGINAL_NGINX_ENABLED
    ORIGINAL_NGINX_SITE_AVAILABLE
    ORIGINAL_NGINX_SITE_ENABLED
    ORIGINAL_CERTBOT_RENEWAL
)

for var in "${required_vars[@]}"; do
    [[ -n "${!var:-}" ]] || die "Manifest variable is missing: $var"
done

case "$ORIGINAL_REVERSE_PROXY" in true|false) ;; *) die "Invalid ORIGINAL_REVERSE_PROXY" ;; esac
case "$ORIGINAL_REDIRECT_SERVER" in true|false) ;; *) die "Invalid ORIGINAL_REDIRECT_SERVER" ;; esac
case "$ORIGINAL_SERVER_SSL" in true|false) ;; *) die "Invalid ORIGINAL_SERVER_SSL" ;; esac
case "$ORIGINAL_NGINX_INSTALLED" in true|false) ;; *) die "Invalid ORIGINAL_NGINX_INSTALLED" ;; esac
case "$ORIGINAL_NGINX_ACTIVE" in true|false) ;; *) die "Invalid ORIGINAL_NGINX_ACTIVE" ;; esac
case "$ORIGINAL_NGINX_ENABLED" in true|false) ;; *) die "Invalid ORIGINAL_NGINX_ENABLED" ;; esac
case "$ORIGINAL_NGINX_SITE_AVAILABLE" in true|false) ;; *) die "Invalid ORIGINAL_NGINX_SITE_AVAILABLE" ;; esac
case "$ORIGINAL_NGINX_SITE_ENABLED" in true|false) ;; *) die "Invalid ORIGINAL_NGINX_SITE_ENABLED" ;; esac
case "$ORIGINAL_CERTBOT_RENEWAL" in true|false) ;; *) die "Invalid ORIGINAL_CERTBOT_RENEWAL" ;; esac

[[ "$ORIGINAL_SERVER_PORT" =~ ^[0-9]+$ ]] || die "Invalid ORIGINAL_SERVER_PORT."
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "Invalid BACKEND_PORT."

log "Rollback plan"

echo "Backup directory:"
echo "  $BACKUP_DIR"
echo
echo "Pritunl target state:"
echo "  app.reverse_proxy   = $ORIGINAL_REVERSE_PROXY"
echo "  app.redirect_server = $ORIGINAL_REDIRECT_SERVER"
echo "  app.server_ssl      = $ORIGINAL_SERVER_SSL"
echo "  app.server_port     = $ORIGINAL_SERVER_PORT"
echo
echo "Original Nginx state:"
echo "  installed           = $ORIGINAL_NGINX_INSTALLED"
echo "  active              = $ORIGINAL_NGINX_ACTIVE"
echo "  enabled at boot     = $ORIGINAL_NGINX_ENABLED"
echo "  site available      = $ORIGINAL_NGINX_SITE_AVAILABLE"
echo "  site enabled        = $ORIGINAL_NGINX_SITE_ENABLED"
echo
echo "MongoDB will NOT be restored."
echo "Let's Encrypt certificates will NOT be deleted."

echo
read -r -p "Type ROLLBACK to continue: " CONFIRM
[[ "$CONFIRM" == "ROLLBACK" ]] || die "Rollback cancelled."

log "Stopping Nginx before restoring Pritunl listener"

if systemctl is-active --quiet nginx; then
    systemctl stop nginx
else
    echo "Nginx is already stopped."
fi

log "Restoring Pritunl settings"

pritunl set app.reverse_proxy "$ORIGINAL_REVERSE_PROXY"
pritunl set app.redirect_server "$ORIGINAL_REDIRECT_SERVER"
pritunl set app.server_ssl "$ORIGINAL_SERVER_SSL"
pritunl set app.server_port "$ORIGINAL_SERVER_PORT"

systemctl restart pritunl
sleep 3

systemctl is-active --quiet pritunl \
    || die "Pritunl service is not active after rollback."

ss -lntp | grep -qE "[:.]${ORIGINAL_SERVER_PORT}[[:space:]]" \
    || die "Nothing is listening on expected Pritunl port ${ORIGINAL_SERVER_PORT}."

if [[ "$ORIGINAL_SERVER_SSL" == "true" ]]; then
    PRITUNL_SCHEME="https"
    CURL_TLS=(-k)
else
    PRITUNL_SCHEME="http"
    CURL_TLS=()
fi

PRITUNL_HTTP_STATUS="$(
    curl "${CURL_TLS[@]}" -sS -o /dev/null -w '%{http_code}' \
        -H "Host: ${FQDN}" \
        "${PRITUNL_SCHEME}://127.0.0.1:${ORIGINAL_SERVER_PORT}/login"
)"

[[ "$PRITUNL_HTTP_STATUS" == "200" ]] \
    || die "Pritunl login verification failed on ${PRITUNL_SCHEME}://127.0.0.1:${ORIGINAL_SERVER_PORT}/login (HTTP ${PRITUNL_HTTP_STATUS})."

echo "Pritunl is active and serving /login on port ${ORIGINAL_SERVER_PORT}."

log "Restoring prior Nginx site state"

if [[ "$ORIGINAL_NGINX_SITE_AVAILABLE" == "true" ]]; then
    [[ -f "$BACKUP_DIR/nginx/pritunl.conf" ]] \
        || die "Manifest says prior Nginx site existed, but backup file is missing."

    mkdir -p /etc/nginx/sites-available
    cp -a "$BACKUP_DIR/nginx/pritunl.conf" \
        /etc/nginx/sites-available/pritunl.conf
else
    rm -f /etc/nginx/sites-available/pritunl.conf
fi

if [[ "$ORIGINAL_NGINX_SITE_ENABLED" == "true" ]]; then
    [[ -f /etc/nginx/sites-available/pritunl.conf ]] \
        || die "Cannot enable prior Nginx site because site file is missing."

    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/pritunl.conf \
        /etc/nginx/sites-enabled/pritunl.conf
else
    rm -f /etc/nginx/sites-enabled/pritunl.conf
fi

if [[ "$ORIGINAL_NGINX_INSTALLED" == "true" ]]; then
    if [[ "$ORIGINAL_NGINX_ENABLED" == "true" ]]; then
        systemctl enable nginx
    else
        systemctl disable nginx >/dev/null 2>&1 || true
    fi

    if [[ "$ORIGINAL_NGINX_ACTIVE" == "true" ]]; then
        nginx -t
        systemctl start nginx
    else
        systemctl stop nginx >/dev/null 2>&1 || true
    fi
else
    systemctl disable nginx >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
fi

log "Rollback complete"

echo "Pritunl:"
echo "  listening on port ${ORIGINAL_SERVER_PORT}"
echo
echo "Nginx:"
echo "  restored to recorded pre-install state"
echo
echo "Backup retained:"
echo "  $BACKUP_DIR"
echo
echo "MongoDB was not restored."
echo "Let's Encrypt certificates were left in place."
