# AC: AC-13
# AC-13: monitor's certificate logs in as readonly on both hosts and is
# refused as operator on both. admin on both hosts is tried too, so every
# role account is covered.
for h in host-billing host-crm; do
  since=$(log_mark)
  out=$(client_helper monitor login.sh role-readonly@billing "readonly@${h}" 'id -un; hostname')
  expect_login AC-13 "monitor -> readonly@${h}" "$out" 1002 "$h" readonly "$since" "readonly | ${h}"
done
for t in operator@host-billing operator@host-crm admin@host-billing admin@host-crm; do
  since=$(log_mark)
  out=$(client_helper monitor login.sh role-readonly@billing "$t" 'id -un')
  expect_login_denied AC-13 "monitor -> ${t}" "$out" 1002 "${t#*@}" "${t%@*}" "$since"
done
check_add_user AC-13 monitor role-readonly@billing
