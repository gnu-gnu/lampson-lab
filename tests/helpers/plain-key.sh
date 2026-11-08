#!/usr/bin/env bash
# Runs inside the client container. Tries to log in without a lab certificate:
#   plain   a plain key pair (prints its public key so a test can plant it in
#           authorized_keys first; run "plain-key.sh keygen" for that)
#   foreign a certificate with a lab principal, signed by a CA the hosts do not trust
# Reports: uid=   rc=<ssh rc>   fp=<key fingerprint>   err=
# Usage: plain-key.sh keygen | plain <user@host> | foreign <principal> <user@host> | cleanup
set -uo pipefail
dir="$HOME/.ac15"
mkdir -p -m 0700 "$dir" "$HOME/.ssh"
try() { # key [cert]
  local -a o=(-n -i "$1" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
              -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  [[ -n ${2:-} ]] && o+=(-o CertificateFile="$2") || o+=(-o CertificateFile=none)
  ssh "${o[@]}" "$3" true 2>"$dir/err"
  echo "rc=$?"
  echo "err=$(paste -sd' ' "$dir/err")"
}
echo "uid=$(id -u)"
case $1 in
  keygen)
    rm -f "$dir/plain" "$dir/plain.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$dir/plain"
    echo "pub=$(cat "$dir/plain.pub")" ;;
  plain)
    echo "fp=$(ssh-keygen -l -f "$dir/plain.pub" | awk '{print $2}')"
    try "$dir/plain" "" "$2" ;;
  cleanup)
    rm -rf "$dir"; echo "cleaned=yes" ;;
  foreign)
    rm -f "$dir"/f*
    ssh-keygen -q -t ed25519 -N '' -C "untrusted CA" -f "$dir/fca"
    ssh-keygen -q -t ed25519 -N '' -f "$dir/fkey"
    ssh-keygen -q -s "$dir/fca" -I "spiffe://lab/client/deployer" -n "$2" -V -1m:+5m -z 4242 "$dir/fkey.pub"
    echo "fp=$(ssh-keygen -l -f "$dir/fca.pub" | awk '{print $2}')"
    try "$dir/fkey" "$dir/fkey-cert.pub" "$3" ;;
esac
