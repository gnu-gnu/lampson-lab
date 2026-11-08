#!/usr/bin/env bash
# Runs inside the client container (as deployer). Signs one X5C token with the
# caller's SVID and presents it twice. Reports:
#   uid=   token=ok|error   first=ok|error   second=ok|error   second_error=
set -uo pipefail
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
spire-agent api fetch x509 -silent -timeout 10s -socketPath "$SPIRE_AGENT_SOCKET" -write "$d" >/dev/null 2>&1
id=$(step certificate inspect --format json "$d/svid.0.pem" 2>/dev/null \
  | jq -r '.extensions.subject_alt_name.uniform_resource_identifiers[0] // empty')
if ! tok=$(step ca token "$id" --ssh --provisioner x5c-spire --principal role-operator@billing \
    --x5c-cert "$d/svid.0.pem" --x5c-key "$d/svid.0.key" \
    --ca-url "$STEP_CA_URL" --root "$STEP_CA_ROOT" 2>"$d/err"); then
  echo "token=error"; printf 'token_error=%s\n' "$(tr '\n' ' ' <"$d/err")"; exit 0
fi
echo "token=ok"
sign() {
  step ssh certificate "$id" "$d/$1" --token "$tok" --principal role-operator@billing \
    --ca-url "$STEP_CA_URL" --root "$STEP_CA_ROOT" \
    --no-password --insecure --no-agent --force >/dev/null 2>"$d/$1.err"
}
sign k1 && echo "first=ok" || { echo "first=error"; printf 'first_error=%s\n' "$(tr '\n' ' ' <"$d/k1.err")"; }
sign k2 && echo "second=ok" || { echo "second=error"; printf 'second_error=%s\n' "$(tr '\n' ' ' <"$d/k2.err")"; }
