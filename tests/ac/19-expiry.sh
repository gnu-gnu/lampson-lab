# AC: AC-19, AC-20
# slow
# AC-19: once a certificate has expired, logging in with it again fails.
# AC-20: a session opened while the certificate was valid stays open after it
#        expires. This documents known OpenSSH behavior (README "인증서 만료와
#        열린 세션"): sshd checks the certificate only at authentication.
# Both use one 1m certificate (the provisioner minimum). The wait is driven by
# the certificate's own validBefore, not a fixed sleep (DECISIONS "P3 전제" 3).
since=$(log_mark)
out=$(client_helper deployer expiry.sh)
serial=$(field serial "$out") vb=$(field valid_before "$out")
if [[ $(field uid "$out") != 1001 || -z $serial || -z $vb ]]; then
  fail AC-19 "precondition: no short-lived certificate for deployer ($(field issue_error "$out"))"
  fail AC-20 "precondition: no short-lived certificate for deployer ($(field issue_error "$out"))"
else
  first=$(field first_ts "$out") last=$(field last_ts "$out") retry=$(field retry_ts "$out")
  # The session must have been accepted with this very certificate.
  if ! logged_line host-billing "$since" "Accepted publickey for operator " "(serial ${serial})"; then
    fail AC-19 "precondition: host-billing has no Accepted line for serial ${serial}"
    fail AC-20 "precondition: host-billing has no Accepted line for serial ${serial}"
  else
    # AC-19
    if ! (( retry > vb )); then
      fail AC-19 "retry at ${retry} was not after validBefore ${vb}"
    elif [[ $(field retry_rc "$out") == 0 ]]; then
      fail AC-19 "expired certificate (serial ${serial}) logged in again at validBefore+$((retry - vb))s"
    elif [[ $(field retry_err "$out") != *"Permission denied (publickey)"* ]]; then
      fail AC-19 "retry failed for another reason: $(field retry_err "$out")"
    elif ! $COMPOSE logs --no-log-prefix --since "$since" host-billing 2>&1 | awk -v s="(serial ${serial})" '
           prev && index($0, "Failed publickey for operator ") && index($0, s) { ok = 1 }
           { prev = index($0, "Certificate invalid: expired") > 0 } END { exit !ok }'; then
      fail AC-19 "retry refused, but host-billing did not log serial ${serial} as an expired certificate"
    else
      pass AC-19 "certificate serial ${serial} expired at ${vb}; new login at validBefore+$((retry - vb))s refused (sshd: Certificate invalid: expired)"
    fi
    # AC-20
    if [[ -z $first || -z $last ]] || ! (( first < vb )); then
      fail AC-20 "the session did not start before the certificate expired (first ${first:-none}, validBefore ${vb})"
    elif [[ $(field session_rc "$out") != 0 ]]; then
      fail AC-20 "the session ended with rc $(field session_rc "$out") (last line at ${last}, validBefore ${vb})"
    elif ! (( last >= vb + 55 )); then
      fail AC-20 "the session stopped at ${last}, only $((last - vb))s after validBefore ${vb}"
    else
      pass AC-20 "session opened at validBefore-$((vb - first))s kept running until validBefore+$((last - vb))s ($(field lines "$out") lines, rc 0)"
    fi
  fi
fi
