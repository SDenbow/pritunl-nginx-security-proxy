# Deployment

## Purpose

This procedure deploys Nginx in front of the Pritunl web interface and
normalizes authentication failure responses from `/auth/session`.

The installer performs the migration, creates backups, configures TLS,
validates the resulting services, and optionally tests authentication-response
normalization.

## Prerequisites

Before production deployment confirm:

1. The host is running a supported Ubuntu release.
2. Pritunl and MongoDB are healthy.
3. The Pritunl administrative web interface is reachable.
4. The public FQDN resolves correctly.
5. TCP/80 and TCP/443 reach this host.
6. TCP/8443 is NOT published externally.
7. You have root or sudo access.
8. You know a valid Pritunl administrator username for the normalization test.
9. The host is not part of an unreviewed multi-host Pritunl cluster.
10. Existing Nginx workloads, if any, have been reviewed for compatibility.

## Recommended Pre-Deployment Validation

Confirm Pritunl:

    systemctl is-active pritunl

Confirm MongoDB:

    systemctl is-active mongod

Review listeners:

    sudo ss -lntp

Review the safe Pritunl web settings individually:

    sudo pritunl get app.reverse_proxy
    sudo pritunl get app.redirect_server
    sudo pritunl get app.server_ssl
    sudo pritunl get app.server_port

Do not dump the entire `app` configuration solely for this check because other
settings can contain sensitive material.

## Installation

From the repository:

    sudo ./install.sh \
      --fqdn vpn.example.com \
      --email admin@example.com \
      --known-user administrator

Arguments:

    --fqdn          Public Pritunl FQDN
    --email         Email used when a new Let's Encrypt certificate is required
    --backend-port  Internal Pritunl HTTPS port; defaults to 8443
    --known-user    Known valid username used by the normalization test

If an existing Certbot certificate is present, certificate issuance is
skipped.

## Installer Sequence

The installer:

1. Validates the operating system and parameters.
2. Creates a timestamped backup directory.
3. Backs up Pritunl configuration.
4. Creates a full MongoDB dump of the `pritunl` database.
5. Captures pre-install state in `rollback.env`.
6. Performs fresh-host safety checks.
7. Installs missing Nginx/Certbot packages when required.
8. Verifies the Nginx HTTP substitution module is available.
9. Changes Pritunl to reverse-proxy mode.
10. Moves the Pritunl HTTPS web listener to the backend port.
11. Restarts Pritunl only when its settings changed.
12. Verifies the backend HTTPS service.
13. Obtains or reuses the public Let's Encrypt certificate.
14. Renders the production Nginx configuration.
15. Starts or reloads Nginx.
16. Installs the Certbot deploy hook.
17. Runs the health check.
18. Runs the authentication normalization test when `--known-user` is supplied.

## Expected Final State

Pritunl:

    app.reverse_proxy = true
    app.redirect_server = false
    app.server_ssl = true
    app.server_port = 8443

Listeners:

    TCP/80    Nginx
    TCP/443   Nginx
    TCP/8443  Pritunl

## Health Check

Run:

    sudo ./scripts/health-check.sh vpn.example.com 8443

The check validates:

- Nginx service
- Pritunl service
- Nginx configuration
- TCP/80 listener
- TCP/443 listener
- Pritunl backend listener
- HTTP-to-HTTPS redirect
- public HTTPS login page
- valid public certificate
- Let's Encrypt certificate files

## Authentication Test

Run:

    ./scripts/test-auth.sh vpn.example.com administrator

A successful test requires:

    Nonexistent-user HTTP status: 401
    Existing-user HTTP status:    401

    PASS: Authentication response bodies are byte-for-byte identical.

The script also prints SHA-256 hashes of both response bodies.

## Manual Functional Validation

After deployment:

1. Open the public Pritunl URL.
2. Confirm an administrator can log in normally.
3. Confirm an invalid username receives the generic authentication error.
4. Confirm a valid username with an incorrect password receives the same error.
5. Connect a Pritunl VPN client.
6. Confirm VPN traffic passes normally.

## Certificate Renewal

Certbot owns the public certificate.

A deploy hook is installed under:

    /etc/letsencrypt/renewal-hooks/deploy/

The hook reloads Nginx after successful renewal.

Validate renewal with:

    sudo certbot renew --dry-run

## Failure Handling

If the installer fails after Pritunl migration begins, it reports:

- the backup directory
- the original Pritunl settings
- the settings observed at the beginning of migration

The installer intentionally does NOT attempt an automatic rollback.

Use the generated backup and `rollback.sh` after reviewing the failure.

## Production Warning: Pritunl Clusters

Pritunl reports that `app.*` setting changes are stored in its database and
applied to all hosts in the cluster.

The installer currently assumes either:

- a single-host Pritunl deployment, or
- a deliberately coordinated cluster migration

Do not treat each member of a multi-host production cluster as an independent
migration.

## Production Warning: Existing Nginx

If Nginx already serves unrelated applications on the host, review the
configuration before running this installer.

Do not assume the installer can safely merge arbitrary existing Nginx
workloads.
