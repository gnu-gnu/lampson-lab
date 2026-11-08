# AC: AC-05
# AC-05: role-admin@* is never issued through x5c-spire, by two independent
# barriers (CONTRACT §5.2):
#   1. the template refuses it (checked against the real step-ca)
#   2. the policy denies it even when the template would issue it: checked
#      against a throwaway step-ca with the same ca.json, keys (read-only) and
#      policy but a template that signs whatever principals are requested.

control=$(client_helper deployer sshcert.sh role-operator@billing)
if [[ $(field issue "$control") != ok ]]; then
  fail AC-05 "precondition: deployer cannot get its own certificate, so refusals prove nothing ($(field issue_error "$control"))"
else
  for req in role-admin@billing role-admin@crm "role-operator@billing role-admin@billing"; do
    since=$(log_mark)
    # shellcheck disable=SC2086
    out=$(client_helper deployer sshcert.sh $req)
    first_admin=$(tr ' ' '\n' <<<"$req" | grep -m1 '^role-admin@')
    expect_denied AC-05 "template: deployer -> {${req// /,}}" "$out" 1001 "$since" \
      "x5c-spire: ${first_admin} is never issued"
  done
fi

# --- policy alone ---------------------------------------------------------
# step-ca reports allow-list misses and deny-list hits with the same message,
# so the explicit deny of CONTRACT §5.2 is also checked in the running config.
deny=$($COMPOSE exec -T step-ca cat /home/step/config/ca.json \
  | jq -r '[.authority.policy.ssh.user.deny.email // [] | .[]] | sort | join(",")')
allow_admin=$($COMPOSE exec -T step-ca cat /home/step/config/ca.json \
  | jq -r '[.authority.policy.ssh.user.allow.email // [] | .[] | select(startswith("role-admin@"))] | join(",")')
if [[ $deny != *role-admin@billing* || $deny != *role-admin@crm* || -n $allow_admin ]]; then
  fail AC-05 "policy: deny list is '${deny}' (want role-admin@billing and role-admin@crm), allow has '${allow_admin}'"
else
  pass AC-05 "policy: deny lists role-admin@billing and role-admin@crm, allow lists no role-admin@"
fi

# The probe has its own throwaway PKI (tests/helpers/probe-pki.sh), so what it
# signs is not trusted by anything in the lab, and it runs on its own internal
# network that only the client joins for the duration of this test.
probe=lampson-lab-step-ca-policy-probe
probe_net=lampson-lab-policy-probe
probe_dir=$(mktemp -d)
client_id=$($COMPOSE ps -q client)
cleanup_probe() {
  docker network disconnect "$probe_net" "$client_id" >/dev/null 2>&1
  docker rm -f -v "$probe" >/dev/null 2>&1
  docker network rm "$probe_net" >/dev/null 2>&1
  $COMPOSE exec -T client rm -f /tmp/ac05-probe-root.crt >/dev/null 2>&1
  rm -rf "$probe_dir"
}
trap cleanup_probe EXIT

image=$(docker inspect --format '{{.Config.Image}}' "$($COMPOSE ps -q step-ca)")
bootstrap_image=$(docker inspect --format '{{.Config.Image}}' "$($COMPOSE ps -aq bootstrap)")
cp "${TESTS_DIR}/fixtures/permissive-ssh.tpl" "${probe_dir}/permissive-ssh.tpl"
pki=$($COMPOSE exec -T step-ca cat /home/step/config/ca.json \
  | docker run --rm -i --network none --entrypoint bash -v "${probe_dir}:/probe" \
      -v "$(pwd)/${TESTS_DIR}/helpers/probe-pki.sh:/probe-pki.sh:ro" \
      "$bootstrap_image" /probe-pki.sh 2>&1)
probe_fp=$(field ssh_ca_fp "$pki")
lab_fp=$($COMPOSE exec -T client ssh-keygen -l -f /etc/lab-step-ca/ssh_user_ca.pub | awk '{print $2}')

ready=0
if [[ -n $probe_fp && $probe_fp != "$lab_fp" ]]; then
  docker network create --internal "$probe_net" >/dev/null
  # The step-ca image declares VOLUME /home/step; a tmpfs there keeps docker
  # from creating an anonymous volume for every run.
  docker run -d --name "$probe" --network "$probe_net" --network-alias step-ca-policy-probe \
    --tmpfs /home/step -v "${probe_dir}:/probe:ro" "$image" /usr/local/bin/step-ca /probe/ca.json >/dev/null
  docker network connect "$probe_net" "$client_id"
  # Written by client root through stdin: it has no capabilities, so it could
  # neither read nor chmod a file copied in with another owner.
  $COMPOSE exec -T client sh -c 'umask 022; cat >/tmp/ac05-probe-root.crt' <"${probe_dir}/root.crt"
  for _ in $(seq 1 30); do
    if $COMPOSE exec -T client step ca health --ca-url https://step-ca-policy-probe:9000 \
        --root /tmp/ac05-probe-root.crt >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
fi
probe_env="STEP_CA_URL=https://step-ca-policy-probe:9000 STEP_CA_ROOT=/tmp/ac05-probe-root.crt"

if [[ -z $probe_fp || $probe_fp == "$lab_fp" ]]; then
  fail AC-05 "policy probe: no throwaway SSH user CA (${pki:0:200})"
elif (( ! ready )); then
  fail AC-05 "policy probe step-ca did not start: $(docker logs "$probe" 2>&1 | tail -n 3 | tr '\n' ' ')"
else
  # The probe must really be permissive, or a refusal below would prove nothing:
  # it signs a principal outside the deployer mapping that the policy allows.
  ctl=$(client_helper_env "$probe_env" deployer sshcert.sh role-readonly@crm)
  if [[ $(field issue "$ctl") != ok || $(field principals "$ctl") != role-readonly@crm ]]; then
    fail AC-05 "precondition: probe template is not permissive (issue=$(field issue "$ctl") principals=$(field principals "$ctl") $(field issue_error "$ctl"))"
  elif [[ $(field signer "$ctl") != mismatch ]]; then
    fail AC-05 "precondition: the probe signed with the lab SSH user CA; it must use a throwaway key"
  else
    # role-admin@* is on the deny list; role-operator@crm is simply not on the allow list.
    for p in role-admin@billing role-admin@crm role-operator@crm; do
      since=$(log_mark)
      out=$(client_helper_env "$probe_env" deployer sshcert.sh "$p")
      if [[ $(field issue "$out") == ok ]]; then
        fail AC-05 "policy: permissive template + policy issued ${p}"
      elif ! logged_container "$probe" "$since" "email name \\\"${p}\\\" not allowed"; then
        fail AC-05 "policy: ${p} refused, but the probe did not log the policy denial (client: $(field issue_error "$out"))"
      else
        pass AC-05 "policy: ${p} denied with a permissive template; step-ca: email name \"${p}\" not allowed"
      fi
    done
  fi
fi
cleanup_probe
trap - EXIT
