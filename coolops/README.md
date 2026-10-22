# CoolOps repository service package

CoolOps installs this package at an explicitly reviewed Git commit. Only the files listed in service.json enter a private build context. BASE_IMAGE is resolved to an immutable digest by the host operator. The repository's historical Compose, sample credentials and certificates are never imported.

Use Infrastructure → Website SFTP in CoolOps to create a dedicated instance or explicitly shared instance, then bind registered local website directories. Each account has an isolated chroot, UID/GID, SSH keys or SHA-512 password hash and optional read-only mount. The instance generates its own persistent SSH host key. The entrypoint does not recursively change ownership of website files. Account configuration is mounted privately; restarting through CoolOps recreates the container to revoke removed users. Website files and host keys survive stop/recreate.

See CoolOps docs/REPOSITORY_SERVICES.md for installation, sharing, recovery and acceptance checks. Existing deployments keep their current entrypoint and require deliberate migration.
