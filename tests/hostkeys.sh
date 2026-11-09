#!/bin/bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prepare() { bash "$repo/hostkeys.sh" "$tmp/config/hostkeys" "$tmp/ssh"; }
snapshot() {
    (cd "$tmp/config/hostkeys" && sha256sum ssh_host_* | sort)
}
expect_failure() {
    if prepare >"$tmp/error" 2>&1; then
        echo 'Expected failure, but preparation succeeded.' >&2
        exit 1
    fi
    grep -q 'refusing to rotate identity' "$tmp/error"
}

prepare
baseline=$(snapshot)
fingerprint=$(ssh-keygen -lf "$tmp/config/hostkeys/ssh_host_ed25519_key.pub" -E sha256)
[[ $(stat -c %a "$tmp/config/hostkeys") == 700 ]]
[[ $(stat -c %a "$tmp/config/hostkeys/ssh_host_ed25519_key") == 600 ]]
[[ $(stat -c %a "$tmp/config/hostkeys/ssh_host_ed25519_key.pub") == 644 ]]
echo 'PASS: first startup creates protected host keys'

# Account updates/password resets are independent of host identity. Recreate
# the ephemeral SSH directory each time, as a newly built container would.
for config in '{"users":[{"user":"existing","password":"same"}]}' \
              '{"users":[{"user":"existing","password":"same"},{"user":"new","password":"new"}]}' \
              '{"users":[{"user":"existing","password":"reset"}]}'; do
    printf '%s\n' "$config" >"$tmp/config/sftp_config.json"
    rm -rf "$tmp/ssh"
    prepare
    [[ $(snapshot) == "$baseline" ]]
    [[ $(readlink "$tmp/ssh/ssh_host_ed25519_key") == "$tmp/config/hostkeys/ssh_host_ed25519_key" ]]
done
prepare
[[ $(snapshot) == "$baseline" ]]
echo 'PASS: account changes, recreation and restart preserve every key byte'

cp "$tmp/config/hostkeys/ssh_host_ed25519_key.pub" "$tmp/original.pub"
rm "$tmp/config/hostkeys/ssh_host_ed25519_key.pub"
prepare
[[ $(ssh-keygen -lf "$tmp/config/hostkeys/ssh_host_ed25519_key.pub" -E sha256) == "$fingerprint" ]]
echo 'PASS: missing public key is recovered with the same fingerprint'

cp "$tmp/config/hostkeys/ssh_host_ed25519_key" "$tmp/original.key"
: >"$tmp/config/hostkeys/ssh_host_ed25519_key"
expect_failure
[[ ! -s "$tmp/config/hostkeys/ssh_host_ed25519_key" ]]
cp "$tmp/original.key" "$tmp/config/hostkeys/ssh_host_ed25519_key"
cp "$tmp/config/hostkeys/ssh_host_rsa_key.pub" "$tmp/config/hostkeys/ssh_host_ed25519_key.pub"
expect_failure
cp "$tmp/original.pub" "$tmp/config/hostkeys/ssh_host_ed25519_key.pub"
rm "$tmp/config/hostkeys/ssh_host_ed25519_key"
expect_failure
rm "$tmp/config/hostkeys/ssh_host_ed25519_key.pub"
expect_failure
cp "$tmp/original.key" "$tmp/config/hostkeys/ssh_host_ed25519_key"
cp "$tmp/original.pub" "$tmp/config/hostkeys/ssh_host_ed25519_key.pub"
[[ $(snapshot) == "$baseline" ]]
echo 'PASS: empty, mismatched and missing initialized keys fail without rotation'

# A pre-upgrade container has real key files in /etc/ssh. Test the migration
# command with Docker copy replaced by a local copy of those actual key pairs.
mkdir "$tmp/legacy" "$tmp/bin"
cp "$tmp/config/hostkeys/"ssh_host_* "$tmp/legacy/"
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == cp && "$2" == -L && "$3" == old-container:/etc/ssh/* ]]
cp "$TEST_LEGACY/${3##*/}" "$4"
MOCK
chmod +x "$tmp/bin/docker"
export TEST_LEGACY="$tmp/legacy"
export PATH="$tmp/bin:$PATH"
bash "$repo/preserve-hostkeys.sh" old-container "$tmp/migrated" >"$tmp/migration.log"
[[ $(cd "$tmp/migrated/hostkeys" && sha256sum ssh_host_* | sort) == "$baseline" ]]
bash "$repo/preserve-hostkeys.sh" old-container "$tmp/migrated" >"$tmp/migration.log"
bash "$repo/hostkeys.sh" "$tmp/migrated/hostkeys" "$tmp/new-container-ssh"
[[ $(cd "$tmp/migrated/hostkeys" && sha256sum ssh_host_* | sort) == "$baseline" ]]
echo 'PASS: migration and repeat migration preserve all live keys through recreation'

ssh-keygen -q -t ed25519 -N '' -f "$tmp/other"
cp "$tmp/other" "$tmp/migrated/hostkeys/ssh_host_ed25519_key"
if bash "$repo/preserve-hostkeys.sh" old-container "$tmp/migrated" >"$tmp/error" 2>&1; then
    echo 'Expected migration to reject a different saved identity.' >&2
    exit 1
fi
grep -q 'differs from the current server' "$tmp/error"
echo 'PASS: migration rejects an existing different identity'
