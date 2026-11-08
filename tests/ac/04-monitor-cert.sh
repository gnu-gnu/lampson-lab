# AC: AC-04
# AC-04: monitor gets the readonly certificate: both principals of CONTRACT
# §5.2, validity <= 15m. Asking for one of them or for both yields the same set.
want="role-readonly@billing,role-readonly@crm"
for req in "role-readonly@billing" "role-readonly@crm" "role-readonly@billing role-readonly@crm"; do
  # shellcheck disable=SC2086 # one principal per word
  out=$(client_helper monitor sshcert.sh $req)
  expect_cert AC-04 "monitor -> {${req// /,}}" "$out" 1002 spiffe://lab/client/monitor "$want" 900
done
