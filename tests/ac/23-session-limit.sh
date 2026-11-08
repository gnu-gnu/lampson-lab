# AC: EP-11
# slow
# EP-11 (TODO.md, DECISIONS D-21): the hosts close every SSH connection 60
# minutes after it opened, whatever the certificate lifetime. Not a CONTRACT
# AC; AC-20 still holds (a session outlives its certificate, up to the limit).
#
# 1. host-billing and host-crm run lab-session-reaper with a 3600s limit.
# 2. Waiting an hour is not practical, so the behavior is shown on a throwaway
#    host from the same image with a 20s limit, on the lab network: a
#    ControlMaster connection is closed by the host after 20s (plus at most one
#    5s check interval), together with its multiplexed sessions, and the
#    reaper's log line leads back to the certificate serial through sshd's own
#    log.
probe=lampson-lab-session-probe
limit=20 interval=5

# 1. the lab hosts
for svc in host-billing host-crm; do
  c=$($COMPOSE ps -q "$svc")
  env_limit=$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SESSION_MAX_SECONDS=//p')
  if [[ $env_limit != 3600 ]]; then
    fail EP-11 "${svc}: SESSION_MAX_SECONDS is '${env_limit}', not 3600"
  elif ! $COMPOSE exec -T "$svc" sh -c 'kill -0 "$(cat /run/lab-session-reaper.pid)"' 2>/dev/null; then
    fail EP-11 "${svc}: lab-session-reaper is not running"
  # Read the whole log first: grep -q stopping at the (early) start line
  # would make `compose logs` fail with SIGPIPE, and pipefail fail the check.
  elif ! grep -qF "lab-session-reaper: started: connections are closed 3600s after they open" \
         <<<"$($COMPOSE logs --no-log-prefix "$svc" 2>&1)"; then
    fail EP-11 "${svc}: no reaper start line for a 3600s limit"
  else
    pass EP-11 "${svc}: lab-session-reaper running, connections closed 3600s after they open"
  fi
done

# 2. the throwaway host
c=$($COMPOSE ps -q host-billing)
net=$(docker inspect "$c" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
ca_vol=$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/run/lab-ca"}}{{.Name}}{{end}}{{end}}')
docker rm -f -v "$probe" >/dev/null 2>&1
if ! docker run -d --name "$probe" --network "$net" -e HOST_GROUP=billing \
       -e SESSION_MAX_SECONDS=$limit -e SESSION_CHECK_SECONDS=$interval \
       -v "${ca_vol}:/run/lab-ca:ro" --tmpfs /etc/ssh/host-keys:mode=0700 \
       lampson-lab/sshd:local >/dev/null; then
  fail EP-11 "precondition: could not start the throwaway host ${probe}"
else
  for _ in $(seq 1 30); do docker exec "$probe" test -s /run/sshd.pid 2>/dev/null && break; sleep 1; done
  out=$(client_helper deployer session-limit.sh "$probe")
  serial=$(field serial "$out") first=$(field first_ts "$out") last=$(field last_ts "$out") end=$(field end_ts "$out")
  # sshd -e ends its lines with CR LF.
  plog=$(docker logs "$probe" 2>&1 | tr -d '\r')
  # Processes of operator (uid 1001) left on the host: the session's commands.
  left=$(docker exec "$probe" ps -eo uid=,args= | awk '$1 == 1001' | paste -sd';' -)
  closed=$(grep -F "lab-session-reaper: closed connection: user=operator " <<<"$plog" | head -n1)
  child=$(sed -nE 's/.* user-child=([0-9]+) .*/\1/p' <<<"$closed")
  # The serial of the connection whose user child sshd reported as <child>:
  # the last "Accepted publickey" line before "User child is on pid <child>".
  logged_serial=$(awk -v c="User child is on pid ${child}" '
    index($0, "Accepted publickey for operator ") { s = $0; sub(/.*\(serial /, "", s); sub(/\).*/, "", s) }
    $0 == c { print s; exit }' <<<"$plog")
  if [[ $(field uid "$out") != 1001 || -z $serial || -z $first ]]; then
    fail EP-11 "precondition: no session to ${probe} ($(field issue_error "$out")$(field master_err "$out"))"
  elif [[ $(field mux_before_rc "$out") != 0 ]]; then
    fail EP-11 "precondition: no multiplexed session over the open connection (rc $(field mux_before_rc "$out"))"
  elif [[ -n $(field still_open_after "$out") ]]; then
    fail EP-11 "the host had not closed the connection $(field still_open_after "$out")s after it opened (limit ${limit}s)"
  elif [[ $(field master_rc "$out") == 0 || $(field master_err "$out") != *"closed by remote host"* ]]; then
    fail EP-11 "the connection was not closed by the host (rc $(field master_rc "$out"): $(field master_err "$out"))"
  elif ! (( end - first >= limit - 2 && end - first <= limit + interval + 5 )); then
    fail EP-11 "the connection was closed $((end - first))s after its session started, not within ${limit}..$((limit + interval))s"
  elif [[ -n $left ]]; then
    fail EP-11 "the session's processes outlived the connection: ${left}"
  elif [[ $(field mux_after_rc "$out") == 0 ]]; then
    fail EP-11 "a ControlMaster connection was still there after the host closed it"
  elif [[ -z $closed ]]; then
    fail EP-11 "${probe} closed the connection but the reaper logged nothing"
  elif [[ $logged_serial != "$serial" ]]; then
    fail EP-11 "reaper line '${closed}' leads to serial '${logged_serial}', not the certificate's ${serial}"
  else
    pass EP-11 "${limit}s host: connection with certificate serial ${serial} closed $((end - first))s after its session started (reaper: $(sed -nE 's/.* (age=[0-9]+s) .*/\1/p' <<<"$closed"), user child ${child}), its multiplexed sessions with it"
  fi
fi
docker rm -f -v "$probe" >/dev/null 2>&1
