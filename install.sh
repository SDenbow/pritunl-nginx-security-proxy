#!/usr/bin/env bash
set -euo pipefail

MIGRATION_STARTED=0
INSTALL_COMPLETE=0

installation_exit_handler() {
    local rc=$?

    if [[ "$rc" -ne 0 && "$MIGRATION_STARTED" -eq 1 && "$INSTALL_COMPLETE" -eq 0 ]]; then
        echo >&2
        echo "============================================================" >&2
        echo "WARNING: Pritunl/Nginx migration did not complete." >&2
        echo "============================================================" >&2

        if [[ -n "${BACKUP_DIR:-}" ]]; then
            echo "Backup directory:" >&2
            echo "  ${BACKUP_DIR}" >&2
        fi

        if [[ -n "${CURRENT_REVERSE_PROXY:-}" ]]; then
            echo >&2
            echo "Original Pritunl settings were:" >&2
            echo "  app.reverse_proxy  = ${CURRENT_REVERSE_PROXY}" >&2
            echo "  app.redirect_server = ${CURRENT_REDIRECT_SERVER}" >&2
            echo "  app.server_ssl      = ${CURRENT_SERVER_SSL}" >&2
            echo "  app.server_port     = ${CURRENT_SERVER_PORT}" >&2
            echo >&2
            echo "No automatic rollback was attempted." >&2
        fi

        echo "Review the failure before making additional changes." >&2
        echo "============================================================" >&2
    fi
}

trap installation_exit_handler EXIT

BACKEND_PORT="8443"
FQDN=""
EMAIL=""
KNOWN_USER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/config/pritunl-nginx.conf.template"

usage() {
    cat <<USAGE
Usage:
  sudo ./install.sh --fqdn vpn.example.com [options]

Required:
  --fqdn <hostname>        Public Pritunl hostname

Optional:
  --email <address>        Email address for Let's Encrypt.
                           Required only when issuing a new certificate.
  --backend-port <port>    Pritunl backend HTTPS port (default: 8443)
  --known-user <username>  Existing Pritunl admin username for auth-response test
  -h, --help               Show this help
USAGE
}

log() {
    echo
    echo "==> $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fqdn)
            [[ $# -ge 2 ]] || die "--fqdn requires a value."
            FQDN="$2"
            shift 2
            ;;
        --email)
            [[ $# -ge 2 ]] || die "--email requires a value."
            EMAIL="$2"
            shift 2
            ;;
        --backend-port)
            [[ $# -ge 2 ]] || die "--backend-port requires a value."
            BACKEND_PORT="$2"
            shift 2
            ;;
        --known-user)
            [[ $# -ge 2 ]] || die "--known-user requires a value."
            KNOWN_USER="$2"
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

[[ $EUID -eq 0 ]] || die "Run this installer with sudo."
[[ -n "$FQDN" ]] || die "--fqdn is required."

if [[ ! -f /etc/os-release ]]; then
    die "Unable to determine operating system."
fi

. /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Unsupported operating system: ${PRETTY_NAME:-unknown}. This installer currently supports Ubuntu only."
fi

case "${VERSION_ID:-}" in
    "22.04"|"24.04")
        echo "Supported operating system detected: ${PRETTY_NAME}"
        ;;
    *)
        die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported versions are 22.04 and 24.04."
        ;;
esac
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "Backend port must be numeric."
[[ -f "$TEMPLATE" ]] || die "Missing template: $TEMPLATE"

for cmd in pritunl systemctl curl sed ss; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/pritunl-nginx-backup-${TIMESTAMP}"

CERT_PATH="/etc/letsencrypt/live/${FQDN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${FQDN}/privkey.pem"

log "Installation parameters"
echo "FQDN:         $FQDN"
echo "Backend port: $BACKEND_PORT"
echo "Backup:       $BACKUP_DIR"

if [[ -n "$KNOWN_USER" ]]; then
    echo "Known user:   $KNOWN_USER"
fi

log "Creating backup"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -f /etc/pritunl.conf ]]; then
    cp -a /etc/pritunl.conf "$BACKUP_DIR/"
fi

if [[ -f /etc/nginx/sites-available/pritunl.conf ]]; then
    mkdir -p "$BACKUP_DIR/nginx"
    cp -a /etc/nginx/sites-available/pritunl.conf \
        "$BACKUP_DIR/nginx/"
fi

if [[ -f "/etc/letsencrypt/renewal/${FQDN}.conf" ]]; then
    mkdir -p "$BACKUP_DIR/letsencrypt"
    cp -a "/etc/letsencrypt/renewal/${FQDN}.conf" \
        "$BACKUP_DIR/letsencrypt/"
fi

if command -v mongodump >/dev/null 2>&1; then
    mongodump \
        --db pritunl \
        --out "$BACKUP_DIR/mongodb"
else
    die "mongodump is not installed; refusing to continue without a Pritunl database backup."
fi

chmod -R go-rwx "$BACKUP_DIR"

log "Running fresh-host preflight"

DNS_IPV4="$(
    {
        getent ahostsv4 "$FQDN" 2>/dev/null || true
    } |
        awk '{print $1}' |
        sort -u |
        paste -sd, -
)"

[[ -n "$DNS_IPV4" ]]     || die "FQDN ${FQDN} does not resolve to an IPv4 address."

echo "FQDN ${FQDN} resolves to:"
echo "  ${DNS_IPV4}"

if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    echo "Existing Certbot certificate found."
else
    echo "No existing Certbot certificate found."

    [[ -n "$EMAIL" ]]         || die "--email is required before changing Pritunl because a new Let's Encrypt certificate must be issued."
fi

log "Preinstalling Nginx and Certbot"

REQUIRED_PACKAGES=()

dpkg-query -W -f='${Status}' nginx 2>/dev/null |
    grep -q '^install ok installed$' ||
    REQUIRED_PACKAGES+=(nginx)

dpkg-query -W -f='${Status}' certbot 2>/dev/null |
    grep -q '^install ok installed$' ||
    REQUIRED_PACKAGES+=(certbot)

dpkg-query -W -f='${Status}' python3-certbot-nginx 2>/dev/null |
    grep -q '^install ok installed$' ||
    REQUIRED_PACKAGES+=(python3-certbot-nginx)

if [[ "${#REQUIRED_PACKAGES[@]}" -gt 0 ]]; then
    echo "Packages to install:"
    printf '  %s\n' "${REQUIRED_PACKAGES[@]}"

    (
        set -e

        POLICY_FILE="/usr/sbin/policy-rc.d"
        POLICY_BACKUP=""

        restore_policy_rc() {
            if [[ -n "$POLICY_BACKUP" && -f "$POLICY_BACKUP" ]]; then
                cp -a "$POLICY_BACKUP" "$POLICY_FILE"
            else
                rm -f "$POLICY_FILE"
            fi
        }

        trap restore_policy_rc EXIT

        if [[ -e "$POLICY_FILE" ]]; then
            POLICY_BACKUP="${BACKUP_DIR}/policy-rc.d.original"
            cp -a "$POLICY_FILE" "$POLICY_BACKUP"
        fi

        cat > "$POLICY_FILE" <<'POLICY_EOF'
#!/bin/sh
exit 101
POLICY_EOF

        chmod 755 "$POLICY_FILE"

        export DEBIAN_FRONTEND=noninteractive

        apt-get update
        apt-get install -y "${REQUIRED_PACKAGES[@]}"
    )
else
    echo "Nginx and Certbot packages are already installed."
fi

command -v nginx >/dev/null 2>&1     || die "Nginx installation verification failed."

command -v certbot >/dev/null 2>&1     || die "Certbot installation verification failed."

nginx -V 2>&1 | grep -q -- '--with-http_sub_module'     || die "Installed Nginx does not include ngx_http_sub_module."

if systemctl is-active --quiet nginx; then
    die "Nginx is unexpectedly running before Pritunl has been moved from ports 80/443."
fi

echo "Nginx/Certbot preflight passed."

log "Checking Pritunl backend configuration"

MIGRATION_STARTED=1

PRITUNL_CHANGES=0

CURRENT_REVERSE_PROXY="$(pritunl get app.reverse_proxy 2>/dev/null | awk '{print $NF}')"
CURRENT_REDIRECT_SERVER="$(pritunl get app.redirect_server 2>/dev/null | awk '{print $NF}')"
CURRENT_SERVER_SSL="$(pritunl get app.server_ssl 2>/dev/null | awk '{print $NF}')"
CURRENT_SERVER_PORT="$(pritunl get app.server_port 2>/dev/null | awk '{print $NF}')"

if [[ "$CURRENT_REVERSE_PROXY" != "true" ]]; then
    echo "Changing app.reverse_proxy: ${CURRENT_REVERSE_PROXY} -> true"
    pritunl set app.reverse_proxy true
    PRITUNL_CHANGES=1
else
    echo "app.reverse_proxy already correct."
fi

if [[ "$CURRENT_REDIRECT_SERVER" != "false" ]]; then
    echo "Changing app.redirect_server: ${CURRENT_REDIRECT_SERVER} -> false"
    pritunl set app.redirect_server false
    PRITUNL_CHANGES=1
else
    echo "app.redirect_server already correct."
fi

if [[ "$CURRENT_SERVER_SSL" != "true" ]]; then
    echo "Changing app.server_ssl: ${CURRENT_SERVER_SSL} -> true"
    pritunl set app.server_ssl true
    PRITUNL_CHANGES=1
else
    echo "app.server_ssl already correct."
fi

if [[ "$CURRENT_SERVER_PORT" != "$BACKEND_PORT" ]]; then
    echo "Changing app.server_port: ${CURRENT_SERVER_PORT} -> ${BACKEND_PORT}"
    pritunl set app.server_port "$BACKEND_PORT"
    PRITUNL_CHANGES=1
else
    echo "app.server_port already correct."
fi

if [[ "$PRITUNL_CHANGES" -eq 1 ]]; then
    log "Pritunl configuration changed; restarting service"

    systemctl restart pritunl
    sleep 3
else
    echo
    echo "Pritunl configuration already matches desired state."
    echo "Restart not required."
fi

systemctl is-active --quiet pritunl \
    || die "Pritunl service is not active."

ss -lnt | grep -qE "[:.]${BACKEND_PORT}[[:space:]]" \
    || die "Pritunl is not listening on backend port ${BACKEND_PORT}."

log "Testing Pritunl backend"

BACKEND_CODE="$(
    curl -sk \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        -H "Host: ${FQDN}" \
        "https://127.0.0.1:${BACKEND_PORT}/login"
)" || BACKEND_CODE="000"

[[ "$BACKEND_CODE" == "200" ]] \
    || die "Backend HTTPS test failed. /login returned HTTP ${BACKEND_CODE}."

echo "Backend HTTPS test passed."

log "Preparing Nginx"

mkdir -p /var/www/html

systemctl enable nginx >/dev/null

if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    log "Existing Let's Encrypt certificate found"
    echo "Certificate issuance skipped."
else
    [[ -n "$EMAIL" ]] \
        || die "No existing certificate found. --email is required for initial Let's Encrypt issuance."

    log "Installing temporary HTTP configuration for ACME"

    cat > /etc/nginx/sites-available/pritunl.conf <<HTTP_EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${FQDN};

    root /var/www/html;

    location /.well-known/acme-challenge/ {
        allow all;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
HTTP_EOF

    ln -sf /etc/nginx/sites-available/pritunl.conf \
        /etc/nginx/sites-enabled/pritunl.conf

    rm -f /etc/nginx/sites-enabled/default

    nginx -t

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi

    log "Requesting Let's Encrypt certificate"

    certbot certonly \
        --webroot \
        --webroot-path /var/www/html \
        --domain "$FQDN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive
fi

[[ -f "$CERT_PATH" ]] \
    || die "Let's Encrypt certificate is missing."

[[ -f "$KEY_PATH" ]] \
    || die "Let's Encrypt private key is missing."

log "Rendering production Nginx configuration"

sed \
    -e "s/{{FQDN}}/${FQDN}/g" \
    -e "s/{{BACKEND_PORT}}/${BACKEND_PORT}/g" \
    "$TEMPLATE" \
    > /etc/nginx/sites-available/pritunl.conf

ln -sf /etc/nginx/sites-available/pritunl.conf \
    /etc/nginx/sites-enabled/pritunl.conf

rm -f /etc/nginx/sites-enabled/default

nginx -t

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl start nginx
fi

log "Installing Certbot Nginx reload hook"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK_EOF'
#!/bin/sh
systemctl reload nginx
HOOK_EOF

chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

log "Running health check"

"${SCRIPT_DIR}/scripts/health-check.sh" \
    "$FQDN" \
    "$BACKEND_PORT"

if [[ -n "$KNOWN_USER" ]]; then
    log "Running authentication-response normalization test"

    "${SCRIPT_DIR}/scripts/test-auth.sh" \
        "$FQDN" \
        "$KNOWN_USER"
else
    echo
    echo "Authentication normalization test skipped."
    echo "Run manually with:"
    echo "  ${SCRIPT_DIR}/scripts/test-auth.sh ${FQDN} <known-valid-username>"
fi

INSTALL_COMPLETE=1

log "Installation complete"

echo "Backup directory:"
echo "  $BACKUP_DIR"
echo
echo "Public HTTPS:"
echo "  https://${FQDN}"
echo
echo "Pritunl backend:"
echo "  https://127.0.0.1:${BACKEND_PORT}"
echo
echo "IMPORTANT:"
echo "  TCP/${BACKEND_PORT} must NOT be published through the perimeter firewall/NAT."
