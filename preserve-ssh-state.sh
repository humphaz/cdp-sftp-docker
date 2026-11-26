#!/bin/bash
# Run on the Docker host while the original server is running.
set -euo pipefail
umask 077

fail() { printf 'SFTP SSH snapshot: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run as root to preserve file ownership and permissions.'
container=${1:-sftp_server}
snapshot=${2:-/data/config/sftp/ssh-state}
if (( $# >= 2 )); then shift 2; else shift "$#"; fi

matches=()
while [[ ${1:-} == --match ]]; do
    [[ -n ${2:-} && $2 != *$'\n'* ]] || fail '--match requires one sshd -C connection specification.'
    matches+=("$2")
    shift 2
done
if [[ ${1:-} == -- ]]; then shift; fi

[[ ! -e "$snapshot" && ! -L "$snapshot" ]] || fail 'Choose a new snapshot directory. Existing snapshots are kept.'
stage=$(mktemp -d -- "$(dirname -- "$snapshot")/.ssh-state.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/files" "$stage/checks"

# The repository's entrypoint starts sshd with its standard configuration path.
remote() { docker exec -u 0 "$container" "$@"; }
remote /usr/sbin/sshd -t
remote /usr/sbin/sshd -T > "$stage/checks/global.effective"
remote /usr/sbin/sshd -T -ddd -e > /dev/null 2> "$stage/includes" ||
    fail 'Cannot enumerate SSH includes from the original container.'
for i in "${!matches[@]}"; do
    printf '%s\n' "${matches[i]}" > "$stage/checks/match-$i.context"
    remote /usr/sbin/sshd -T -C "${matches[i]}" > "$stage/checks/match-$i.effective"
done

# Copy the whole SSH directory. Also capture static files referenced by the
# effective policy, plus explicitly named dependencies such as external Includes.
declare -A paths=( [/etc/ssh]=1 )
add_path() {
    local path=$1
    [[ $path == /* && $path != / && $path != */ && $path != *//* &&
       $path/ != */../* && $path/ != */./* && $path != *[,\"$'\n'$'\r']* ]] ||
        fail "Expected a clean absolute path suitable for a Docker bind mount: $path"
    case $path in
        /etc|/data|/data/sftp|/data/config|/data/config/sftp|/run|/run/sshd|/run/sftp-ssh-state*)
            fail "Choose specific SSH files or directories instead of $path." ;;
    esac
    paths["$path"]=1
}

for path in "$@"; do add_path "$path"; done
# OpenSSH reports the actual files it loaded, including nested Includes.
while IFS= read -r path; do add_path "$path"; done < <(
    sed -nE 's/\r$//; s/^debug[0-9]+: .* line [0-9]+: including (.+)$/\1/p' "$stage/includes"
)
rm -- "$stage/includes"
while IFS=' ' read -r option value; do
    case $option in
        hostkeyagent)
            [[ $value == none ]] || fail 'Preserve the configured host key agent and its socket separately before upgrading.' ;;
        hostkey)
            [[ $value == /* ]] || fail 'HostKey must use an absolute path.'
            if remote test -e "$value"; then
                add_path "$value"
                if remote test -e "$value.pub"; then add_path "$value.pub"; fi
            elif [[ $value != /etc/ssh/* ]]; then
                fail "External HostKey is unavailable: $value"
            fi ;;
        hostcertificate|trustedusercakeys|revokedkeys|modulifile|banner|securitykeyprovider|authorizedprincipalsfile)
            if [[ $value == /* && $value != *%* ]]; then add_path "$value"; fi ;;
        authorizedkeysfile)
            read -r -a key_files <<< "$value"
            for path in "${key_files[@]}"; do
                if [[ $path == /* && $path != *%* ]]; then add_path "$path"; fi
            done ;;
        usepam)
            if [[ $value == yes ]]; then add_path /etc/pam.d; fi ;;
    esac
done < <(sort -u "$stage/checks/"*.effective)

# A directory bind already includes its descendants. Keep mounts disjoint.
mounts=()
for path in "${!paths[@]}"; do
    parent=${path%/*}
    while [[ -n $parent && ! ${paths[$parent]+present} ]]; do parent=${parent%/*}; done
    if [[ -z $parent ]]; then mounts+=("$path"); fi
done
printf '%s\n' "${mounts[@]}" | LC_ALL=C sort > "$stage/checks/mounts"

# Materialize symlink targets, including the previous version's persistent host
# keys. Keep numeric ownership and modes, and publish only a complete snapshot.
remote tar --dereference -C / -cf - -- "${mounts[@]#/}" |
    tar --numeric-owner -xpf - -C "$stage/files"
(
    cd "$stage/files"
    [[ -s etc/ssh/sshd_config ]] || fail 'The captured sshd_config is missing or empty.'
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$stage/checks/files.sha256"
(
    cd "$stage/files"
    find "${mounts[@]/#/.}" -printf '%m %U:%G %p\0' | LC_ALL=C sort -z
) > "$stage/checks/files.metadata"

# Catch policy edits made during the capture. Schedule key/config writes outside
# the capture window and verify the replacement against a trusted SFTP client.
remote /usr/sbin/sshd -T | cmp -s "$stage/checks/global.effective" - ||
    fail 'The effective policy changed during capture. Retry after edits are complete.'
mv -T --no-clobber -- "$stage" "$snapshot"
[[ ! -d "$stage" ]] || fail 'A snapshot already exists at that destination.'
printf 'SSH state captured in %s\n' "$snapshot"
