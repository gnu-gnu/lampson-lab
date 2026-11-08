#!/usr/bin/env bash
# Runs inside the client container as the account under test.
# Fetches X.509-SVIDs from the SPIRE agent for the current uid and reports:
#   uid=<numeric uid of the caller>
#   fetch=ok|error   fetch_error=<agent message>
#   svid_count=<number of SVIDs the agent returned>
#   uris=<URI SANs of every returned SVID, comma separated>
#   chain=ok|fail    (every SVID verified against the fixed lab root only)
# Usage: svid.sh [retry_seconds]   (retry covers agent entry sync after startup)
set -uo pipefail

echo "uid=$(id -u)"

retry=${1:-0}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

deadline=$((SECONDS + retry))
while :; do
  if out=$(spire-agent api fetch x509 -silent -timeout 5s \
      -socketPath "$SPIRE_AGENT_SOCKET" -write "$dir" 2>&1); then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "fetch=error"
    printf 'fetch_error=%s\n' "$(tr '\n' ' ' <<<"$out")"
    exit 0
  fi
  sleep 1
done

echo "fetch=ok"
shopt -s nullglob
svids=("$dir"/svid.*.pem)
echo "svid_count=${#svids[@]}"

uris=() chain=ok
for svid in "${svids[@]}"; do
  uris+=("$(step certificate inspect --format json "$svid" \
    | jq -r '(.extensions.subject_alt_name.uniform_resource_identifiers // []) | join(",")')")
  step certificate verify "$svid" --roots /etc/lab/root.crt >/dev/null 2>&1 || chain=fail
done
(IFS=,; echo "uris=${uris[*]}")
echo "chain=${chain}"
