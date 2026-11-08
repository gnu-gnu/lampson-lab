# AC: AC-12
# AC-12: deployer's certificate is refused for operator@host-crm,
# admin@host-billing and readonly@host-billing: sshd finds no authorized
# principal for that certificate. The other role accounts (admin@host-crm,
# readonly@host-crm) are tried too, so every account except
# operator@host-billing is covered. The principals files themselves are
# checked against CONTRACT §5.3. The positive control is AC-11's login in the
# same way, repeated here so this file stands alone.
since=$(log_mark)
ctl=$(client_helper deployer login.sh role-operator@billing operator@host-billing 'id -un')
if [[ $(field rc "$ctl") != 0 ]]; then
  fail AC-12 "precondition: deployer cannot log in as operator@host-billing, so refusals prove nothing ($(field err "$ctl"))"
else
  for t in operator@host-crm admin@host-billing readonly@host-billing admin@host-crm readonly@host-crm; do
    since=$(log_mark)
    out=$(client_helper deployer login.sh role-operator@billing "$t" 'id -un')
    expect_login_denied AC-12 "deployer -> ${t}" "$out" 1001 "${t#*@}" "${t%@*}" "$since"
  done
fi
check_add_user AC-12 deployer role-operator@billing

# Principals files on each host: exactly one file per role account, each
# holding exactly role-<role>@<group> (CONTRACT §5.3).
for row in "host-billing billing" "host-crm crm"; do
  read -r h g <<<"$row"
  got=$($COMPOSE exec -T "$h" sh -c 'for f in /etc/ssh/auth_principals/*; do printf "%s=%s;" "${f##*/}" "$(paste -sd, "$f")"; done')
  want="admin=role-admin@${g};operator=role-operator@${g};readonly=role-readonly@${g};"
  if [[ $got == "$want" ]]; then
    pass AC-12 "${h}: principals files are exactly ${want}"
  else
    fail AC-12 "${h}: principals files are '${got}', want '${want}'"
  fi
done
