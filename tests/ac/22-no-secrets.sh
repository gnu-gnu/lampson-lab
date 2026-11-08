# AC: AC-22
# AC-22: no private key or token is committed (CONTRACT §7, §10.6).
#   - tests/helpers/secret-scan.py checks .gitignore, `git ls-files`, file
#     names and binary blobs, and writes the raw content of every blob in the
#     history to a directory;
#   - gitleaks (pinned in .env, rules in .gitleaks.toml: the default set plus
#     this lab's own formats) scans that directory (DECISIONS D-20).
#
# Positive control first: a throwaway repository gets one committed file per
# disguise the scan must see through, all generated here at run time (this
# file contains no secret-shaped text). Each planted file must be reported.

GITLEAKS_IMAGE=$(sed -n 's/^GITLEAKS_IMAGE=//p' .env)
gl_ver=${GITLEAKS_IMAGE#*gitleaks:v}; gl_ver=${gl_ver%%@*}

# secret_scan <repo dir>: prints "finding=<kind> <path> (blob <sha>)" lines,
# "findings=<n>" and "blobs=<n>". Fails closed: a scan that does not run
# cleanly is a finding.
secret_scan() {
  local repo=$1 exp out rep rc n
  exp=$(mktemp -d)
  out=$(python3 -I "${TESTS_DIR}/helpers/secret-scan.py" "$repo" "$exp" 2>&1)
  rc=$?
  grep '^finding=' <<<"$out"
  n=$(field findings "$out")
  if (( rc != 0 )) || [[ ! $n =~ ^[0-9]+$ ]] || [[ -z $(field blobs "$out") && $n == 0 ]]; then
    echo "finding=secret-scan.py did not run (exit ${rc}): $(grep -v '^finding=' <<<"$out" | tail -n 1)"
    n=$(( ${n:-0} + 1 ))
  fi
  # The container sees only the exported blobs and the rules: no network, no
  # repository config, no .gitleaksignore, and gitleaks:allow comments do not
  # count. --redact keeps secret values out of the report.
  rep=$(docker run --rm --network none --read-only --user "$(id -u):$(id -g)" -w / \
          -v "${exp}:/scan:ro" -v "${PWD}/.gitleaks.toml:/rules.toml:ro" \
          "${GITLEAKS_IMAGE:?GITLEAKS_IMAGE not set in .env}" \
          dir /scan --config /rules.toml --gitleaks-ignore-path / --ignore-gitleaks-allow \
          --redact --no-banner --log-level error --exit-code 0 \
          --report-format json --report-path - 2>&1)
  rc=$?
  rm -rf "$exp"
  if (( rc != 0 )) || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rep"; then
    echo "finding=gitleaks did not run (exit ${rc}): $(head -c 300 <<<"$rep" | tr '\n' ' ')"
    n=$((n + 1))
  else
    jq -r '.[] | .File as $f | ($f | ltrimstr("/scan/") | split("/")) as $p
           | "finding=\(.RuleID): \($p[1:] | join("/")) (blob \($p[0][0:12]))"' <<<"$rep" | sort -u
    n=$((n + $(jq length <<<"$rep")))
  fi
  echo "findings=${n}"
  field blobs "$out" | sed 's/^/blobs=/'
}

ctl=$(mktemp -d)
planted=$(
  cd "$ctl" || exit 1
  git init -q && git config user.email t@t && git config user.name t
  cp "$OLDPWD/.gitignore" .gitignore
  uuid() { cat /proc/sys/kernel/random/uuid; }
  b64url() { printf '%s' "$1" | base64 -w0 | tr -d '=' | tr '/+' '_-'; }
  rnd() { python3 -I -c 'import secrets,sys; print("".join(secrets.choice(sys.argv[1]) for _ in range(int(sys.argv[2]))))' "$@"; }
  ssh-keygen -q -t ed25519 -N '' -f ./k && mv k notes.txt && rm k.pub          # OpenSSH key, innocent name
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out pkcs8 2>/dev/null
  sed 's/$/\r/' pkcs8 >crlf.conf                                                # CRLF line ends
  { echo "tls:"; echo "  key: |"; sed 's/^/    /' pkcs8; } >values.yaml          # indented in YAML
  python3 -I -c 'import json,sys; print(json.dumps({"key": open(sys.argv[1]).read()}))' pkcs8 >blob.json  # escaped in JSON
  openssl pkey -in pkcs8 -outform DER -out cert-data 2>/dev/null                # DER (binary)
  { echo "hidden -diff"; } >.gitattributes; cp pkcs8 hidden                     # diff disabled
  openssl pkey -in pkcs8 -aes256 -passout pass:x -out sealed.txt 2>/dev/null     # encrypted PKCS#8
  openssl ec -in pkcs8 -aes256 -passout pass:x -out legacy.txt 2>/dev/null       # encrypted, Proc-Type headers
  rm pkcs8
  python3 -I -c 'import json,secrets,base64
e=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print(json.dumps({"kty":"EC","crv":"P-256","x":e(secrets.token_bytes(32)),"y":e(secrets.token_bytes(32)),"d":e(secrets.token_bytes(32))}))' >jwk.txt
  printf 'plugins {\n  NodeAttestor "join_token" { plugin_data { join_token = "%s" } }\n}\n' "$(uuid)" >agent.conf
  uuid >value.txt                                                               # a token on its own
  echo "agent spiffe://lab/spire/agent/join_token/$(uuid)" >spire.log
  echo "ott=$(b64url '{"alg":"ES256","typ":"JWT"}').$(b64url '{"sub":"spiffe://lab/client/deployer"}').$(b64url "sig-$(uuid)")" >request.log
  # Formats this lab does not produce, caught only by the gitleaks default
  # rules: shows the default set is in use.
  echo "AWS_ACCESS_KEY_ID=AKIA$(rnd ABCDEFGHIJKLMNOPQRSTUVWXYZ234567 16)" >cloud.env
  echo "git clone https://x:ghp_$(rnd ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 36)@example.org/r" >deploy.sh
  # Marked as allowed: gitleaks:allow comments must not count.
  echo "TOKEN=ghp_$(rnd ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 36) # gitleaks:allow" >allowed.sh
  # Committed, then deleted: still in the history.
  ssh-keygen -q -t ed25519 -N '' -f ./old && rm old.pub
  git add -A && git commit -qm planted && git rm -q old && git commit -qm "remove key"
  echo "notes.txt crlf.conf values.yaml blob.json cert-data hidden jwk.txt agent.conf value.txt spire.log request.log cloud.env deploy.sh old sealed.txt legacy.txt allowed.sh"
)
c=$(secret_scan "$ctl")
rm -rf "$ctl"
missed=()
for f in $planted; do
  grep -q "^finding=.* ${f} (blob " <<<"$c" || missed+=("$f")
done
if grep -q '^finding=.* did not run' <<<"$c"; then
  fail AC-22 "precondition: $(grep -m1 '^finding=.* did not run' <<<"$c" | sed 's/^finding=//')"
elif [[ -z $planted || ${#missed[@]} -gt 0 ]]; then
  fail AC-22 "precondition: the scan missed planted secrets: ${missed[*]:-nothing was planted}"
else
  out=$(secret_scan .)
  if [[ $(field findings "$out") == 0 ]]; then
    pass AC-22 "no key or token in $(git ls-files | wc -l) tracked files, $(field blobs "$out") blobs of $(git rev-list --all | wc -l) commits; .gitignore covers key paths (gitleaks ${gl_ver}; caught all $(wc -w <<<"$planted") planted disguises)"
  else
    fail AC-22 "$(grep '^finding=' <<<"$out" | sed 's/^finding=//' | paste -sd';' -)"
  fi
fi
