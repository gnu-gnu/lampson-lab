# AC: AC-06
# AC-06: deployer asking for role-operator@crm (right role, wrong host group)
# is refused. So is a principal mapped only to another identity.
control=$(client_helper deployer sshcert.sh role-operator@billing)
if [[ $(field issue "$control") != ok ]]; then
  fail AC-06 "precondition: deployer cannot get its own certificate ($(field issue_error "$control"))"
else
  for p in role-operator@crm role-readonly@billing; do
    since=$(log_mark)
    out=$(client_helper deployer sshcert.sh "$p")
    expect_denied AC-06 "deployer -> ${p}" "$out" 1001 "$since" \
      "x5c-spire: ${p} is not mapped for spiffe://lab/client/deployer"
  done
fi
