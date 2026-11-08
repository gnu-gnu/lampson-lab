# AC: AC-01
# AC-01: deployer, monitor, stranger receive an SVID whose SPIFFE ID matches
# CONTRACT §5.1. Expected uids and IDs are written here from the contract, not
# read from the bootstrap config or the image, so a wrong mapping fails the test.
# Each account must get exactly one SVID: an extra identity for the same uid
# also violates §5.1.

ac01_expect=(
  "deployer 1001 spiffe://lab/client/deployer"
  "monitor  1002 spiffe://lab/client/monitor"
  "stranger 1003 spiffe://lab/client/stranger"
)

for row in "${ac01_expect[@]}"; do
  read -r user want_uid want <<<"$row"
  out=$(client_helper "$user" svid.sh 30)
  if [[ $(field uid "$out") != "$want_uid" ]]; then
    fail AC-01 "${user}: uid $(field uid "$out"), want ${want_uid}"
  elif [[ $(field fetch "$out") != ok ]]; then
    fail AC-01 "${user}: no SVID ($(field fetch_error "$out"))"
  elif [[ $(field svid_count "$out") != 1 ]]; then
    fail AC-01 "${user}: $(field svid_count "$out") SVIDs ($(field uris "$out")), want exactly 1"
  elif [[ $(field uris "$out") != "$want" ]]; then
    fail AC-01 "${user}: SPIFFE ID '$(field uris "$out")', want '${want}'"
  elif [[ $(field chain "$out") != ok ]]; then
    fail AC-01 "${user}: ${want} does not chain to the lab root"
  else
    pass AC-01 "${user} (uid ${want_uid}): exactly one SVID, ${want}, chains to the lab root"
  fi
done

# The server's own entries must agree: exactly one entry selects each account,
# by any unix selector. This catches a change the agent has not synced yet.
for row in "${ac01_expect[@]}"; do
  read -r user want_uid want <<<"$row"
  got=$(entries_selecting "$user")
  if [[ $got == "$want" ]]; then
    pass AC-01 "${user}: spire-server has exactly one entry selecting it, ${want}"
  else
    fail AC-01 "${user}: spire-server entries selecting it are '${got}', want exactly '${want}'"
  fi
done
