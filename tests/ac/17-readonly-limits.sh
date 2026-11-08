# AC: AC-17
# AC-17: readonly has no sudo at all and cannot read /etc/demo/secret.conf.
# Through monitor's certificate (the real path).
for h in host-billing host-crm; do
  out=$(client_helper monitor login.sh role-readonly@billing "readonly@${h}" '
    for c in true id /usr/local/bin/demo-restart; do sudo -n $c >/dev/null 2>&1; echo "sudo_$c=$?"; done
    sudo -n -l >/dev/null 2>&1; echo "sudo_list=$?"
    stat -c "secret=%U:%G:%a" /etc/demo/secret.conf
    cat /etc/demo/secret.conf >/dev/null 2>&1; echo "read=$?"
    cat /etc/demo/secret.conf 2>&1 >/dev/null | head -n1')
  o=$(field out "$out")
  if [[ $(field rc "$out") != 0 ]]; then
    fail AC-17 "precondition: monitor cannot log in as readonly@${h} ($(field err "$out"))"
  elif [[ $o != *"secret=root:root:600"* ]]; then
    fail AC-17 "precondition: ${h}:/etc/demo/secret.conf is not root:root 0600 ('${o}')"
  elif [[ $o != *"sudo_true=1 | sudo_id=1 | sudo_/usr/local/bin/demo-restart=1 | sudo_list=1"* ]]; then
    fail AC-17 "readonly@${h}: some sudo call was not refused: '${o}'"
  elif [[ $o != *"read=1"* || $o != *"Permission denied"* ]]; then
    fail AC-17 "readonly@${h}: secret.conf read was not refused with Permission denied: '${o}'"
  else
    pass AC-17 "readonly@${h}: every sudo refused (no sudo rights), secret.conf (root:root 0600) Permission denied"
  fi
done

# sudo's own view on each host (as root): readonly has no rule at all.
for h in host-billing host-crm; do
  l=$($COMPOSE exec -T "$h" sudo -l -U readonly 2>&1)
  if [[ $l == "User readonly is not allowed to run sudo on ${h}." ]]; then
    pass AC-17 "${h}: sudo -l -U readonly: not allowed to run sudo"
  else
    fail AC-17 "${h}: sudo -l -U readonly: '${l}'"
  fi
done
