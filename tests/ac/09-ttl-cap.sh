# AC: AC-09
# AC-09: deployer asking for a certificate longer than its 5m maximum is
# refused (DECISIONS D-11), whichever way the length is asked for:
#   - a 1h lifetime: longer than deployer's SVID
#   - a 10m window that starts in the past and ends inside the SVID lifetime:
#     refused by the 5m provisioner maximum
control=$(client_helper deployer sshcert.sh role-operator@billing)
if [[ $(field issue "$control") != ok ]]; then
  fail AC-09 "precondition: deployer cannot get its own certificate ($(field issue_error "$control"))"
else
  since=$(log_mark)
  out=$(client_helper deployer sshcert.sh --ttl 1h role-operator@billing)
  expect_denied AC-09 "deployer -> role-operator@billing for 1h" "$out" 1001 "$since" \
    "provisioning credential expiration"
  since=$(log_mark)
  out=$(client_helper deployer sshcert.sh --from -9m --ttl 1m role-operator@billing)
  expect_denied AC-09 "deployer -> role-operator@billing from -9m to +1m (10m)" "$out" 1001 "$since" \
    "is greater than maximum accepted duration for selected provisioner of 5m"
fi
