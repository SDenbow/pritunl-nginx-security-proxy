# Pritunl Nginx Security Proxy

Nginx reverse proxy deployment and security hardening for Pritunl.

This project was created to remediate username enumeration in the Pritunl
administrative authentication endpoint while minimizing changes to Pritunl
itself.

## Problem

Pritunl can return different authentication error responses for:

- a nonexistent username
- an existing username with an invalid password

Those distinct responses allow an unauthenticated client to determine whether
a username exists.

The remediation implemented by this project places Nginx in front of the
Pritunl web interface and normalizes the response from the exact
`/auth/session` endpoint.

Both authentication failures are externally returned as:

    {"error": "auth_invalid", "error_msg": "Authentication credentials are not valid."}

This removes the distinct response-body behavior identified by the external
penetration test.

## Architecture

Before deployment:

    Internet
       |
    TCP/80,443
       |
    Pritunl

After deployment:

    Internet
       |
    TCP/80,443
       |
    Nginx
       |
    HTTPS
       |
    127.0.0.1:8443
       |
    Pritunl

Nginx owns the public web ports.

Pritunl continues to use HTTPS on the backend.

TCP/8443 must not be published through the perimeter firewall or NAT.

## Components

- `install.sh` - installation and migration script
- `rollback.sh` - deterministic rollback using installer-generated state
- `config/pritunl-nginx.conf.template` - production Nginx configuration
- `scripts/health-check.sh` - service and listener validation
- `scripts/test-auth.sh` - authentication-response normalization test
- `docs/deployment.md` - deployment procedure
- `docs/rollback.md` - rollback procedure

## Supported Operating Systems

Tested:

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

The installer rejects unsupported Ubuntu releases.

## TLS

Public TLS is managed by Certbot and Nginx.

Pritunl continues to use HTTPS internally on the backend port. Certificate
validation is disabled for the localhost backend connection because the
internal Pritunl certificate does not need to be publicly trusted.

After the public Nginx/Certbot configuration passes health validation, the
installer disables Pritunl ACME renewal by setting:

    app.acme_domain = null

Only `app.acme_domain` is changed. The existing Pritunl backend certificate,
private key, ACME account state, and ACME timestamp are not cleared by the
installer.

Port 80 remains available through Nginx for Let's Encrypt HTTP-01 validation.

A Certbot deploy hook reloads Nginx following successful certificate renewal.

## Authentication Normalization

Only the exact endpoint:

    /auth/session

is modified.

Other Pritunl HTTP responses, including unrelated 401 responses, are not
globally rewritten.

The deployment test verifies that:

- nonexistent username returns HTTP 401
- existing username with incorrect password returns HTTP 401
- both response bodies are byte-for-byte identical

## Backup and Rollback

Every installer run creates a timestamped backup under:

    /root/pritunl-nginx-backup-YYYYMMDD-HHMMSS

The backup includes:

- `/etc/pritunl.conf`
- relevant preexisting Nginx site configuration when present
- relevant Certbot renewal configuration when present
- full `mongodump` of the `pritunl` database
- `rollback.env` state manifest

The rollback manifest records the pre-install Pritunl and Nginx state required
for deterministic rollback.

MongoDB is intentionally NOT automatically restored by `rollback.sh`.

See `docs/rollback.md`.

## Important Production Considerations

### Backend exposure

TCP/8443 must not be reachable from the Internet after deployment.

This is primarily enforced at the perimeter firewall/NAT layer.

### Pritunl clusters

Pritunl `app.*` settings are stored in the database and Pritunl reports that
changes are applied to all hosts in a cluster.

The current installer should therefore be treated as a coordinated
cluster-wide change when used with multi-host Pritunl deployments.

Do not independently run the migration on a production cluster until the
cluster topology and migration sequence have been reviewed.

### Existing Nginx installations

Production hosts with unrelated existing Nginx workloads require additional
review before deployment.

The current project is designed primarily for Pritunl hosts where Nginx is
absent or dedicated to this Pritunl proxy.

### Pritunl ACME configuration

The installer transfers public certificate renewal responsibility from Pritunl
to Certbot.

After Nginx is running and the deployment health check succeeds, the installer
sets:

    app.acme_domain = null

This disables Pritunl ACME renewal while preserving the existing Pritunl
backend certificate and related certificate state.

Do not use destructive certificate-reset operations as part of this
migration.

If Pritunl SSO is enabled, `app.server_sso_url` must already be explicitly
configured before migration. The installer refuses to continue when SSO is
enabled and `app.server_sso_url` is unset, because Pritunl can otherwise use
`app.acme_domain` as an SSO URL fallback.

## Repository Security

This repository is intended to remain private.

Do not commit:

- private keys
- VPN profiles
- passwords
- authentication tokens
- production configuration exports containing secrets
- MongoDB backups
