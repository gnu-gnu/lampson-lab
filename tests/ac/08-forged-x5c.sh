# AC: AC-08
# AC-08: intruder (no SVID) forges an X5C token from its own X.509 certificate
# carrying deployer's SPIFFE ID; step-ca refuses it because the chain does not
# verify against the x5c-spire roots. Also checks that those roots are exactly
# the lab root and that x5c-spire is the only provisioner (CONTRACT §3, §10.5).

svid=$(client_helper intruder svid.sh 0)
if [[ $(field fetch "$svid") == ok ]]; then
  fail AC-08 "precondition: intruder has an SVID ($(field uris "$svid"))"
fi
for mode in self-signed fake-root; do
  since=$(log_mark)
  out=$(client_helper intruder forge-x5c.sh "$mode" spiffe://lab/client/deployer role-operator@billing)
  expect_denied AC-08 "intruder, ${mode} certificate as spiffe://lab/client/deployer" "$out" 1004 "$since" \
    "error verifying x5c certificate chain in token"
done

provs=$($COMPOSE exec -T client step ca provisioner list \
  --ca-url https://step-ca:9000 --root /etc/lab-step-ca/root_ca.crt 2>/dev/null)
names=$(jq -r '[.[] | "\(.type)/\(.name)"] | join(",")' <<<"$provs")
if [[ $names != X5C/x5c-spire ]]; then
  fail AC-08 "provisioners are '${names}', want only X5C/x5c-spire"
else
  roots=$(jq -r '.[0].roots' <<<"$provs" | base64 -d)
  lab_root=$($COMPOSE exec -T client cat /etc/lab/root.crt)
  n=$(grep -c 'BEGIN CERTIFICATE' <<<"$roots")
  if [[ $n != 1 || $roots != "$lab_root" ]]; then
    fail AC-08 "x5c-spire roots are not exactly the lab root (${n} certificate(s))"
  else
    pass AC-08 "x5c-spire is the only provisioner and its roots are exactly the lab root"
  fi
fi
