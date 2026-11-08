#!/usr/bin/env bash
# Lab bootstrap: a one-shot compose service. Safe to re-run (idempotent).
#
#   bootstrap pki   Offline material only, before compose starts the CAs:
#                   - fixed lab root + SPIRE upstream intermediate
#                   - step-ca: its own TLS root/intermediate, SSH user CA key,
#                     ca.json (x5c-spire provisioner, template, policy), and the
#                     public files clients and sshd hosts need
#                   `make up` runs this before compose starts spire-server/step-ca.
#   bootstrap       PKI check, then SPIRE:
#                   - agent: join token unless the local agent (by its data
#                     volume) holds a current SVID; other agents are evicted
#                   - entries: the whole trust domain converged to the agent
#                     alias plus bootstrap/spire-entries.txt, every field compared
#
# PKI is created once, then reused and checked; never silently regenerated.
#
# Secrets (keys, join token) only go to volumes; they are never printed.
set -euo pipefail

TRUST_DOMAIN=lab
AGENT_ALIAS_PATH=/agent/client
AGENT_ID="spiffe://${TRUST_DOMAIN}${AGENT_ALIAS_PATH}"
SPIRE_SERVER_UID=1000 # user of the ghcr.io/spiffe/spire-server image

PKI_PRIVATE=/lab/pki-private # root key; only this container mounts it
ROOT_DIR=/lab/root           # root cert; mounted read-only by others
UPSTREAM=/lab/spire-upstream
SERVER_DATA=/lab/spire-server-data
SERVER_SOCKET_DIR=/lab/spire-server-socket
TOKEN_DIR=/lab/agent-token
AGENT_DATA=/lab/spire-agent-data/agent/agent-data.json # read-only: which agent is ours
STEP_CA=/lab/step-ca               # step-ca's /home/step (keys, config, db)
STEP_PUBLIC=/lab/step-ca-public    # TLS root + SSH user CA public key; read-only elsewhere
STEP_CA_UID=1000                   # user "step" of the smallstep/step-ca image
STEP_CA_HOME=/home/step            # paths as step-ca sees them
SOCK="${SERVER_SOCKET_DIR}/api.sock"
CONF=/etc/lab-bootstrap
JOIN_TOKEN_TTL=600
# An agent counts as current only if its SVID outlives this margin. A running
# agent renews at half its SVID lifetime, so it never gets close.
AGENT_SVID_MARGIN=60

log() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
# spire-server CLI. Its error messages can name agent IDs, which embed the join
# token, so stderr goes through redact too (stdout is parsed by callers).
spire() {
  { spire-server "$@" -socketPath "$SOCK" 2>&1 1>&3 | redact_stream >&2; } 3>&1
}
fingerprint() { step certificate fingerprint "$1"; }

ensure_pki() {
  local root_crt="${ROOT_DIR}/root.crt" root_key="${PKI_PRIVATE}/root.key"
  local int_crt="${UPSTREAM}/intermediate.crt" int_key="${UPSTREAM}/intermediate.key"

  if [[ -s $root_crt && -s $root_key ]]; then
    log "lab root exists, reusing (sha256 $(fingerprint "$root_crt"))"
  elif [[ -e $root_crt || -e $root_key ]]; then
    die "partial lab root found; run 'make down' to reset"
  else
    log "creating lab root"
    step certificate create "Lampson Lab Root CA" "$root_crt" "$root_key" \
      --template "${CONF}/templates/root.tpl" \
      --kty EC --curve P-256 --not-after 87600h \
      --no-password --insecure
    log "lab root created (sha256 $(fingerprint "$root_crt"))"
  fi

  if [[ -s $int_crt && -s $int_key ]]; then
    step certificate verify "$int_crt" --roots "$root_crt" \
      || die "SPIRE intermediate does not chain to the lab root; run 'make down' to reset"
    log "SPIRE intermediate exists and chains to the lab root, reusing"
  elif [[ -e $int_crt || -e $int_key ]]; then
    die "partial SPIRE intermediate found; run 'make down' to reset"
  else
    log "creating SPIRE intermediate under the lab root"
    step certificate create "Lampson Lab SPIRE Intermediate CA" "$int_crt" "$int_key" \
      --template "${CONF}/templates/intermediate.tpl" \
      --ca "$root_crt" --ca-key "$root_key" \
      --kty EC --curve P-256 --not-after 43800h \
      --no-password --insecure
  fi

  cp "$root_crt" "${UPSTREAM}/bundle.crt"
  chmod 0400 "$root_key"
  chmod 0444 "$root_crt" "$int_crt" "${UPSTREAM}/bundle.crt"
  chown "${SPIRE_SERVER_UID}:${SPIRE_SERVER_UID}" "$int_key"
  chmod 0400 "$int_key"
  # spire-server runs as a non-root user and needs to own its data and socket dirs.
  chown "${SPIRE_SERVER_UID}:${SPIRE_SERVER_UID}" "$SERVER_DATA" "$SERVER_SOCKET_DIR"
}

# Create a CA cert/key pair once; afterwards reuse it if it chains to $4.
#   ensure_ca <name> <crt> <key> <issuer_crt> <issuer_key> <profile> <not_after>
# With issuer "-" the CA is self-signed (a root).
ensure_ca() {
  local name=$1 crt=$2 key=$3 issuer_crt=$4 issuer_key=$5 profile=$6 not_after=$7
  if [[ -s $crt && -s $key ]]; then
    if [[ $issuer_crt != - ]]; then
      step certificate verify "$crt" --roots "$issuer_crt" \
        || die "${name} does not chain to its issuer; run 'make down' to reset"
    fi
    log "${name} exists, reusing"
    return 0
  elif [[ -e $crt || -e $key ]]; then
    die "partial ${name} found; run 'make down' to reset"
  fi
  log "creating ${name}"
  local -a issuer=()
  [[ $issuer_crt != - ]] && issuer=(--ca "$issuer_crt" --ca-key "$issuer_key")
  step certificate create "$name" "$crt" "$key" "${issuer[@]}" \
    --profile "$profile" --kty EC --curve P-256 --not-after "$not_after" \
    --no-password --insecure
}

# step-ca: TLS PKI of its own, SSH user CA key, and ca.json.
#
# The TLS root is deliberately NOT the lab root: step-ca's intermediate key must
# not be able to mint certificates that X5C (which trusts the lab root) would
# accept as SVIDs (DECISIONS D-10). Only the lab root goes into x5c-spire roots.
ensure_step_ca() {
  local tls_root_key="${PKI_PRIVATE}/step-ca-tls-root.key"
  local tls_root="${STEP_PUBLIC}/root_ca.crt"
  local certs="${STEP_CA}/certs" secrets="${STEP_CA}/secrets"
  mkdir -p "$certs" "$secrets" "${STEP_CA}/config" "${STEP_CA}/templates" "${STEP_CA}/db"

  ensure_ca "Lampson Lab step-ca TLS Root" "$tls_root" "$tls_root_key" - - root-ca 87600h
  ensure_ca "Lampson Lab step-ca TLS Intermediate" \
    "${certs}/intermediate_ca.crt" "${secrets}/intermediate_ca_key" \
    "$tls_root" "$tls_root_key" intermediate-ca 43800h
  cp "$tls_root" "${certs}/root_ca.crt"

  local ssh_key="${secrets}/ssh_user_ca_key" ssh_pub="${certs}/ssh_user_ca_key.pub"
  if [[ -s $ssh_key && -s $ssh_pub ]]; then
    log "SSH user CA key exists, reusing"
  elif [[ -e $ssh_key || -e $ssh_pub ]]; then
    die "partial SSH user CA key found; run 'make down' to reset"
  else
    log "creating SSH user CA key"
    step crypto keypair "$ssh_pub" "$ssh_key" --kty EC --curve P-256 --no-password --insecure
  fi
  # sshd's TrustedUserCAKeys takes the OpenSSH format.
  step crypto key format --ssh "$ssh_pub" >"${STEP_PUBLIC}/ssh_user_ca.pub.tmp"
  mv "${STEP_PUBLIC}/ssh_user_ca.pub.tmp" "${STEP_PUBLIC}/ssh_user_ca.pub"
  log "SSH user CA: $(step ssh fingerprint "${STEP_PUBLIC}/ssh_user_ca.pub")"

  cp "${CONF}/step/templates/ssh-user.tpl" "${STEP_CA}/templates/ssh-user.tpl"
  write_ca_json

  chown -R "${STEP_CA_UID}:${STEP_CA_UID}" "$STEP_CA"
  chmod 0400 "$tls_root_key" "${secrets}/intermediate_ca_key" "$ssh_key"
  chmod 0444 "$tls_root" "${STEP_PUBLIC}/ssh_user_ca.pub"
}

# ca.json is regenerated on every run from the repo files and the lab root, so
# the provisioner, template and policy always match the repo. There is exactly
# one provisioner and no admin API, so nothing else can issue SSH certificates.
write_ca_json() {
  local h=$STEP_CA_HOME out="${STEP_CA}/config/ca.json"
  jq -n \
    --arg roots "$(base64 -w0 "${ROOT_DIR}/root.crt")" \
    --slurpfile mapping "${CONF}/step/ssh-mapping.json" \
    --slurpfile policy "${CONF}/step/policy/ssh-user.json" \
    --arg h "$h" '{
      root: "\($h)/certs/root_ca.crt",
      crt: "\($h)/certs/intermediate_ca.crt",
      key: "\($h)/secrets/intermediate_ca_key",
      address: ":9000",
      dnsNames: ["step-ca", "localhost"],
      logger: {format: "text"},
      db: {type: "badgerv2", dataSource: "\($h)/db"},
      ssh: {userKey: "\($h)/secrets/ssh_user_ca_key"},
      authority: {
        backdate: "0s",
        policy: {ssh: {user: $policy[0]}},
        provisioners: [{
          type: "X5C",
          name: "x5c-spire",
          roots: $roots,
          claims: {
            enableSSHCA: true,
            disableRenewal: true,
            minUserSSHCertDuration: "1m",
            defaultUserSSHCertDuration: "5m",
            maxUserSSHCertDuration: "5m"
          },
          options: {
            x509: {template: "{{ fail \"x5c-spire issues SSH user certificates only\" }}"},
            ssh: {
              templateFile: "\($h)/templates/ssh-user.tpl",
              templateData: {Mapping: $mapping[0]}
            }
          }
        }]
      },
      tls: {minVersion: 1.2, maxVersion: 1.3, renegotiation: false}
    }' >"${out}.tmp"
  if cmp -s "${out}.tmp" "$out"; then
    rm "${out}.tmp"
    log "step-ca ca.json unchanged"
  else
    mv "${out}.tmp" "$out"
    log "step-ca ca.json written (x5c-spire roots = lab root $(fingerprint "${ROOT_DIR}/root.crt"))"
  fi
}

wait_for_server() {
  local i
  for i in $(seq 1 120); do
    if spire-server healthcheck -socketPath "$SOCK" >/dev/null 2>&1; then
      log "spire-server is healthy"
      return 0
    fi
    sleep 1
  done
  die "spire-server did not become healthy within 120s"
}

all_entries() { spire entry show -output json | jq -c '(.entries // [])[]'; }
# Agent IDs embed the (spent) join token; keep it out of the logs.
redact_stream() { sed -E 's#(join_token/)[0-9A-Za-z-]+#\1<token>#g'; }
redact() { redact_stream <<<"$*"; }

# Every field that changes what an entry grants. Missing fields count as their
# protobuf defaults. Two entries with the same signature grant the same thing.
ENTRY_SIGNATURE='[
  .parent_id.path, .spiffe_id.path,
  ([.selectors[] | .type + ":" + .value] | sort | join(",")),
  "admin=\(.admin // false)", "downstream=\(.downstream // false)",
  "x509_ttl=\(.x509_svid_ttl // 0)", "jwt_ttl=\(.jwt_svid_ttl // 0)",
  "wit_ttl=\(.wit_svid_ttl // 0)", "expires_at=\(.expires_at // "0")",
  "dns=\((.dns_names // []) | join(","))",
  "federates=\((.federates_with // []) | join(","))",
  "hint=\(.hint // "")", "store_svid=\(.store_svid // false)"
] | join("|")'

# Signature of the alias entry `token generate -spiffeID` creates for an agent.
alias_signature() { # agent_path
  jq -nr --arg parent "$1" --arg alias "$AGENT_ALIAS_PATH" --arg td "$TRUST_DOMAIN" \
    "{parent_id: {path: \$parent}, spiffe_id: {path: \$alias},
      selectors: [{type: \"spiffe_id\", value: (\"spiffe://\" + \$td + \$parent)}]}
     | ${ENTRY_SIGNATURE}"
}

# Keep exactly one unmodified alias entry per given agent; delete every other
# entry whose SPIFFE ID is the alias, and recreate a current agent's alias if it
# was missing or modified (same shape as the one `token generate` creates).
converge_alias_entries() { # [current_agent_path...]
  local -A keep=() parent_of=()
  local p id sig
  for p in "$@"; do
    sig=$(alias_signature "$p")
    keep["$sig"]=want
    parent_of["$sig"]=$p
  done
  while IFS=$'\t' read -r id sig; do
    [[ -z ${id:-} ]] && continue
    if [[ ${keep[$sig]:-} == want ]]; then
      keep["$sig"]=found
      continue
    fi
    log "deleting agent alias entry ${id}: not the unmodified alias of a current agent ($(redact "$sig"))"
    spire entry delete -entryID "$id" >/dev/null
  done < <(all_entries | jq -r --arg p "$AGENT_ALIAS_PATH" \
    "select(.spiffe_id.path == \$p) | [.id, (${ENTRY_SIGNATURE})] | @tsv")
  local agent
  for sig in "${!keep[@]}"; do
    [[ ${keep[$sig]} == found ]] && continue
    agent="spiffe://${TRUST_DOMAIN}${parent_of[$sig]}"
    spire entry create -parentID "$agent" -spiffeID "$AGENT_ID" \
      -selector "spiffe_id:${agent}" >/dev/null
    log "agent alias entry recreated for $(redact "$agent")"
  done
}

# SPIFFE ID of the agent whose data is on our agent volume, or empty if the
# volume has no SVID (fresh, or lost).
local_agent_id() {
  [[ -r $AGENT_DATA ]] || return 0
  jq -r '.svid[0] // empty' "$AGENT_DATA" 2>/dev/null | base64 -d 2>/dev/null \
    | step certificate inspect --format json - 2>/dev/null \
    | jq -r '.extensions.subject_alt_name.uniform_resource_identifiers[0] // empty'
}

# Join tokens are single use and join_token agents cannot re-attest. The agent
# on our volume renews with its SVID while that SVID is current, so then no token
# is issued. Otherwise (no agent yet, its SVID expired while the lab was stopped,
# or its data volume was lost) every agent is evicted, every alias entry is
# removed, and one new token is issued. Agents that are not ours are always
# evicted: they cannot be the agent this lab runs.
ensure_join_token() {
  local now agents mine current a
  now=$(date +%s)
  agents=$(spire agent list -output json)
  mine=$(local_agent_id || true)
  current=$(jq -r --argjson min $((now + AGENT_SVID_MARGIN)) --arg mine "$mine" '(.agents // [])[]
      | select((.banned | not) and ((.x509svid_expires_at | tonumber) > $min))
      | "spiffe://\(.id.trust_domain)\(.id.path)" | select(. == $mine)' <<<"$agents")

  for a in $(jq -r '(.agents // [])[] | select(.banned | not) | "spiffe://\(.id.trust_domain)\(.id.path)"' <<<"$agents"); do
    [[ -n $current && $a == "$current" ]] && continue
    log "evicting agent $(redact "$a"): $([[ -n $mine && $a == "$mine" ]] && echo "SVID expired" || echo "not the agent on this lab's volume")"
    spire agent evict -spiffeID "$a" >/dev/null
  done

  if [[ -n $current ]]; then
    log "agent attested with a current SVID; no new join token"
    converge_alias_entries "${current#spiffe://"${TRUST_DOMAIN}"}"
    return 0
  fi
  converge_alias_entries

  local token
  token=$(spire token generate -spiffeID "$AGENT_ID" -ttl "$JOIN_TOKEN_TTL" -output json | jq -r '.value')
  [[ -n $token && $token != null ]] || die "spire-server returned no join token"
  (umask 077 && printf '%s' "$token" >"${TOKEN_DIR}/join_token.tmp")
  mv "${TOKEN_DIR}/join_token.tmp" "${TOKEN_DIR}/join_token"
  log "join token issued for ${AGENT_ID} (ttl ${JOIN_TOKEN_TTL}s)"
}

# Converge every workload entry in the trust domain (all entries except the
# agent alias) to exactly bootstrap/spire-entries.txt. An entry is kept only if
# its signature matches a wanted one exactly; anything else is deleted, and
# missing entries are created with default flags and the listed X509-SVID TTL.
ensure_entries() {
  local -A want=() sel_of=() ttl_of=()
  local name uid id ttl sig
  while read -r name uid id ttl; do
    [[ -z ${name:-} || $name == \#* ]] && continue
    [[ $uid =~ ^[0-9]+$ && $ttl =~ ^[0-9]+$ ]] || die "bad line in spire-entries.txt: ${name} ${uid} ${id} ${ttl:-}"
    sig=$(jq -nr --arg parent "$AGENT_ALIAS_PATH" --arg path "${id#spiffe://"${TRUST_DOMAIN}"}" \
      --arg sel "unix:uid:${uid}" --argjson ttl "$ttl" \
      "{parent_id: {path: \$parent}, spiffe_id: {path: \$path}, x509_svid_ttl: \$ttl,
        selectors: [{type: (\$sel | split(\":\")[0]), value: (\$sel | split(\":\")[1:] | join(\":\"))}]}
       | ${ENTRY_SIGNATURE}")
    want["$sig"]="$id"
    sel_of["$id"]="unix:uid:${uid}"
    ttl_of["$id"]=$ttl
  done <"${CONF}/spire-entries.txt"

  local -A have=()
  local entry_id
  while IFS=$'\t' read -r entry_id sig; do
    [[ -z ${entry_id:-} ]] && continue
    if [[ -n ${want[$sig]:-} && -z ${have[$sig]:-} ]]; then
      have["$sig"]=1
    else
      log "deleting entry ${entry_id}: not in spire-entries.txt as-is ($(redact "$sig"))"
      spire entry delete -entryID "$entry_id" >/dev/null
    fi
  done < <(all_entries | jq -r --arg p "$AGENT_ALIAS_PATH" \
    "select(.spiffe_id.path != \$p) | [.id, (${ENTRY_SIGNATURE})] | @tsv")

  for sig in "${!want[@]}"; do
    id=${want[$sig]}
    if [[ -n ${have[$sig]:-} ]]; then
      log "entry ok: ${id} <- ${sel_of[$id]}"
    else
      spire entry create -parentID "$AGENT_ID" -spiffeID "$id" -selector "${sel_of[$id]}" \
        -x509SVIDTTL "${ttl_of[$id]}" >/dev/null
      log "entry created: ${id} <- ${sel_of[$id]} (x509 ttl ${ttl_of[$id]}s)"
    fi
  done
}

main() {
  case "${1:-all}" in
    pki)
      ensure_pki
      ensure_step_ca
      log "PKI ready"
      return 0
      ;;
    all) ;;
    *) die "usage: bootstrap [pki]" ;;
  esac

  ensure_pki
  ensure_step_ca
  wait_for_server
  ensure_join_token
  ensure_entries
  log "done"
}

main "$@"
