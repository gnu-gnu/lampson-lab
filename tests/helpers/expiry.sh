#!/usr/bin/env bash
# Runs inside the client container as deployer. With one short-lived (1m)
# certificate:
#   1. opens a session to operator@host-billing that keeps printing the time
#      for well past the certificate's expiry
#   2. once the certificate has expired (by its own validBefore), tries a new
#      login with the same certificate
# Reports:
#   uid=  serial=  valid_before=<epoch>  first_ts=<first line from the session>
#   retry_ts=<epoch of the new login>  retry_rc=  retry_err=
#   session_rc=  last_ts=<last line from the session>  lines=<lines received>
set -uo pipefail
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"; kill %1 2>/dev/null' EXIT
cert=$(lab-ssh-cert --ttl 1m --out "$d/id" role-operator@billing 2>"$d/cert.err") \
  || { echo "issue_error=$(paste -sd' ' "$d/cert.err")"; exit 0; }
info=$(ssh-keygen -L -f "$cert")
sed -nE 's/^[[:space:]]*Serial: ([0-9]+)$/serial=\1/p' <<<"$info"
to=$(sed -nE 's/^[[:space:]]*Valid: from [^ ]+ to ([^ ]+)$/\1/p' <<<"$info")
vb=$(date -u -d "$to" +%s)
echo "valid_before=${vb}"
mkdir -p -m 0700 "$HOME/.ssh"
o=(-i "$d/id" -o CertificateFile="$cert" -o IdentitiesOnly=yes -o IdentityAgent=none
   -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# 1. a session that outlives the certificate by about a minute
end=$((vb + 60))
ssh -n "${o[@]}" operator@host-billing \
  "while [ \$(date +%s) -lt ${end} ]; do date +%s; sleep 5; done; date +%s" >"$d/session" 2>"$d/session.err" &
for _ in $(seq 1 100); do [[ -s $d/session ]] && break; sleep 0.1; done
echo "first_ts=$(head -n1 "$d/session")"

# 2. a new login with the same certificate after it has expired
while (( $(date +%s) < vb + 5 )); do sleep 1; done
echo "retry_ts=$(date +%s)"
ssh -n "${o[@]}" operator@host-billing true 2>"$d/retry.err"
echo "retry_rc=$?"
echo "retry_err=$(paste -sd' ' "$d/retry.err")"

wait %1
echo "session_rc=$?"
echo "last_ts=$(tail -n1 "$d/session")"
echo "lines=$(wc -l <"$d/session")"
