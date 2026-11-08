#!/usr/bin/env bash
# Runs in a throwaway container (bootstrap image) on the lab network, with the
# SPIRE agent and server data volumes, the lab root and step-ca's public files
# mounted read-only. Builds an X.509 credential for one of SPIRE's own
# identities on its real chain, and asks x5c-spire for an SSH certificate with
# it. The credential stays inside this container; nothing is written elsewhere.
#   agent   the agent's SVID and key exactly as the agent stores them
#   server  a leaf for spiffe://lab/spire/server signed by the SPIRE CA key, the
#           way spire-server signs its own SVID (that one is kept only in memory)
# Prints: id=<SPIFFE ID>  issue=ok|error  issue_error=<client text>, or error=<why>
# Usage: spire-identity.sh agent|server <principal>
set -uo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
data=/agent/agent/agent-data.json
n=$(jq -r '.svid | length' "$data" 2>/dev/null)
[[ $n =~ ^[0-9]+$ ]] && ((n >= 2)) || { echo "error=no agent SVID chain in agent-data.json"; exit 0; }
for i in $(seq 0 $((n - 1))); do jq -r ".svid[$i]" "$data" | base64 -d >"$d/c$i.pem"; done

# PEM key from SPIRE's KeyManager "disk" file (base64 PKCS#8 DER per key id).
key_pem() { # keys.json id out
  { echo "-----BEGIN PRIVATE KEY-----"; jq -r --arg k "$2" '.keys[$k]' "$1" | fold -w 64; echo "-----END PRIVATE KEY-----"; } >"$3"
}
# Find the key in keys.json whose public key is the one in <cert>.
matching_key() { # keys.json cert out
  local k want
  want=$(step certificate key "$2")
  for k in $(jq -r '.keys | keys[]' "$1"); do
    key_pem "$1" "$k" "$3"
    [[ $(step crypto key public "$3" 2>/dev/null) == "$want" ]] && return 0
  done
  return 1
}

case ${1:-} in
  agent)
    matching_key /agent/agent/keys.json "$d/c0.pem" "$d/key.pem" || { echo "error=agent SVID key not found"; exit 0; }
    id=$(step certificate inspect --format json "$d/c0.pem" | jq -r '.extensions.subject_alt_name.uniform_resource_identifiers[0]')
    cat "$d"/c*.pem >"$d/chain.pem" ;;
  server)
    # c1 is the SPIRE CA that signed the agent SVID; its key is in the server's keys.json.
    matching_key /server/server/keys.json "$d/c1.pem" "$d/ca.key" || { echo "error=SPIRE CA key for the current CA cert not found"; exit 0; }
    id=spiffe://lab/spire/server
    step certificate create "$id" "$d/leaf.pem" "$d/key.pem" --profile leaf \
      --ca "$d/c1.pem" --ca-key "$d/ca.key" --san "$id" --not-after 5m \
      --kty EC --curve P-256 --no-password --insecure >/dev/null 2>&1 \
      || { echo "error=could not sign a server leaf"; exit 0; }
    cat "$d/leaf.pem" "$d"/c[1-9]*.pem >"$d/chain.pem" ;;
  *) echo "error=usage: spire-identity.sh agent|server"; exit 0 ;;
esac
step certificate verify "$d/chain.pem" --roots /lab-root/root.crt >/dev/null 2>&1 \
  || { echo "error=${id} does not chain to the lab root"; exit 0; }
echo "id=${id}"
if step ssh certificate "$id" "$d/ssh" --principal "${2:?principal}" --provisioner x5c-spire \
    --x5c-cert "$d/chain.pem" --x5c-key "$d/key.pem" \
    --ca-url https://step-ca:9000 --root /step-public/root_ca.crt \
    --no-password --insecure --no-agent --force >/dev/null 2>"$d/err"; then
  echo "issue=ok"
else
  echo "issue=error"
  printf 'issue_error=%s\n' "$(tr '\n' ' ' <"$d/err")"
fi
