# AC: AC-18
# AC-18: sshd's Accepted line carries the certificate's KeyID (the SPIFFE ID)
# and serial. The serial is the one lab-login reported for the certificate it
# just used; the KeyID must be the SPIFFE ID from CONTRACT §5.1.
for row in "deployer role-operator@billing operator@host-billing spiffe://lab/client/deployer" \
           "monitor role-readonly@crm readonly@host-crm spiffe://lab/client/monitor"; do
  read -r user p t want <<<"$row"
  since=$(log_mark)
  out=$(client_helper "$user" login.sh "$p" "$t" true)
  host=${t#*@} serial=$(field serial "$out")
  line=$($COMPOSE logs --no-log-prefix --since "$since" "$host" 2>&1 | grep -m1 "Accepted publickey for ${t%@*} ")
  if [[ $(field rc "$out") != 0 ]]; then
    fail AC-18 "precondition: ${user} cannot log in as ${t} ($(field err "$out"))"
  elif [[ $(field keyid "$out") != "$want" ]]; then
    fail AC-18 "${user}: certificate key id '$(field keyid "$out")', want ${want}"
  elif [[ $line != *" ID ${want} (serial ${serial}) "* ]]; then
    fail AC-18 "${host} Accepted line lacks 'ID ${want} (serial ${serial})': '${line}'"
  else
    pass AC-18 "${host}: Accepted publickey for ${t%@*} ... ID ${want} (serial ${serial})"
  fi
done

# sshd runs in the foreground with logs on stderr (CONTRACT §5.4), which is
# what puts the lines above into `docker compose logs`.
for h in host-billing host-crm; do
  # sshd rewrites its process title ("sshd: /usr/sbin/sshd -D -e [listener] ..."),
  # so the executable and the arguments in that title are checked.
  exe=$($COMPOSE exec -T "$h" readlink /proc/1/exe)
  cmd=$($COMPOSE exec -T "$h" sh -c 'tr "\0" " " </proc/1/cmdline')
  if [[ $exe == /usr/sbin/sshd && $cmd =~ ^(sshd:\ )?/usr/sbin/sshd\ -D\ -e(\ |$) ]]; then
    pass AC-18 "${h}: PID 1 is /usr/sbin/sshd running with -D -e"
  else
    fail AC-18 "${h}: PID 1 is ${exe} '${cmd}', want /usr/sbin/sshd -D -e"
  fi
done
