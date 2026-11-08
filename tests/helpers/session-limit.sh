#!/usr/bin/env bash
# Runs inside the client container as deployer: session-limit.sh <host>
# With one certificate:
#   1. opens a ControlMaster connection to operator@<host> whose session keeps
#      printing the time, and does not end on its own
#   2. opens a second session over that connection (multiplexed)
#   3. waits for the host to close the connection (up to 120s)
#   4. tries another multiplexed session after that
# Reports:
#   uid=  serial=  first_ts=  last_ts=  end_ts=<when ssh returned>  master_rc=
#   master_err=  mux_before_rc=  mux_after_rc=
#   still_open_after=<s>  only when the host had not closed it by then
set -uo pipefail
host=$1
echo "uid=$(id -u)"
d=$(mktemp -d)
mpid=''
trap 'rm -rf "$d"; [[ -n $mpid ]] && kill "$mpid" 2>/dev/null' EXIT
cert=$(lab-ssh-cert --out "$d/id" role-operator@billing 2>"$d/cert.err") \
  || { echo "issue_error=$(paste -sd' ' "$d/cert.err")"; exit 0; }
ssh-keygen -L -f "$cert" | sed -nE 's/^[[:space:]]*Serial: ([0-9]+)$/serial=\1/p'
mkdir -p -m 0700 "$HOME/.ssh"
o=(-i "$d/id" -o CertificateFile="$cert" -o IdentitiesOnly=yes -o IdentityAgent=none
   -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
   -o UserKnownHostsFile="$d/known_hosts" -o ControlPath="$d/mux")
# (A fresh known_hosts: the throwaway host gets a new host key every run.)

# 1. the master connection
ssh -n "${o[@]}" -o ControlMaster=yes -o ControlPersist=no "operator@${host}" \
  'while :; do date +%s; sleep 1; done' >"$d/session" 2>"$d/session.err" &
mpid=$!
for _ in $(seq 1 100); do [[ -s $d/session ]] && break; sleep 0.1; done
echo "first_ts=$(head -n1 "$d/session")"

# 2. a multiplexed session while the connection is open. -O check first: with
# no master, ControlMaster=no would quietly make a new connection instead.
sleep 2
ssh "${o[@]}" -O check "operator@${host}" 2>/dev/null \
  && ssh -n "${o[@]}" -o ControlMaster=no "operator@${host}" true 2>/dev/null
echo "mux_before_rc=$?"

# 3. wait for the host to close it; after 120s, close it here and say so
for _ in $(seq 1 120); do kill -0 "$mpid" 2>/dev/null || break; sleep 1; done
if kill -0 "$mpid" 2>/dev/null; then
  echo "still_open_after=120"
  kill "$mpid"
fi
wait "$mpid"
echo "master_rc=$?"
echo "end_ts=$(date +%s)"
echo "last_ts=$(tail -n1 "$d/session")"
echo "master_err=$(grep -v '^$' "$d/session.err" | tail -n1)"

# 4. no master left to multiplex over
ssh "${o[@]}" -O check "operator@${host}" 2>/dev/null
echo "mux_after_rc=$?"
