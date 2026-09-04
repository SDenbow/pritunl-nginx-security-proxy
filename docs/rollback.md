# Rollback

## Purpose

`rollback.sh` restores the Pritunl web settings and Nginx service/site state
recorded immediately before an installer run.

Rollback is deterministic because `install.sh` writes the required state into:

    rollback.env

inside the timestamped backup directory.

## Usage

    sudo ./rollback.sh \
      --backup-dir /root/pritunl-nginx-backup-YYYYMMDD-HHMMSS

The script displays the recorded target state and requires explicit
confirmation:

    Type ROLLBACK to continue:

Enter:

    ROLLBACK

to proceed.

## Rollback Manifest

Current rollback manifests use:

    ROLLBACK_MANIFEST_VERSION=2

The manifest records:

- FQDN
- backend port
- original Pritunl reverse proxy setting
- original Pritunl redirect setting
- original Pritunl SSL setting
- original Pritunl web port
- whether Nginx was installed
- whether Nginx was active
- whether Nginx was enabled at boot
- whether the Pritunl Nginx site existed
- whether the Pritunl Nginx site was enabled
- whether Certbot renewal configuration existed

The rollback script parses an explicit allowlist of manifest fields rather than
executing the manifest as shell code.

## Rollback Sequence

The rollback script:

1. Validates the backup directory and manifest.
2. Displays the recorded rollback plan.
3. Requires explicit operator confirmation.
4. Stops Nginx before moving Pritunl back to its original port.
5. Restores the recorded Pritunl web settings.
6. Restarts Pritunl.
7. Verifies the original Pritunl port is listening.
8. Verifies the Pritunl `/login` endpoint.
9. Restores or removes the Pritunl Nginx site according to recorded state.
10. Restores Nginx active/enabled state.
11. Retains the backup directory.

## Conservative Rollback Behavior

Rollback intentionally does NOT attempt to completely erase everything the
installer may have installed.

### Nginx packages

If Nginx was not installed before the original migration, rollback stops and
disables Nginx and removes the Pritunl site configuration.

It does NOT automatically uninstall the Nginx package.

This avoids destructive package removal during an emergency rollback.

### Let's Encrypt

Rollback does NOT delete Let's Encrypt certificates or private keys.

It also does not automatically remove all Certbot state created during the
migration.

This is intentional to avoid destructive certificate operations.

### Certbot deploy hook

The Nginx reload deploy hook may remain installed following rollback.

If Nginx is disabled after rollback, certificate-renewal behavior should be
reviewed before leaving the host permanently in the rolled-back state.

### MongoDB

The installer creates a full MongoDB backup.

`rollback.sh` does NOT restore it.

Normal rollback changes only the web/proxy configuration and does not require
a database restore.

A MongoDB restore is a separate disaster-recovery operation and should only be
performed deliberately when database recovery is actually required.

## Expected Stock-Pritunl Rollback

For a host that originally had Pritunl directly serving HTTPS, a typical
rollback target is:

    app.reverse_proxy = false
    app.redirect_server = true
    app.server_ssl = true
    app.server_port = 443

Typical listeners after rollback:

    TCP/80   Pritunl
    TCP/443  Pritunl

There should be no Pritunl listener on TCP/8443.

## Post-Rollback Validation

Check settings:

    sudo pritunl get app.reverse_proxy
    sudo pritunl get app.redirect_server
    sudo pritunl get app.server_ssl
    sudo pritunl get app.server_port

Check services:

    systemctl is-active pritunl
    systemctl is-active nginx
    systemctl is-enabled nginx

Check listeners:

    sudo ss -lntp | grep -E ':(80|443|8443)[[:space:]]'

Check the local Pritunl login page:

    curl -sk -o /dev/null -w 'HTTP %{http_code}\n' \
      -H 'Host: vpn.example.com' \
      https://127.0.0.1/login

Then manually confirm:

1. The Pritunl administrative web interface loads.
2. Administrator authentication succeeds.
3. A VPN client connects.
4. VPN traffic passes.

## Pritunl Cluster Warning

Pritunl reports that `app.*` setting changes are stored in the database and
applied to all hosts in a cluster.

Rollback of those settings can therefore affect multiple cluster members.

Do not execute rollback independently on a production cluster member without
understanding the cluster-wide effect.

## Backup Retention

Rollback never deletes the selected backup directory.

Keep the backup until the deployment or rollback has been fully validated.
