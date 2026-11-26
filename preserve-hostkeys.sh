#!/bin/bash
# Run on the Docker host BEFORE removing/rebuilding an existing deployment.
set -euo pipefail
umask 077
container=${1:-sftp_server}
config_dir=${2:-/data/config/sftp}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$config_dir/hostkeys"
chmod 700 "$config_dir/hostkeys"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/ssh"
# Capture all active key pairs without stopping the old container. Never print keys.
for type in ed25519 rsa ecdsa; do
    name="ssh_host_${type}_key"
    docker cp -L "$container:/etc/ssh/$name" "$scratch/ssh/$name"
    docker cp -L "$container:/etc/ssh/$name.pub" "$scratch/ssh/$name.pub"
    # An existing persistent identity must agree with the deployed identity.
    if [[ -e "$config_dir/hostkeys/$name" ]]; then
        live=$(ssh-keygen -y -P '' -f "$scratch/ssh/$name")
        saved=$(ssh-keygen -y -P '' -f "$config_dir/hostkeys/$name")
        [[ "$live" == "$saved" ]] || { echo "Saved $name differs from the current server; migration stopped." >&2; exit 1; }
    fi
done
bash "$script_dir/hostkeys.sh" "$config_dir/hostkeys" "$scratch/ssh"
echo 'Existing host key pairs preserved. It is now safe to recreate this container with the same config mount.'
ssh-keygen -lf "$config_dir/hostkeys/ssh_host_ed25519_key.pub" -E sha256
