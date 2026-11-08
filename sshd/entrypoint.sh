#!/usr/bin/env bash
# sshd host entrypoint. HOST_GROUP (billing | crm) selects the principals:
# /etc/ssh/auth_principals/<role> = role-<role>@<group> (CONTRACT §5.3).
set -euo pipefail
case ${HOST_GROUP:-} in
  billing | crm) ;;
  *) echo "entrypoint: HOST_GROUP must be billing or crm, got '${HOST_GROUP:-}'" >&2; exit 1 ;;
esac
# Every connection is closed this long after it opened (lab-session-reaper).
[[ ${SESSION_MAX_SECONDS:-} =~ ^[1-9][0-9]*$ ]] \
  || { echo "entrypoint: SESSION_MAX_SECONDS must be a positive number of seconds, got '${SESSION_MAX_SECONDS:-}'" >&2; exit 1; }

# The only user CA sshd trusts: step-ca's SSH user CA, published by bootstrap.
ca=/run/lab-ca/ssh_user_ca.pub
# Count keys as ssh-keygen parses them (a line count misses a last line
# without a newline).
n=$(ssh-keygen -l -f "$ca" 2>/dev/null | wc -l)
[[ $n -eq 1 && $(grep -cv '^[[:space:]]*$' "$ca") -eq 1 ]] \
  || { echo "entrypoint: ${ca} must hold exactly one key, found ${n}" >&2; exit 1; }
install -m 0644 -o root -g root "$ca" /etc/ssh/user_ca.pub

install -d -m 0755 -o root -g root /etc/ssh/auth_principals
rm -f /etc/ssh/auth_principals/*
for role in admin operator readonly; do
  printf 'role-%s@%s\n' "$role" "$HOST_GROUP" >"/etc/ssh/auth_principals/${role}"
  chmod 0644 "/etc/ssh/auth_principals/${role}"
done

key=/etc/ssh/host-keys/ssh_host_ed25519_key
[[ -s $key ]] || ssh-keygen -q -t ed25519 -N '' -C "host-${HOST_GROUP}" -f "$key"

mkdir -p /run/sshd
/usr/sbin/sshd -t
echo "entrypoint: host group ${HOST_GROUP}, user CA $(ssh-keygen -l -f /etc/ssh/user_ca.pub | awk '{print $2}')" >&2
# The reaper stays a child of this process, which becomes sshd. The
# healthcheck fails when it is gone.
/usr/local/bin/lab-session-reaper &
echo $! >/run/lab-session-reaper.pid
exec /usr/sbin/sshd -D -e
