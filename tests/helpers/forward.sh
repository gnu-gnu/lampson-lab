#!/usr/bin/env bash
# Runs inside the client container as monitor. Logs in to readonly@<host> with
# a lab certificate and asks for a local port forward to the host's own sshd.
# Reports:
#   uid=   session=ok|error (the login itself; the remote command ran)
#   serial=   banner=<what came through the forwarded port, or empty>
#   err=<ssh stderr>
# Usage: forward.sh <host>
set -uo pipefail
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"; kill %1 2>/dev/null' EXIT
cert=$(lab-ssh-cert --out "$d/id" role-readonly@billing 2>/dev/null) || { echo "session=error"; exit 0; }
sed -nE 's/^[[:space:]]*Serial: ([0-9]+)$/serial=\1/p' < <(ssh-keygen -L -f "$cert")
port=$((20000 + RANDOM % 20000))
mkdir -p -m 0700 "$HOME/.ssh"
ssh -n -i "$d/id" -o CertificateFile="$cert" -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  -L "127.0.0.1:${port}:127.0.0.1:22" "readonly@$1" 'echo session-ok; sleep 6' >"$d/out" 2>"$d/err" &
for _ in $(seq 1 50); do grep -q session-ok "$d/out" 2>/dev/null && break; sleep 0.1; done
banner=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port} && head -n 1 <&3" 2>/dev/null | tr -d '\r\n')
wait %1
grep -q session-ok "$d/out" && echo "session=ok" || echo "session=error"
echo "banner=${banner}"
echo "err=$(paste -sd' ' "$d/err")"
