#!/usr/bin/env bash
# Runs inside the client container as the account under test. Logs in with
# lab-login (the CONTRACT §6 path) and runs a command. Reports:
#   uid=<caller uid>   rc=<ssh exit code>   keyid=   serial=   (of the certificate used)
#   out=<remote stdout, lines joined with " | ">   err=<stderr, joined>
# Usage: login.sh <principal> <user@host> <command>
set -uo pipefail
echo "uid=$(id -u)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
lab-login "$1" "$2" "$3" </dev/null >"$d/out" 2>"$d/err"
echo "rc=$?"
line=$(grep -m1 '^lab-login: certificate' "$d/err")
sed -nE 's/.*key id "([^"]*)".*/keyid=\1/p' <<<"$line"
sed -nE 's/.*serial ([0-9]+).*/serial=\1/p' <<<"$line"
echo "out=$(paste -sd'|' "$d/out" | sed 's/|/ | /g')"
echo "err=$(grep -v '^lab-login: certificate\|✔' "$d/err" | sed -E 's/\x1b\[[0-9;]*m//g' | paste -sd' ' -)"
