# AC: AC-10
# AC-10: the same X5C token presented twice: the first request succeeds, the
# second is refused because step-ca has already recorded the token.
since=$(log_mark)
out=$(client_helper deployer token-reuse.sh)
if [[ $(field uid "$out") != 1001 ]]; then
  fail AC-10 "ran as uid $(field uid "$out"), want 1001"
elif [[ $(field token "$out") != ok ]]; then
  fail AC-10 "could not create a token: $(field token_error "$out")"
elif [[ $(field first "$out") != ok ]]; then
  fail AC-10 "precondition: first use of the token failed: $(field first_error "$out")"
elif [[ $(field second "$out") == ok ]]; then
  fail AC-10 "second use of the same token was accepted"
elif ! logged step-ca "$since" "token already used"; then
  fail AC-10 "second use refused, but step-ca did not log 'token already used' (client: $(field second_error "$out"))"
else
  pass AC-10 "first use accepted, second use refused: token already used"
fi
