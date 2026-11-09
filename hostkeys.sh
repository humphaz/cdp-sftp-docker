#!/bin/bash
# Persist host identities and expose them at OpenSSH's conventional paths.
set -euo pipefail
umask 077
key_dir=${1:?Persistent key directory required}
ssh_dir=${2:?SSH directory required}
mkdir -p "$key_dir" "$ssh_dir"
key_dir=$(cd "$key_dir" && pwd -P)
ssh_dir=$(cd "$ssh_dir" && pwd -P)
[[ "$key_dir" != "$ssh_dir" ]] || { echo 'Host key directories must differ.' >&2; exit 1; }
chmod 700 "$key_dir"
scratch=$(mktemp -d "$key_dir/.prepare.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() { echo "SFTP host key error: $* Restore the existing key pair; refusing to rotate identity." >&2; exit 1; }

# Prepare and validate every key before changing the SSH paths.
for type in ed25519 rsa ecdsa; do
    name="ssh_host_${type}_key"
    key="$key_dir/$name"
    legacy="$ssh_dir/$name"
    if [[ ! -e "$key" && ! -L "$key" ]]; then
        [[ ! -e "$key_dir/.initialized" ]] || fail "$name is missing."
        [[ ! -e "$key.pub" && ! -L "$key.pub" ]] || fail "$name has only a public key."
        if [[ -f "$legacy" && ! -L "$legacy" ]]; then
            # Adopt a pre-existing identity, including during migration.
            cp -p "$legacy" "$scratch/$name"
            if [[ -f "$legacy.pub" ]]; then
                cp -p "$legacy.pub" "$scratch/$name.pub"
            fi
        else
            [[ ! -e "$legacy.pub" && ! -L "$legacy" ]] || fail "$name has no usable private key."
            ssh-keygen -q -t "$type" -N '' -f "$scratch/$name"
        fi
        ssh-keygen -y -P '' -f "$scratch/$name" >"$scratch/derived.pub" || fail "$name is invalid."
        if [[ -f "$scratch/$name.pub" ]]; then
            [[ $(awk '{print $1 " " $2}' "$scratch/$name.pub") == $(awk '{print $1 " " $2}' "$scratch/derived.pub") ]] || fail "$name public/private keys disagree."
        else
            cp "$scratch/derived.pub" "$scratch/$name.pub"
        fi
        mv "$scratch/$name" "$key"
        mv "$scratch/$name.pub" "$key.pub"
    fi
    [[ -f "$key" && ! -L "$key" && -s "$key" ]] || fail "$name is empty or not a regular private key."
    chmod 600 "$key"
    ssh-keygen -y -P '' -f "$key" >"$scratch/derived.pub" || fail "$name is invalid."
    if [[ -e "$key.pub" || -L "$key.pub" ]]; then
        [[ -f "$key.pub" && ! -L "$key.pub" ]] || fail "$name public key is not a regular file."
        [[ $(awk '{print $1 " " $2}' "$key.pub") == $(awk '{print $1 " " $2}' "$scratch/derived.pub") ]] || fail "$name public/private keys disagree."
    else
        # Recover the public half from the same private key, never generate a replacement.
        mv "$scratch/derived.pub" "$key.pub"
    fi
    chmod 644 "$key.pub"
done
touch "$key_dir/.initialized"
for type in ed25519 rsa ecdsa; do
    name="ssh_host_${type}_key"
    ln -sfn "$key_dir/$name" "$ssh_dir/$name"
    ln -sfn "$key_dir/$name.pub" "$ssh_dir/$name.pub"
done
