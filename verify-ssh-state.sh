#!/bin/bash
set -euo pipefail
checks=${1:?SSH snapshot checks directory required}
mode=${2:-full}

fail() { printf 'SFTP SSH verification: %s\n' "$*" >&2; exit 1; }

[[ -s "$checks/mounts" && -s "$checks/files.metadata" &&
   -s "$checks/files.sha256" && -s "$checks/global.effective" ]] ||
    fail 'The snapshot checks are incomplete.'

(cd / && sha256sum --check --status "$checks/files.sha256") ||
    fail 'Captured SSH files are missing or changed. Restore the original snapshot.'

mapfile -t paths < "$checks/mounts"
(cd / && find -L "${paths[@]/#/.}" -printf '%m %U:%G %p\0' | LC_ALL=C sort -z) |
    cmp -s "$checks/files.metadata" - ||
    fail 'Captured SSH file ownership, permissions or paths differ from the snapshot.'

/usr/sbin/sshd -t
/usr/sbin/sshd -T | cmp -s "$checks/global.effective" - ||
    fail 'The effective SSH settings differ from the snapshot.'

if [[ $mode == --global-only ]]; then exit 0; fi

shopt -s nullglob
for context in "$checks"/match-*.context; do
    IFS= read -r spec < "$context"
    /usr/sbin/sshd -T -C "$spec" | cmp -s "${context%.context}.effective" - ||
        fail "The effective SSH settings differ for the saved context in ${context##*/}."
done
