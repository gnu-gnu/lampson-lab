# AC: AC-02
# AC-02: intruder (uid 1004, not registered) receives no SVID.
# Guards against false positives: the agent must be serving SVIDs to a
# registered account in the same run, and the refusal must be the agent's
# "no identity issued", not a socket or connection error.

control=$(client_helper deployer svid.sh 30)
if [[ $(field fetch "$control") != ok ]]; then
  fail AC-02 "precondition: deployer cannot fetch an SVID, so a refusal for intruder proves nothing ($(field fetch_error "$control"))"
else
  out=$(client_helper intruder svid.sh 0)
  err=$(field fetch_error "$out")
  if [[ $(field uid "$out") != 1004 ]]; then
    fail AC-02 "intruder runs as uid $(field uid "$out"), want 1004"
  elif [[ $(field fetch "$out") == ok ]]; then
    fail AC-02 "intruder received an SVID: $(field uris "$out")"
  elif [[ $err != *PermissionDenied* || $err != *"no identity issued"* ]]; then
    fail AC-02 "intruder fetch failed for an unexpected reason: ${err}"
  else
    pass AC-02 "intruder refused by the agent: PermissionDenied, no identity issued"
  fi
fi

# No entry may select intruder by any unix selector: uid, user name, primary
# or supplementary gid/group.
matches=$(entries_selecting intruder)
if [[ -z $matches ]]; then
  pass AC-02 "no SPIRE entry selects intruder ($(account_selectors intruder | sed 's/ /, /g'))"
else
  fail AC-02 "SPIRE entries select intruder: ${matches}"
fi
