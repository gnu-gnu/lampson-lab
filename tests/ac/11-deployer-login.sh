# AC: AC-11
# AC-11: deployer's certificate logs in as operator@host-billing.
since=$(log_mark)
out=$(client_helper deployer login.sh role-operator@billing operator@host-billing 'id -un; hostname')
expect_login AC-11 "deployer -> operator@host-billing" "$out" 1001 host-billing operator "$since" \
  "operator | host-billing"
