#!/usr/bin/env bash
# lab-session-reaper: closes every SSH connection SESSION_MAX_SECONDS after it
# opened (TODO EP-11, DECISIONS D-21). Started by the entrypoint, runs as root.
#
# sshd checks a certificate only when it authenticates, so a connection opened
# with a 5-minute certificate would otherwise stay open (and could open new
# sessions over ControlMaster) for as long as the client keeps it. sshd has no
# absolute connection lifetime: ChannelTimeout and UnusedConnectionTimeout only
# close idle connections.
#
# OpenSSH 10 runs each connection in its own privileged "sshd-session: <user>
# [priv]" process, a child of the listener. Terminating it closes the
# connection, every session on it included. Its child (the user's
# "sshd-session: <user>@..." process) is the pid sshd logs as
# "User child is on pid <n>", right after the "Accepted publickey ... (serial
# <n>)" line of the same connection: that is how a closed connection is tied
# to its certificate.
set -uo pipefail

limit=${SESSION_MAX_SECONDS:?}
interval=${SESSION_CHECK_SECONDS:-5}
tck=$(getconf CLK_TCK)
log() { echo "lab-session-reaper: $*" >&2; }

log "started: connections are closed ${limit}s after they open (checked every ${interval}s)"
declare -A signalled=()
while :; do
  listener=''
  read -r listener 2>/dev/null </run/sshd.pid
  if [[ -n $listener ]]; then
    read -r up _ </proc/uptime
    up=${up%.*}
    declare -A ppid_of=() start_of=()
    for st in /proc/[0-9]*/stat; do
      s=''
      read -r s 2>/dev/null <"$st" || continue
      pid=${st#/proc/}; pid=${pid%/stat}
      # Fields after the command name, which is in parentheses: state is
      # field 3, ppid field 4, start time (clock ticks after boot) field 22.
      read -r -a f <<<"${s##*) }"
      ppid_of[$pid]=${f[1]}
      start_of[$pid]=${f[19]}
    done
    for pid in "${!ppid_of[@]}"; do
      [[ ${ppid_of[$pid]} == "$listener" ]] || continue
      cmd=$(tr '\0' ' ' 2>/dev/null <"/proc/${pid}/cmdline") || continue
      [[ $cmd == sshd-session:* ]] || continue
      age=$(( up - start_of[$pid] / tck ))
      (( age >= limit )) || continue
      user=${cmd#sshd-session: }; user=${user%% *}
      # Everything under the connection: the user child and the session
      # commands below it. Terminating only the [priv] process leaves those
      # commands running, reparented to PID 1 (and the client waiting on
      # them). A process that already detached itself to PID 1 is not found.
      child=- tree=() queue=("$pid")
      while (( ${#queue[@]} )); do
        p=${queue[0]}; queue=("${queue[@]:1}")
        for c in "${!ppid_of[@]}"; do
          [[ ${ppid_of[$c]} == "$p" ]] || continue
          tree+=("$c"); queue+=("$c")
          [[ $p == "$pid" ]] && child=$c
        done
      done
      # The session processes get SIGKILL. The [priv] process gets SIGTERM so
      # that sshd logs the end; still there one round later, it gets SIGKILL.
      sig=TERM
      [[ -n ${signalled[$pid]:-} ]] && sig=KILL
      (( ${#tree[@]} )) && kill -KILL "${tree[@]}" 2>/dev/null
      if kill "-${sig}" "$pid" 2>/dev/null; then
        signalled[$pid]=1
        log "closed connection: user=${user} pid=${pid} user-child=${child} processes=$(( ${#tree[@]} + 1 )) age=${age}s limit=${limit}s signal=${sig}"
      fi
    done
    for pid in "${!signalled[@]}"; do [[ -e /proc/$pid ]] || unset "signalled[$pid]"; done
    unset ppid_of start_of
  fi
  sleep "$interval"
done
