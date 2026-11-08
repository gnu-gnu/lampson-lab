# AC: AC-14
# AC-14: monitor's `ssh -L` port forward is refused. The server allows TCP
# forwarding (CONTRACT §5.4), so the refusal must come from the certificate,
# which has no permit-port-forwarding extension. Checked: the login works,
# nothing comes through the forwarded port (the target is the host's own sshd,
# which would answer with an SSH banner), and sshd logs the refusal.
fwd=$($COMPOSE exec -T host-billing /usr/sbin/sshd -T 2>/dev/null \
  | awk '$1 == "allowtcpforwarding" || $1 == "disableforwarding" {printf "%s=%s ", $1, $2}')
if [[ $fwd != "allowtcpforwarding=yes disableforwarding=no " && $fwd != "disableforwarding=no allowtcpforwarding=yes " ]]; then
  fail AC-14 "precondition: host-billing sshd does not allow TCP forwarding (${fwd}), so a refusal would not test the certificate"
else
  since=$(log_mark)
  out=$(client_helper monitor forward.sh host-billing)
  if [[ $(field uid "$out") != 1002 ]]; then
    fail AC-14 "ran as uid $(field uid "$out"), want 1002"
  elif [[ $(field session "$out") != ok ]]; then
    fail AC-14 "precondition: monitor could not log in to readonly@host-billing ($(field err "$out"))"
  elif [[ $(field banner "$out") == SSH-* ]]; then
    fail AC-14 "port forward worked: got '$(field banner "$out")' through it"
  elif [[ $(field err "$out") != *"administratively prohibited"* ]]; then
    fail AC-14 "no forwarded data, but ssh did not report a refusal: $(field err "$out")"
  elif ! logged host-billing "$since" "refused local port forward"; then
    fail AC-14 "ssh reported a refusal, but host-billing did not log 'refused local port forward'"
  else
    pass AC-14 "monitor -> readonly@host-billing with -L: session ok, forward refused (administratively prohibited; sshd: refused local port forward)"
  fi
fi
