# AC: AC-16
# AC-16: operator may `sudo /usr/local/bin/demo-restart` and nothing else.
# Logged in through deployer's certificate (the real path), with sudo -n so a
# refusal cannot turn into a password prompt.
out=$(client_helper deployer login.sh role-operator@billing operator@host-billing \
  'sudo -n /usr/local/bin/demo-restart; echo "rc=$?"')
if [[ $(field rc "$out") != 0 ]]; then
  fail AC-16 "precondition: deployer cannot log in as operator@host-billing ($(field err "$out"))"
elif [[ $(field out "$out") != "demo-restart: called by operator as root on host-billing | rc=0" ]]; then
  fail AC-16 "sudo demo-restart: '$(field out "$out")' ($(field err "$out"))"
else
  pass AC-16 "operator: sudo /usr/local/bin/demo-restart ran as root, called by operator"
fi

for cmd in "id" "/usr/local/bin/demo-restart --force" "-u admin /usr/local/bin/demo-restart"; do
  out=$(client_helper deployer login.sh role-operator@billing operator@host-billing \
    "sudo -n ${cmd}; echo \"rc=\$?\"")
  if [[ $(field rc "$out") != 0 ]]; then
    fail AC-16 "precondition: login for 'sudo ${cmd}' failed ($(field err "$out"))"
  elif [[ $(field out "$out") != "rc=1" ]]; then
    fail AC-16 "operator: 'sudo ${cmd}' was not refused: '$(field out "$out")'"
  elif [[ $(field err "$out") != *"sudo: a password is required"* && $(field err "$out") != *"not allowed"* ]]; then
    fail AC-16 "operator: 'sudo ${cmd}' failed for an unexpected reason: $(field err "$out")"
  else
    pass AC-16 "operator: 'sudo ${cmd}' refused by sudo ($(field err "$out" | sed -E 's/^.*(sudo: [^.]*).*/\1/'))"
  fi
done

# sudo's own view on each host (as root): operator's rules are exactly the one
# command with no arguments, so the refusals above are "not allowed", not a
# missing password.
for h in host-billing host-crm; do
  rules=$($COMPOSE exec -T "$h" sudo -l -U operator 2>&1 | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')
  if [[ $rules == '(root) NOPASSWD: /usr/local/bin/demo-restart ""' ]]; then
    pass AC-16 "${h}: sudo rules for operator are exactly: ${rules}"
  else
    fail AC-16 "${h}: sudo rules for operator are '${rules}'"
  fi
done

# admin's rule (CONTRACT §5.3: sudo ALL, NOPASSWD). No AC logs in as admin
# (no certificate can carry role-admin@*), so it is checked here as config.
for h in host-billing host-crm; do
  rules=$($COMPOSE exec -T "$h" sudo -l -U admin 2>&1 | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')
  if [[ $rules == '(ALL : ALL) NOPASSWD: ALL' ]]; then
    pass AC-16 "${h}: sudo rules for admin are exactly: ${rules}"
  else
    fail AC-16 "${h}: sudo rules for admin are '${rules}', want '(ALL : ALL) NOPASSWD: ALL'"
  fi
done
