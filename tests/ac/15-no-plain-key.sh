# AC: AC-15
# AC-15: logging in without a lab certificate fails. Checked on the hosts'
# own configuration first (CONTRACT §5.4, §10.5), then by trying:
#   - a plain key, even after it is written into the account's authorized_keys
#     (AuthorizedKeysFile none: that file is never read)
#   - a certificate with the right principal from a CA the hosts do not trust
#     (TrustedUserCAKeys holds only the lab SSH user CA)
# The positive control is the deployer login, so the host is reachable and
# accepts lab certificates in the same run.
ctl=$(client_helper deployer login.sh role-operator@billing operator@host-billing 'id -un')
if [[ $(field rc "$ctl") != 0 ]]; then
  fail AC-15 "precondition: deployer cannot log in as operator@host-billing ($(field err "$ctl"))"
else
  pub=$(field pub "$(client_helper deployer plain-key.sh keygen)")
  $COMPOSE exec -T host-billing bash -c \
    'install -d -m 0700 -o operator -g lab-operator ~operator/.ssh && cat >~operator/.ssh/authorized_keys && chown operator ~operator/.ssh/authorized_keys' <<<"$pub"
  since=$(log_mark)
  out=$(client_helper deployer plain-key.sh plain operator@host-billing)
  $COMPOSE exec -T host-billing bash -c 'rm -rf ~operator/.ssh'
  if [[ -z $pub ]]; then
    fail AC-15 "precondition: could not create a plain key"
  elif [[ $(field rc "$out") == 0 ]]; then
    fail AC-15 "plain key in authorized_keys logged in as operator@host-billing"
  elif [[ $(field err "$out") != *"Permission denied (publickey)"* ]]; then
    fail AC-15 "plain key failed for another reason: $(field err "$out")"
  elif ! logged_line host-billing "$since" "Failed publickey for operator " "ED25519 $(field fp "$out")"; then
    fail AC-15 "plain key refused, but host-billing did not log refusing key $(field fp "$out")"
  else
    pass AC-15 "plain key (also in ~operator/.ssh/authorized_keys) refused for operator@host-billing"
  fi

  since=$(log_mark)
  out=$(client_helper deployer plain-key.sh foreign role-operator@billing operator@host-billing)
  if [[ $(field rc "$out") == 0 ]]; then
    fail AC-15 "certificate from an untrusted CA logged in as operator@host-billing"
  elif [[ $(field err "$out") != *"Permission denied (publickey)"* ]]; then
    fail AC-15 "untrusted-CA certificate failed for another reason: $(field err "$out")"
  elif ! logged_line host-billing "$since" "Failed publickey for operator " "CA ED25519 $(field fp "$out")"; then
    fail AC-15 "untrusted-CA certificate refused, but host-billing did not log a refusal naming CA $(field fp "$out")"
  else
    pass AC-15 "certificate for role-operator@billing from an untrusted CA refused for operator@host-billing"
  fi
fi

client_cleanup=$(client_helper deployer plain-key.sh cleanup)

# Effective sshd settings (sshd -T) on each host, against CONTRACT §5.4, and
# the trusted user CA file: exactly one key, the one step-ca signs with.
served=$($COMPOSE exec -T client sh -c 'step ssh config --roots --ca-url "$STEP_CA_URL" --root "$STEP_CA_ROOT"' 2>/dev/null \
  | $COMPOSE exec -T client ssh-keygen -l -f - 2>/dev/null | awk '{print $2}' | paste -sd, -)
for h in host-billing host-crm; do
  eff=$($COMPOSE exec -T "$h" /usr/sbin/sshd -T 2>/dev/null)
  bad=()
  while read -r k v; do
    got=$(awk -v k="$k" '$1 == k { $1 = ""; sub(/^ /, ""); print }' <<<"$eff")
    [[ $got == "$v" ]] || bad+=("${k}='${got}' want '${v}'")
  done <<'WANT'
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
authorizedkeysfile none
authorizedkeyscommand none
authorizedprincipalscommand none
trustedusercakeys /etc/ssh/user_ca.pub
authorizedprincipalsfile /etc/ssh/auth_principals/%u
permitrootlogin no
allowtcpforwarding yes
loglevel VERBOSE
WANT
  cas=$($COMPOSE exec -T "$h" ssh-keygen -l -f /etc/ssh/user_ca.pub 2>/dev/null | awk '{print $2}' | paste -sd, -)
  lines=$($COMPOSE exec -T "$h" grep -cv '^[[:space:]]*$' /etc/ssh/user_ca.pub)
  [[ -n $served && $cas == "$served" && $lines == 1 ]] \
    || bad+=("user_ca.pub holds '${cas}' (${lines} non-empty lines), step-ca serves '${served}'")
  if ((${#bad[@]})); then
    fail AC-15 "${h}: $(IFS=';'; echo "${bad[*]}")"
  else
    pass AC-15 "${h}: sshd -T matches CONTRACT §5.4; TrustedUserCAKeys is exactly step-ca's SSH user CA (${served})"
  fi
done
