#!/usr/bin/env bash
# Runs inside the client container (as intruder). Builds an X5C token from a
# certificate that does not chain to the lab root and asks step-ca for an SSH
# certificate with it. Reports:
#   uid=<caller uid>   issue=ok|error   issue_error=<client-side error>
# Usage: forge-x5c.sh self-signed|fake-root <spiffe id> <principal>
#   self-signed  leaf signed by itself, carrying the SPIFFE ID
#   fake-root    leaf under a new root named exactly like the lab root
set -uo pipefail
mode=$1 id=$2 principal=$3
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cd "$d" || exit 1
q() { "$@" >/dev/null 2>&1; }
case $mode in
  self-signed)
    q step certificate create "$id" leaf.crt leaf.key --profile self-signed --subtle \
      --san "$id" --kty EC --curve P-256 --not-after 5m --no-password --insecure ;;
  fake-root)
    q step certificate create "Lampson Lab Root CA" root.crt root.key --profile root-ca \
      --kty EC --curve P-256 --no-password --insecure
    q step certificate create "$id" leaf.crt leaf.key --profile leaf --ca root.crt --ca-key root.key \
      --san "$id" --kty EC --curve P-256 --not-after 5m --bundle --no-password --insecure ;;
  *) echo "issue=error"; echo "issue_error=bad mode"; exit 0 ;;
esac
[[ -s leaf.crt ]] || { echo "issue=error"; echo "issue_error=could not create the forged certificate"; exit 0; }
if step ssh certificate "$id" id --principal "$principal" --provisioner x5c-spire \
    --x5c-cert leaf.crt --x5c-key leaf.key --ca-url "$STEP_CA_URL" --root "$STEP_CA_ROOT" \
    --no-password --insecure --no-agent --force >out 2>err; then
  echo "issue=ok"
else
  echo "issue=error"
  printf 'issue_error=%s\n' "$(tr '\n' ' ' <err)"
fi
