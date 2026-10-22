#!/bin/bash
set -euo pipefail
umask 077
config=/run/secrets/accounts
test -f "$config"
# This image has no baked host keys. Every instance owns its persistent key volume.
mkdir -p /data/hostkeys /data/sftp /etc/ssh/authorized_keys /run/sshd
chown root:root /data /data/hostkeys /data/sftp /etc/ssh/authorized_keys
chmod 755 /data /data/sftp /etc/ssh/authorized_keys
chmod 700 /data/hostkeys
if [ ! -s /data/hostkeys/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /data/hostkeys/ssh_host_ed25519_key
fi
chmod 600 /data/hostkeys/ssh_host_ed25519_key
groupadd -f coolops-sftp
jq -e '.version == 1 and (.users | type == "array")' "$config" >/dev/null
while IFS= read -r row; do
    user=$(jq -r '.user' <<<"$row")
    uid=$(jq -r '.uid' <<<"$row")
    gid=$(jq -r '.gid' <<<"$row")
    [[ "$user" =~ ^[a-z][a-z0-9_-]{0,31}$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]]
    (( uid >= 1000 && uid <= 60000 && gid >= 1000 && gid <= 60000 ))
    ! id "$user" >/dev/null 2>&1
    getent group "$gid" >/dev/null || groupadd -g "$gid" "site-$gid"
    useradd -M -u "$uid" -g "$gid" -G coolops-sftp -d /site -s /usr/sbin/nologin "$user"
    hash=$(jq -r '.passwordHash // "!"' <<<"$row")
    [[ "$hash" == '!' || "$hash" =~ ^\$6\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+$ ]]
    # An unlocked account is required for SSH public-key authentication too.
    # '*' is an impossible password hash while allowing public-key authentication.
    [ "$hash" != '!' ] || hash='*'
    usermod -p "$hash" "$user"
    mkdir -p "/data/sftp/$user"
    chown root:root "/data/sftp/$user"
    chmod 755 "/data/sftp/$user"
    test -d "/data/sftp/$user/site"
    jq -r '.keys[]' <<<"$row" >"/etc/ssh/authorized_keys/$user"
    chmod 644 "/etc/ssh/authorized_keys/$user"
done < <(jq -c '.users[] | select(.enabled == true)' "$config")
/usr/sbin/sshd -t
exec /usr/sbin/sshd -D -e
