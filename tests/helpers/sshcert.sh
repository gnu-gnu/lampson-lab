#!/usr/bin/env bash
# Runs inside the client container as the account under test.
# Requests an SSH certificate through lab-ssh-cert (the same path lab-login
# uses) and reports what was issued, as parsed from `ssh-keygen -L`:
#   uid=<caller uid>
#   issue=ok|error   issue_error=<client-side error text>
#   cert_type=user|host   keyid=<Key ID>   serial=<serial>
#   principals=<sorted, comma separated>
#   extensions=<sorted, comma separated>   critical=<sorted, comma separated, or empty>
#   span=<ValidBefore - ValidAfter, seconds>
#   signer=ok|mismatch   (signing CA is the lab's SSH user CA)
# Usage: sshcert.sh [--ttl <duration>] [--from <time>] <principal>...  (passed to lab-ssh-cert)
set -uo pipefail

echo "uid=$(id -u)"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

if ! cert=$(lab-ssh-cert --out "${dir}/id" "$@" 2>"${dir}/err"); then
  echo "issue=error"
  printf 'issue_error=%s\n' "$(tr '\n' ' ' <"${dir}/err")"
  exit 0
fi
echo "issue=ok"

info=$(ssh-keygen -L -f "$cert")
section() { # values under "<Name>:" (same line or indented below) until the next "Name:"
  awk -v h="$1" '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    index(line, h ":") == 1 {
      on = 1; rest = substr(line, length(h) + 2); gsub(/^[ \t]+/, "", rest)
      if (rest != "" && rest != "(none)") print rest
      next
    }
    on && line ~ /^[A-Z][A-Za-z ]*:/ { on = 0 }
    on && line != "" { print line }
  ' <<<"$info" | sort | paste -sd, -
}
type=$(sed -nE 's/^[[:space:]]*Type: .* (user|host) certificate$/\1/p' <<<"$info")
keyid=$(sed -nE 's/^[[:space:]]*Key ID: "(.*)"$/\1/p' <<<"$info")
serial=$(sed -nE 's/^[[:space:]]*Serial: ([0-9]+)$/\1/p' <<<"$info")
from=$(sed -nE 's/^[[:space:]]*Valid: from ([^ ]+) to ([^ ]+)$/\1/p' <<<"$info")
to=$(sed -nE 's/^[[:space:]]*Valid: from ([^ ]+) to ([^ ]+)$/\2/p' <<<"$info")
echo "cert_type=${type}"
echo "keyid=${keyid}"
echo "serial=${serial}"
echo "principals=$(section Principals)"
echo "extensions=$(section Extensions)"
echo "critical=$(section 'Critical Options')"
if [[ -n $from && -n $to ]]; then
  echo "span=$(($(date -u -d "$to" +%s) - $(date -u -d "$from" +%s)))"
else
  echo "span=unknown"
fi
ca=$(sed -nE 's/^[[:space:]]*Signing CA: [A-Z0-9-]+ (SHA256:[^ ]+) .*/\1/p' <<<"$info")
want=$(ssh-keygen -l -f /etc/lab-step-ca/ssh_user_ca.pub | awk '{print $2}')
[[ -n $ca && $ca == "$want" ]] && echo "signer=ok" || echo "signer=mismatch"
