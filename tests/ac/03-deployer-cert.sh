# AC: AC-03
# AC-03: deployer asking for role-operator@billing gets exactly the certificate
# of CONTRACT §5.2 (values written here from the contract).
out=$(client_helper deployer sshcert.sh role-operator@billing)
expect_cert AC-03 "deployer -> role-operator@billing" "$out" 1001 \
  spiffe://lab/client/deployer role-operator@billing 300
