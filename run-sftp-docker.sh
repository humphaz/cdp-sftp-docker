#!/bin/bash
set -euo pipefail

check_only=false
if [[ ${1:-} == --check ]]; then check_only=true; shift; fi
if (( $# > 1 )) || [[ $check_only == true && ${1:-} == --fresh ]]; then
    echo 'Usage: run-sftp-docker.sh [--check] [SNAPSHOT_DIRECTORY] or run-sftp-docker.sh --fresh' >&2
    exit 1
fi

config_dir=/data/config/sftp
snapshot=${1:-$config_dir/ssh-state}
ssh_mounts=()
if [[ $snapshot == --fresh ]]; then
    if [[ -e $config_dir/ssh-state || -L $config_dir/ssh-state ]]; then
        echo 'An SSH snapshot exists. Start with that snapshot.' >&2
        exit 1
    fi
else
    if [[ ! -s $snapshot/checks/mounts || ! -s $snapshot/checks/global.effective ||
          ! -s $snapshot/checks/files.sha256 || ! -s $snapshot/checks/files.metadata ]] ||
       ! grep -Fxq /etc/ssh "$snapshot/checks/mounts"; then
        echo 'A complete SSH snapshot is required. Capture the current server before updating. Use --fresh for a new installation.' >&2
        exit 1
    fi
    snapshot=$(realpath -e -- "$snapshot")
    if [[ $(stat -c '%u:%a' -- "$snapshot") != 0:700 ]]; then
        echo 'The SSH snapshot directory must be owned by root with mode 700.' >&2
        exit 1
    fi
    if [[ $snapshot == *[,\"$'\n'$'\r']* ]]; then
        echo 'Choose an SSH snapshot path without commas, quotes or line breaks.' >&2
        exit 1
    fi
    ssh_mounts+=(--mount "type=bind,src=$snapshot/checks,dst=/run/sftp-ssh-state,readonly")
    while IFS= read -r path; do
        # Keep the original writable account/data mounts in place. Verification
        # checks any explicitly captured files inside them at their live paths.
        case $path in /data/config/sftp/*|/data/sftp/*) continue ;; esac
        ssh_mounts+=(--mount "type=bind,src=$snapshot/files$path,dst=$path,readonly")
    done < "$snapshot/checks/mounts"
fi

data_mount=type=bind,src=/data/sftp,dst=/data/sftp
config_mount=type=bind,src=$config_dir,dst=$config_dir
if [[ $check_only == true ]]; then
    docker run --rm --network none --entrypoint /bin/bash \
        --mount "$data_mount,readonly" --mount "$config_mount,readonly" \
        "${ssh_mounts[@]}" sftp_image -ec \
        'mkdir -p /run/sshd; bash /usr/local/sbin/verify-sftp-ssh-state /run/sftp-ssh-state --global-only'
    echo 'Preflight passed. SSH files and global settings match the snapshot.'
    exit
fi

exec docker run -d \
  --name sftp_server \
  -p 2211:22 \
  --mount "$data_mount" \
  --mount "$config_mount" \
  "${ssh_mounts[@]}" \
  sftp_image
