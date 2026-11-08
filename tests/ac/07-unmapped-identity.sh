# AC: AC-07
# AC-07: stranger has a valid SVID but no SSH mapping, so it is refused for
# any principal. (The SVID precondition makes sure the refusal is about the
# mapping, not a missing SVID.)
svid=$(client_helper stranger svid.sh 30)
if [[ $(field fetch "$svid") != ok || $(field uris "$svid") != spiffe://lab/client/stranger ]]; then
  fail AC-07 "precondition: stranger has no SVID spiffe://lab/client/stranger ($(field fetch_error "$svid"))"
else
  for p in role-operator@billing role-readonly@crm; do
    since=$(log_mark)
    out=$(client_helper stranger sshcert.sh "$p")
    expect_denied AC-07 "stranger -> ${p}" "$out" 1003 "$since" \
      "x5c-spire: spiffe://lab/client/stranger has no SSH mapping"
  done
fi

# SPIRE's own identities chain to the same lab root as workload SVIDs
# (DECISIONS "P2 전제" 3): the agent's real SVID and key, and a server-ID leaf
# signed by the real SPIRE CA key. They are read from the SPIRE volumes
# (read-only) and used only inside a throwaway container; the refusal reason
# "has no SSH mapping" also shows the chain itself was accepted.
vol_at() { docker inspect --format "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$($COMPOSE ps -aq "$1")"; }
agent_vol=$(vol_at spire-agent /opt/spire/data)
server_vol=$(vol_at spire-server /opt/spire/data)
root_vol=$(vol_at client /etc/lab)
public_vol=$(vol_at client /etc/lab-step-ca)
stepca_id=$($COMPOSE ps -q step-ca)
network=$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$stepca_id" | awk '{print $1}')
bootstrap_image=$(docker inspect --format '{{.Config.Image}}' "$($COMPOSE ps -aq bootstrap)")
for who in agent server; do
  since=$(log_mark)
  out=$(docker run --rm --network "$network" --entrypoint bash \
    -v "${agent_vol}:/agent:ro" -v "${server_vol}:/server:ro" \
    -v "${root_vol}:/lab-root:ro" -v "${public_vol}:/step-public:ro" \
    -v "$(pwd)/${TESTS_DIR}/helpers/spire-identity.sh:/spire-identity.sh:ro" \
    "$bootstrap_image" /spire-identity.sh "$who" role-operator@billing 2>&1)
  sid=$(field id "$out")
  if [[ -n $(field error "$out") || -z $sid ]]; then
    fail AC-07 "precondition: no SPIRE ${who} credential on the lab chain: $(field error "$out")"
    continue
  fi
  expect_denied AC-07 "SPIRE ${who} identity ${sid} -> role-operator@billing" "uid=0
${out}" 0 "$since" "x5c-spire: ${sid} has no SSH mapping"
done
