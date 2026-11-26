# CDP SFTP server

The Docker launcher publishes container port `22` on host port `2211`. Accounts
come from `/data/config/sftp/sftp_config.json`. Account configuration, user data
and any per-user `.ssh` files stay in the existing `/data/config/sftp` and
`/data/sftp` mounts.

## Update an existing server

Run these steps from the updated checkout on the Docker host. Keep the original
container and its image available until the replacement passes the client test.
Pause account, SSH configuration and key edits for the duration of the update.
Run each command in order and stop at any error before proceeding.

### 1. Verify the current deployment and make a backup

Confirm the container name, published port and mounts before using the commands
below. The launcher assumes `sftp_server`, `2211:22` and the two paths above.
If the deployment differs, carry its existing Docker settings into the launcher
before using it. Use a trusted SFTP client to connect to the old server with
strict host-key checking and note which accounts and operations must work after
the update.

```sh
sudo docker port sftp_server
sudo docker inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' sftp_server
sudo docker ps -a --format '{{.Names}}' --filter 'name=^/sftp_server_(before_update|failed_update)$'
```

The last command should print no names. If either name is already in use, choose
unused names for this update and use them consistently in steps 4 and 5.

Back up both mounted directories, keeping numeric ownership and modes. Pause
uploads while making a file archive, or use a verified storage snapshot. For
the standard mount paths, the commands below save an archive in a root-only
directory. Keep the backup outside source control because it contains account
credentials.

```sh
sudo install -d -m 700 /var/backups/cdp-sftp
backup_dir=$(sudo mktemp -d /var/backups/cdp-sftp/pre-update.XXXXXXXX)
sudo tar --numeric-owner -cpf "$backup_dir/sftp-mounts.tar" -C /data config/sftp sftp
sudo tar -tf "$backup_dir/sftp-mounts.tar" >/dev/null
printf 'Backup directory %s\n' "$backup_dir"
```

### 2. Capture SSH state while the original server is running

```sh
sudo bash preserve-ssh-state.sh sftp_server /data/config/sftp/ssh-state
```

This creates a root-only directory with the complete `/etc/ssh` tree, including
configuration fragments, host keys and any authorization files stored there.
It follows symlinks to copy their contents. It also captures configured static
files such as custom `HostKey` files, host certificates, trusted user CA keys,
revocation lists and banners, as well as loaded external includes and the
effective settings reported by `sshd -T`.
The snapshot includes private keys. Keep a protected backup and retain the
original snapshot at its configured path for future restarts.

```sh
sudo cp -a -- /data/config/sftp/ssh-state "$backup_dir/"
```

For `Match` rules, supply a connection specification for each relevant user,
source address or other condition. For external wildcard `Include` rules, list
the entire directories after `--` to preserve the exact set of fragments.
List other custom dependencies after `--` as well. For tokenized or per-user
authorization paths outside `/etc/ssh` and the original mounts, list the actual
files or their containing directory. Retain the original mounts and services for
any external authentication commands, providers or sockets. Agent-backed host
keys require the original agent and a separate migration procedure.

```sh
sudo bash preserve-ssh-state.sh sftp_server /data/config/sftp/ssh-state \
  --match 'user=partner,host=partner.example,addr=192.0.2.10,laddr=172.17.0.2,lport=22' \
  -- /opt/sftp/sshd.d /opt/sftp/partner-keys
```

Use the command that fits your setup. A second capture needs a new destination.
Pass that same directory to both `run-sftp-docker.sh --check` and
`run-sftp-docker.sh` in the following steps. Resolve any capture error while the
original container is still available.

### 3. Build and preflight with the old server still online

```sh
sudo bash build-sftp-image.sh
sudo bash run-sftp-docker.sh --check
```

Preflight starts an isolated check container with read-only mounts. It verifies
captured file contents, ownership, modes, OpenSSH configuration validity and the
effective global settings. Continue only after `Preflight passed` appears. A new
OpenSSH release can change defaults. If preflight reports differences, keep the
old server running and review the image and configuration before trying again.

### 4. Switch containers and verify client access

```sh
sudo docker stop sftp_server
sudo docker rename sftp_server sftp_server_before_update
sudo bash run-sftp-docker.sh
sudo docker ps --filter 'name=^/sftp_server$'
sudo docker logs --tail 50 sftp_server
```

The replacement binds the captured SSH files read-only at their original paths
and uses the original config and data mounts. After provisioning the accounts,
startup checks the snapshot again, including any supplied `Match` contexts.
If a check fails, the daemon never starts. For this update, start with the
snapshot so the entrypoint uses the captured keys.

Reconnect from the same trusted client with strict host-key checking enabled
and its existing `known_hosts` entry. For an OpenSSH client, use the real account
and host in the following command.

```sh
sftp -o StrictHostKeyChecking=yes -P 2211 partner@sftp.example
```

Confirm each required login method and check the expected directory listing
and transfer permissions. A host-key warning, failed login or changed permissions
means the update needs investigation. Keep the client's existing trust entry
and roll back if the new server fails acceptance.

### 5. Roll back if any check fails after the switch

If the original container was stopped and never renamed, restart it with
`sudo docker start sftp_server`. Otherwise use the steps below.

If the replacement container exists, stop it and rename it so the original
name is free. Keep it for log inspection.

```sh
sudo docker stop sftp_server
sudo docker rename sftp_server sftp_server_failed_update
```

Then return the original container to service and rerun the trusted-client test.

```sh
sudo docker rename sftp_server_before_update sftp_server
sudo docker start sftp_server
```

Keep the rollback container and SSH snapshot until the update is accepted.
Take a new snapshot before future updates if the live SSH policy has changed.

## New installations and key recovery

For a new deployment, create the two host directories, place `sftp_config.json`
in `/data/config/sftp`, build the image, then use
`sudo bash run-sftp-docker.sh --fresh`. Startup generates ED25519, RSA and ECDSA
keys once and stores them in `/data/config/sftp/hostkeys`. Keep that directory
and its `.initialized` marker with the config backup.

If an initialized private key is missing, damaged or mismatched, startup stops.
Restore the original private key from a protected backup or the original
container. A missing public file can be derived from the existing private key.
`preserve-hostkeys.sh` remains available for a key-only migration. Use
`preserve-ssh-state.sh` for an update that preserves SSH policy as well.

The [CoolOps package](coolops/README.md) uses its own deployment procedure and
persistent `/data/hostkeys` mount. The container switch above is for the
standalone CDP deployment.

Run `bash tests/hostkeys.sh` for host-key regression checks. On Debian with
OpenSSH installed, run `sudo bash tests/ssh-state.sh` to exercise snapshot and
startup verification with an isolated OpenSSH fixture and a Docker CLI stub.
