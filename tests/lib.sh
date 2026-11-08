# Shared helpers for acceptance tests. Sourced by tests/run.sh.
# Every check prints one line: "<AC-ID> PASS|FAIL <detail>".

COMPOSE=${COMPOSE:-docker compose}
TESTS_DIR=${TESTS_DIR:-tests}

# Agent SPIFFE IDs embed the (spent) join token; reports are committed, so it is masked.
redact() { sed -E 's#(join_token/)[0-9A-Za-z-]+#\1<token>#g' <<<"$*"; }
pass() { local ac=$1; shift; printf '%s PASS %s\n' "$ac" "$(redact "$*")"; printf '%s PASS\n' "$ac" >>"$RESULTS"; }
fail() { local ac=$1; shift; printf '%s FAIL %s\n' "$ac" "$(redact "$*")"; printf '%s FAIL\n' "$ac" >>"$RESULTS"; }

# Run a script from tests/helpers inside the client container as <user>.
#   client_helper <user> <helper> [args...]
client_helper() {
  local user=$1 helper=$2
  shift 2
  $COMPOSE exec -T -u "$user" client bash -s -- "$@" <"${TESTS_DIR}/helpers/${helper}"
}

spire_server() {
  $COMPOSE exec -T spire-server /opt/spire/bin/spire-server "$@"
}

# Extract "key=value" from helper output.
field() { sed -n "s/^$1=//p" <<<"$2" | head -n 1; }

# Unix selector values that match a client account: uid, user, primary and
# supplementary gid/group.
account_selectors() {
  local user=$1 g
  local -a s
  s=("uid:$($COMPOSE exec -T client id -u "$user")" "user:${user}"
     "gid:$($COMPOSE exec -T client id -g "$user")" "group:$($COMPOSE exec -T client id -gn "$user")")
  for g in $($COMPOSE exec -T client id -G "$user"); do s+=("supplementary_gid:${g}"); done
  for g in $($COMPOSE exec -T client id -Gn "$user"); do s+=("supplementary_group:${g}"); done
  echo "${s[*]}"
}

# SPIFFE IDs (sorted, comma separated) of every server-side entry with a unix
# selector matching <user>. Reads spire-server, not the agent, so an entry the
# agent has not synced yet still counts.
entries_selecting() {
  local sels
  sels=$(account_selectors "$1")
  spire_server entry show -output json | jq -r --arg sels "$sels" '
    ($sels | split(" ")) as $s
    | [(.entries // [])[]
       | select(any(.selectors[]; .type == "unix" and (.value as $v | $s | index($v))))
       | "spiffe://\(.spiffe_id.trust_domain)\(.spiffe_id.path)"] | sort | join(",")'
}

# Like client_helper, with extra environment: client_helper_env "<K=V ...>" <user> <helper> [args...]
client_helper_env() {
  local envs=$1 user=$2 helper=$3 e
  shift 3
  local -a flags=()
  for e in $envs; do flags+=(-e "$e"); done
  $COMPOSE exec -T "${flags[@]}" -u "$user" client bash -s -- "$@" <"${TESTS_DIR}/helpers/${helper}"
}

# step-ca log checks. Failure tests require the reason step-ca logged, so a
# request that failed for an unrelated reason (network, typo) is not a PASS.
log_mark() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }
# logged <service> <since> <text>: <service> logged <text> after <since> (waits up to 5s).
logged() {
  local svc=$1 since=$2 text=$3 i
  for i in 1 2 3 4 5; do
    $COMPOSE logs --no-log-prefix --since "$since" "$svc" 2>&1 | grep -qF -- "$text" && return 0
    sleep 1
  done
  return 1
}

# expect_cert <ac> <label> <sshcert.sh output> <uid> <key id> <principals> <max seconds>
# The certificate must match exactly: user type, key id, principal set,
# extensions = permit-pty only, no critical options, 0 < validity <= max,
# signed by the lab SSH user CA.
expect_cert() {
  local ac=$1 label=$2 out=$3 uid=$4 keyid=$5 principals=$6 max=$7 span
  local -a bad=()
  if [[ $(field uid "$out") != "$uid" ]]; then
    fail "$ac" "${label}: ran as uid $(field uid "$out"), want ${uid}"
    return
  fi
  if [[ $(field issue "$out") != ok ]]; then
    fail "$ac" "${label}: not issued: $(field issue_error "$out")"
    return
  fi
  [[ $(field cert_type "$out") == user ]] || bad+=("type '$(field cert_type "$out")', want user")
  [[ $(field keyid "$out") == "$keyid" ]] || bad+=("key id '$(field keyid "$out")', want '${keyid}'")
  [[ $(field principals "$out") == "$principals" ]] || bad+=("principals '$(field principals "$out")', want '${principals}'")
  [[ $(field extensions "$out") == permit-pty ]] || bad+=("extensions '$(field extensions "$out")', want 'permit-pty'")
  [[ -z $(field critical "$out") ]] || bad+=("critical options '$(field critical "$out")', want none")
  span=$(field span "$out")
  if ! [[ $span =~ ^[0-9]+$ ]] || (( span <= 0 || span > max )); then
    bad+=("validity ${span}s, want 1..${max}s")
  fi
  [[ $(field signer "$out") == ok ]] || bad+=("not signed by the lab SSH user CA")
  if ((${#bad[@]})); then
    fail "$ac" "${label}: $(IFS=';'; echo "${bad[*]}")"
  else
    pass "$ac" "${label}: key id ${keyid}, principals {${principals}}, permit-pty only, valid ${span}s (<= ${max}s), serial $(field serial "$out")"
  fi
}

# expect_denied <ac> <label> <sshcert.sh output> <uid> <since> <step-ca log text>
# Issuance must fail, and step-ca must have logged the expected reason.
expect_denied() {
  local ac=$1 label=$2 out=$3 uid=$4 since=$5 reason=$6
  if [[ $(field uid "$out") != "$uid" ]]; then
    fail "$ac" "${label}: ran as uid $(field uid "$out"), want ${uid}"
  elif [[ $(field issue "$out") == ok ]]; then
    fail "$ac" "${label}: certificate issued (principals {$(field principals "$out")}, key id $(field keyid "$out"))"
  elif ! logged step-ca "$since" "$reason"; then
    fail "$ac" "${label}: refused, but step-ca did not log the expected reason '${reason}' (client: $(field issue_error "$out"))"
  else
    pass "$ac" "${label}: refused; step-ca: ${reason}"
  fi
}

# logged_container <container> <since> <text>: like logged, for a container outside compose.
logged_container() {
  local c=$1 since=$2 text=$3 i
  for i in 1 2 3 4 5; do
    docker logs --since "$since" "$c" 2>&1 | grep -qF -- "$text" && return 0
    sleep 1
  done
  return 1
}

# expect_login <ac> <label> <login.sh output> <uid> <host service> <user> <since> <want out>
# The login must succeed, print <want out>, and sshd must log the Accepted line
# for exactly this certificate (key id and serial).
expect_login() {
  local ac=$1 label=$2 out=$3 uid=$4 host=$5 user=$6 since=$7 want=$8
  local keyid serial
  keyid=$(field keyid "$out") serial=$(field serial "$out")
  if [[ $(field uid "$out") != "$uid" ]]; then
    fail "$ac" "${label}: ran as uid $(field uid "$out"), want ${uid}"
  elif [[ $(field rc "$out") != 0 ]]; then
    fail "$ac" "${label}: login failed (rc $(field rc "$out")): $(field err "$out")"
  elif [[ $(field out "$out") != "$want" ]]; then
    fail "$ac" "${label}: remote output '$(field out "$out")', want '${want}'"
  elif [[ -z $serial ]] || ! logged_line "$host" "$since" "Accepted publickey for ${user} " \
       "ID ${keyid} (serial ${serial})"; then
    fail "$ac" "${label}: ${host} has no Accepted line for ${user} with ID ${keyid} serial ${serial}"
  else
    pass "$ac" "${label}: logged in, '${want}' (certificate serial ${serial})"
  fi
}

# expect_login_denied <ac> <label> <login.sh output> <uid> <host service> <user> <since>
# The login must fail with "Permission denied (publickey)", and sshd must have
# refused exactly this certificate because no principal matched <user>.
expect_login_denied() {
  local ac=$1 label=$2 out=$3 uid=$4 host=$5 user=$6 since=$7 serial
  serial=$(field serial "$out")
  if [[ $(field uid "$out") != "$uid" ]]; then
    fail "$ac" "${label}: ran as uid $(field uid "$out"), want ${uid}"
  elif [[ -z $serial ]]; then
    fail "$ac" "${label}: no certificate was issued, so sshd never judged one: $(field err "$out")"
  elif [[ $(field rc "$out") == 0 ]]; then
    fail "$ac" "${label}: login succeeded (remote output '$(field out "$out")')"
  elif [[ $(field err "$out") != *"Permission denied (publickey)"* ]]; then
    fail "$ac" "${label}: failed for another reason: $(field err "$out")"
  elif ! logged_line "$host" "$since" "Failed publickey for ${user} " "(serial ${serial})" ||
       ! logged "$host" "$since" "Certificate does not contain an authorized principal"; then
    fail "$ac" "${label}: refused, but ${host} did not log a principal refusal for certificate serial ${serial}"
  else
    pass "$ac" "${label}: refused; ${host}: certificate serial ${serial} has no authorized principal for ${user}"
  fi
}

# logged_line <service> <since> <text1> <text2>: one log line contains both.
logged_line() {
  local svc=$1 since=$2 a=$3 b=$4 i
  for i in 1 2 3 4 5; do
    $COMPOSE logs --no-log-prefix --since "$since" "$svc" 2>&1 \
      | awk -v a="$a" -v b="$b" 'index($0, a) && index($0, b) { found = 1 } END { exit !found }' && return 0
    sleep 1
  done
  return 1
}

# check_add_user <ac> <user> <principal>: the add-user certificate step-ca also
# signs for <user> (DECISIONS D-14) logs in nowhere: every role account and
# "provisioner" on both hosts, and root (P3 전제 2).
check_add_user() {
  local ac=$1 user=$2 principal=$3 since out t host svc bad=()
  local -a targets=()
  for host in host-billing host-crm; do
    for t in admin operator readonly provisioner root; do targets+=("${t}@${host}"); done
  done
  since=$(log_mark)
  out=$(client_helper "$user" add-user-login.sh "$principal" "${targets[@]}")
  if [[ $(field addcert "$out") != ok ]]; then
    fail "$ac" "precondition: no add-user certificate for ${user}, so this proves nothing"
    return
  fi
  for t in "${targets[@]}"; do
    [[ $(field "login_${t/@/_}" "$out") == 255 ]] || bad+=("${t} rc=$(field "login_${t/@/_}" "$out")")
  done
  # Each refusal must be in the target host's log: accounts that exist refuse
  # this serial, "provisioner" does not exist on the hosts at all.
  for t in "${targets[@]}"; do
    if [[ ${t%@*} == provisioner ]]; then
      logged "${t#*@}" "$since" "Invalid user provisioner " || bad+=("${t}: no 'Invalid user provisioner' in the log")
    else
      logged_line "${t#*@}" "$since" "Failed publickey for ${t%@*} " "(serial $(field serial "$out"))" \
        || bad+=("${t}: refusal of serial $(field serial "$out") not in the log")
    fi
  done
  if ((${#bad[@]})); then
    fail "$ac" "${user}'s add-user certificate ($(field keyid "$out")): $(IFS=';'; echo "${bad[*]}")"
  else
    pass "$ac" "${user}'s add-user certificate ($(field keyid "$out"), serial $(field serial "$out")) logs in nowhere: ${#targets[@]} targets refused"
  fi
}
