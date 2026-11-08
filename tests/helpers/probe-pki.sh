#!/usr/bin/env bash
# Runs in a throwaway container (bootstrap image) with an empty /probe mounted.
# Reads the lab's ca.json on stdin and writes /probe/ca.json for the AC-05
# policy probe: the same provisioner, roots, claims and policy, but
#   - a throwaway TLS root/intermediate and SSH user CA key (no lab key is used,
#     so nothing the probe signs is trusted by the lab's sshd hosts)
#   - the permissive test template, a scratch DB, its own DNS name
# Prints: ssh_ca_fp=<OpenSSH fingerprint of the throwaway SSH user CA>
set -euo pipefail
cd /probe
q() { "$@" >/dev/null 2>&1; }
q step certificate create "AC-05 probe TLS root" root.crt root.key --profile root-ca \
  --kty EC --curve P-256 --no-password --insecure
q step certificate create "AC-05 probe TLS intermediate" int.crt int.key --profile intermediate-ca \
  --ca root.crt --ca-key root.key --kty EC --curve P-256 --no-password --insecure
q step crypto keypair ssh_user_ca.pem ssh_user_ca.key --kty EC --curve P-256 --no-password --insecure
step crypto key format --ssh ssh_user_ca.pem >ssh_user_ca.pub
jq '.root = "/probe/root.crt" | .crt = "/probe/int.crt" | .key = "/probe/int.key"
  | .ssh.userKey = "/probe/ssh_user_ca.key"
  | .dnsNames = ["step-ca-policy-probe"] | .db.dataSource = "/tmp/probe-db"
  | .authority.provisioners[0].options.ssh.templateFile = "/probe/permissive-ssh.tpl"' >ca.json
chown -R 1000:1000 /probe
echo "ssh_ca_fp=$(step ssh fingerprint ssh_user_ca.pub)"
