# AC: AC-21
# slow
# AC-21: `make down && make up && make test` run twice in a row gives the same
# result. This test runs exactly that, twice, from the repository root. Inside
# those runs AC-21 itself is skipped (LAB_INSIDE_AC21=1), or it would recurse.
# It tears the running lab down, so it runs late (only AC-22, which needs no
# lab, comes after it) and leaves a freshly built lab behind.
#
# Per cycle:
#   - after `make down`, nothing of the lab is left: no container, volume or
#     network of the compose project (CONTRACT §6 "make down")
#   - after `make up`, the lab root is a new one, so the run really started
#     from nothing
#   - `make test` exits 0 and covers every expected AC except AC-21
# Across cycles: the same per-AC verdicts and the same set of passing checks
# (check labels with serials, fingerprints and times masked).
want=$(grep -vE '^[[:space:]]*(#|$)' tests/expected-acs | grep -vx AC-21 | sort | paste -sd' ' -)
project=com.docker.compose.project=lampson-lab
lab_root_fp() { $COMPOSE exec -T client step certificate fingerprint /etc/lab/root.crt 2>/dev/null; }
labels() { # passing checks of a run, without the values that differ by design
  grep -E '^(AC|EP)-[0-9]+ PASS ' "$1" | sed -E 's/SHA256:[A-Za-z0-9+\/=]+/SHA256:X/g; s/[0-9]+/N/g' | sort
}
declare -A verdicts=() checks=()
for i in 1 2; do
  log=$(mktemp)
  before=$(lab_root_fp)
  if ! make down >"$log" 2>&1 </dev/null; then
    fail AC-21 "cycle ${i}: make down failed: $(tail -n 3 "$log" | paste -sd' ' -)"; rm -f "$log"; continue
  fi
  left="$(docker ps -aq --filter "label=${project}" | wc -l) containers, $(docker volume ls -q --filter "label=${project}" | wc -l) volumes, $(docker network ls -q --filter "label=${project}" | wc -l) networks"
  if [[ $left != "0 containers, 0 volumes, 0 networks" ]]; then
    fail AC-21 "cycle ${i}: after make down ${left} of the lab are left"; rm -f "$log"; continue
  fi
  if ! make up >"$log" 2>&1 </dev/null; then
    fail AC-21 "cycle ${i}: make up failed: $(tail -n 3 "$log" | paste -sd' ' -)"; rm -f "$log"; continue
  fi
  after=$(lab_root_fp)
  if [[ -z $after || $after == "$before" ]]; then
    fail AC-21 "cycle ${i}: the lab root did not change across make down && make up (${before:-none} -> ${after:-none})"
  fi
  LAB_INSIDE_AC21=1 make test >"$log" 2>&1 </dev/null
  rc=$?
  verdicts[$i]=$(grep -E '^(AC|EP)-[0-9]+: (PASS|FAIL)$' "$log" | sort | paste -sd' ' -)
  checks[$i]=$(labels "$log")
  covered=$(grep -E '^(AC|EP)-[0-9]+: (PASS|FAIL)$' "$log" | cut -d: -f1 | sort | paste -sd' ' -)
  if [[ $rc != 0 ]]; then
    fail AC-21 "cycle ${i}: make test exit ${rc}: $(grep -E ' FAIL ' "$log" | head -n 3 | paste -sd';' -)"
  elif [[ $covered != "$want" ]]; then
    fail AC-21 "cycle ${i}: covered '${covered}', want '${want}'"
  else
    pass AC-21 "cycle ${i}: make down left nothing, make up built a new lab root, make test exit 0 with $(wc -l <<<"${checks[$i]}") passing checks"
  fi
  rm -f "$log"
done
if [[ -z ${verdicts[1]:-} || ${verdicts[1]} != "${verdicts[2]:-}" ]]; then
  fail AC-21 "verdicts differ: 1=[${verdicts[1]:-none}] 2=[${verdicts[2]:-none}]"
elif [[ ${checks[1]} != "${checks[2]:-}" ]]; then
  fail AC-21 "passing checks differ: $(diff <(echo "${checks[1]}") <(echo "${checks[2]:-}") | grep '^[<>]' | head -n 4 | paste -sd';' -)"
else
  pass AC-21 "both cycles gave the same verdicts and the same $(wc -l <<<"${checks[1]}") passing checks"
fi
