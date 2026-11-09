# CDP SFTP server

Accounts are read from `/data/config/sftp/sftp_config.json`. Keep both mounts in
`run-sftp-docker.sh`: `/data/sftp` contains user files and `/data/config/sftp`
contains account configuration and the server's persistent SSH identity.

## Upgrade an existing server without changing its fingerprint

The old image generated host keys during its build. **Before removing the old
container**, preserve its private and public host keys on the Docker host:

```sh
sudo bash preserve-hostkeys.sh sftp_server /data/config/sftp
```

The command copies the active keys without restarting the server, checks them,
and prints only the ED25519 SHA-256 fingerprint. It can also copy from a stopped
container. If copying fails, keep the old container and resolve the error before
recreating it. Use the actual container name and host config directory if different.

Then build the updated image with `bash build-sftp-image.sh` and recreate the
container using the same mounts as `run-sftp-docker.sh`. Compare the fingerprint
with the one already trusted by CDP. Account edits and password resets can now
recreate the container while preserving every server host key.

## Key lifecycle

- New installations generate ED25519, RSA and ECDSA keys once, at first startup.
- Keys live in `/data/config/sftp/hostkeys`, outside the replaceable container.
  OpenSSH reads them through its usual `/etc/ssh/ssh_host_*` paths.
- Existing private/public pairs remain unchanged. A missing public file is
  recovered from its private key without changing the fingerprint.
- Invalid, mismatched or missing initialized private keys stop startup instead
  of silently generating a different server identity.
- Back up the entire config directory securely, including **private keys** and
  `.initialized`. Do not delete or replace `hostkeys` when applying account config.
  Passwords continue to come from the account configuration as before.

A previously lost private key cannot be recovered from its `.pub` file. Restore
the original pair from a backup or an old container to recover an already trusted
fingerprint. This change preserves the identity migrated into the persistent mount.

The separate [CoolOps package](coolops/README.md) already stores its ED25519 key
at `/data/hostkeys`; it must retain that instance's persistent host-key mount
when account changes recreate the container. The migration command above is for
the original CDP image and its `/data/config/sftp` mount.

Run the host-key regression checks with `bash tests/hostkeys.sh` (Bash and
OpenSSH's `ssh-keygen` are required).
