#!/bin/bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
old=$root/old
new=$root/new
mkdir -p "$root/bin"
mkdir -p "$old"/{etc/ssh/sshd_config.d,etc/extra,run/sshd,private,dev}
touch "$old/dev/null"
for executable in /usr/sbin/sshd /usr/bin/{bash,test,tar,cmp,sha256sum,sort,find}; do
    cp --parents -L "$executable" "$old"
    while IFS= read -r library; do cp --parents -L "$library" "$old"; done < <(
        ldd "$executable" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^\//) print $i }'
    )
done
cat > "$old/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/usr/bin/bash
sshd:x:101:65534:sshd:/run/sshd:/usr/sbin/nologin
partner:x:1000:1000:partner:/data/sftp/partner:/usr/sbin/nologin
PASSWD
printf 'root:x:0:\npartner:x:1000:\n' > "$old/etc/group"
cat > "$old/etc/ssh/sshd_config" <<'CONFIG'
Include /etc/ssh/sshd_config.d/*.conf
Include /etc/extra/*.conf
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /private/custom_key
HostCertificate /private/custom_key-cert.pub
TrustedUserCAKeys /private/user_ca.pub
Subsystem sftp internal-sftp
Match Group partner
    PasswordAuthentication no
    Banner /private/partner_banner
CONFIG
printf 'PermitRootLogin no\n' > "$old/etc/ssh/sshd_config.d/root.conf"
printf 'AllowTcpForwarding no\n' > "$old/etc/extra/forwarding.conf"
printf 'Banner contents\n' > "$old/private/partner_banner"
ssh-keygen -qt ed25519 -N '' -f "$old/private/persisted"
ln -s /private/persisted "$old/etc/ssh/ssh_host_ed25519_key"
ln -s /private/persisted.pub "$old/etc/ssh/ssh_host_ed25519_key.pub"
ssh-keygen -qt ecdsa -N '' -f "$old/private/custom_key"
ssh-keygen -qt ed25519 -N '' -f "$root/ca"
cp "$root/ca.pub" "$old/private/user_ca.pub"
ssh-keygen -q -s "$root/ca" -I fixture -h -n sftp.example "$old/private/custom_key.pub"

cat > "$root/bin/docker" <<'DOCKER'
#!/bin/bash
set -eu
case $1 in
    exec)
        [[ $2 == -u && $3 == 0 && $4 == fake-old ]]
        shift 4
        case $1 in test|tar) set -- "/usr/bin/$1" "${@:2}";; esac
        exec chroot "$OLD_ROOT" "$@"
        ;;
    run) printf '%s\n' "$@" > "$DOCKER_ARGS" ;;
    *) exit 1 ;;
esac
DOCKER
chmod 755 "$root/bin/docker"
export OLD_ROOT=$old DOCKER_ARGS=$root/docker-args PATH="$root/bin:$PATH"
export LC_ALL=C
snapshot=$root/snapshot
match='user=partner,host=test.example,addr=192.0.2.10,laddr=192.0.2.20,lport=22'
bash "$repo/preserve-ssh-state.sh" fake-old "$snapshot" --match "$match"
[[ $(stat -c %a "$snapshot") == 700 ]]
[[ ! -L "$snapshot/files/etc/ssh/ssh_host_ed25519_key" ]]
cmp "$old/private/persisted" "$snapshot/files/etc/ssh/ssh_host_ed25519_key"
for p in custom_key custom_key.pub custom_key-cert.pub user_ca.pub partner_banner; do
    cmp "$old/private/$p" "$snapshot/files/private/$p"
done
grep -qx 'passwordauthentication no' "$snapshot/checks/match-0.effective"
cmp "$old/etc/extra/forwarding.conf" "$snapshot/files/etc/extra/forwarding.conf"
bash "$repo/run-sftp-docker.sh" --check "$snapshot"
grep -Fxq 'none' "$DOCKER_ARGS"
grep -Fxq "type=bind,src=$snapshot/files/etc/ssh,dst=/etc/ssh,readonly" "$DOCKER_ARGS"
bash "$repo/run-sftp-docker.sh" "$snapshot"
grep -Fxq '2211:22' "$DOCKER_ARGS"
grep -Fxq "type=bind,src=$snapshot/files/private/custom_key,dst=/private/custom_key,readonly" "$DOCKER_ARGS"
if bash "$repo/preserve-ssh-state.sh" fake-old "$snapshot" > "$root/error" 2>&1; then exit 1; fi
grep -Fq 'Choose a new snapshot directory' "$root/error"
if bash "$repo/preserve-ssh-state.sh" fake-old "$root/bad" -- /missing > "$root/error" 2>&1; then exit 1; fi
[[ ! -e "$root/bad" ]]
if bash "$repo/run-sftp-docker.sh" "$root/bad" > "$root/error" 2>&1; then exit 1; fi
grep -Fq 'complete SSH snapshot is required' "$root/error"
echo 'PASS: capture, protected contents, launcher mounts and failed-capture handling'

cp -a "$old" "$new"
rm -r "$new/etc/ssh" "$new/etc/extra" "$new/private"
cp -a "$snapshot/files/." "$new"
cp -a "$snapshot/checks" "$new/checks"
cp "$repo/verify-ssh-state.sh" "$new/verify"
verify() { chroot "$new" /usr/bin/bash /verify /checks "$@"; }
expect_refusal() {
    local expected=$1
    if verify > "$root/error" 2>&1; then exit 1; fi
    cat "$root/error"
    grep -Fq "$expected" "$root/error"
}
verify --global-only
verify
echo 'PASS: real OpenSSH accepts restored keys, certificate and settings including Match'
chmod 640 "$new/private/custom_key"
expect_refusal 'ownership, permissions or paths differ'
chmod 600 "$new/private/custom_key"
mv "$new/private/custom_key" "$root/preserved"
expect_refusal 'missing or changed'
mv "$root/preserved" "$new/private/custom_key"
printf '\npermitrootlogin yes\n' >> "$new/checks/global.effective"
expect_refusal 'effective SSH settings differ from the snapshot'
cp "$snapshot/checks/global.effective" "$new/checks/global.effective"
sed -i '/^partner:/d' "$new/etc/group"
expect_refusal 'effective SSH settings differ for the saved context'
verify --global-only
echo 'PASS: permissions, missing key, global drift and Match drift block startup'
