#!/usr/bin/env bash
# Runs inside the client container as deployer or monitor. Gets the side
# "add-user" certificate step-ca signs when asked (DECISIONS D-14) and tries
# every given user@host with it. Reports:
#   uid=   addcert=ok|error   serial=   keyid=   then per target: login_<user>_<host>=<ssh rc>
# Usage: add-user-login.sh <principal> <user@host>...
set -uo pipefail
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
spire-agent api fetch x509 -silent -timeout 10s -socketPath "$SPIRE_AGENT_SOCKET" -write "$d" >/dev/null 2>&1
id=$(step certificate inspect --format json "$d/svid.0.pem" 2>/dev/null \
  | jq -r '.extensions.subject_alt_name.uniform_resource_identifiers[0] // empty')
p=$1; shift
step ssh certificate "$id" "$d/k" --add-user --principal "$p" --provisioner x5c-spire \
  --x5c-cert "$d/svid.0.pem" --x5c-key "$d/svid.0.key" --ca-url "$STEP_CA_URL" --root "$STEP_CA_ROOT" \
  --no-password --insecure --no-agent --force >/dev/null 2>&1
cert="$d/k-provisioner-cert.pub"
if [[ ! -s $cert ]]; then echo "addcert=error"; exit 0; fi
echo "addcert=ok"
info=$(ssh-keygen -L -f "$cert")
sed -nE 's/^[[:space:]]*Serial: ([0-9]+)$/serial=\1/p' <<<"$info"
sed -nE 's/^[[:space:]]*Key ID: "(.*)"$/keyid=\1/p' <<<"$info"
mkdir -p -m 0700 "$HOME/.ssh"
for t in "$@"; do
  ssh -n -i "$d/k-provisioner" -o CertificateFile="$cert" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$t" true >/dev/null 2>&1
  echo "login_${t/@/_}=$?"
done
