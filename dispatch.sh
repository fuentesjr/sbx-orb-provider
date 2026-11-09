#!/usr/bin/env bash
# Amp self-hosted orb dispatch -> Docker Sandboxes (sbx).
#
# Run by `amp orb provider` (as user `agent`) once per job, no arguments.
# Contract (ampcode.com/docs/orbs/self-hosted): every operation must be safe
# to repeat and finish within five minutes. Output goes to the provider log;
# spawn output also shows in the thread's setup log.
#
#   ORB_OPERATION    spawn | pause | delete
#   ORB_ID           orb id (amp-<thread id>), used as the sandbox name
#   ORB_IMAGE        spawn: image to boot (provider override, or Amp's default)
#   ORB_SNAPSHOT_ID  spawn: boot from it if present; pause: save to it
#   ORB_TYPE         spawn: orb type name: large (default) | small; see below
#   ORB_TOKEN        spawn: short-lived token for `amp orb bootstrap`
#   AMP_URL          spawn: only set when not ampcode.com
set -euo pipefail

# The provider's own token is in our environment by inheritance. Nothing here
# needs it, so drop it before running anything.
unset AMP_ORB_PROVIDER_TOKEN

# Nothing here reads stdin, but `sbx exec` does: given an open stdin it reads or
# waits on it. Close it so a job can't hang or swallow the caller's input.
exec </dev/null

: "${ORB_OPERATION:?ORB_OPERATION not set}" "${ORB_ID:?ORB_ID not set}"

# Orb types (defined in Amp's provider Edit dialog; Amp sends the name as
# ORB_TYPE on spawn). Sizes are fixed when the sandbox is created.
#   large (default): 4 CPU, 8 GB, 20 GB Docker volume. Most threads run the
#                    Rails suite with Postgres/Redis on the orb's own Docker.
#   small:           2 CPU, 4 GB, 10 GB Docker volume (sbx's default size).
# sbx's own default (50% of host RAM per sandbox) is far too much on 32 GB.
# Docker volumes are sparse; the free-space check below only guards against
# overcommitting the host disk, as the image build does.
ORB_MIN_FREE_HEADROOM_GB=${ORB_MIN_FREE_HEADROOM_GB:-10}

orb_size() { # sets ORB_KIND ORB_CPUS ORB_MEMORY ORB_DOCKER_GB from ORB_TYPE
  local t=${ORB_TYPE:-}
  case $t in
    large|small) ;;
    "") log "WARNING: ORB_TYPE unset; using large"; t=large ;;
    *) log "WARNING: unknown ORB_TYPE '$t'; using large"; t=large ;;
  esac
  case $t in
    large) ORB_KIND=large ORB_CPUS=4 ORB_MEMORY=8g ORB_DOCKER_GB=20 ;;
    small) ORB_KIND=small ORB_CPUS=2 ORB_MEMORY=4g ORB_DOCKER_GB=10 ;;
  esac
}

# Hosts an orb needs beyond the global Balanced policy (which already has
# github.com and storage.googleapis.com). See ampcode.com/docs/orbs/self-hosted.
AMP_HOSTS=ampcode.com,static.ampcode.com,tunnel.ampcode.com
# Desktop streams over WebRTC: UDP to Amp's relays only (the viewer's own IP,
# the direct path, stays blocked). Needs sbx's experimental global
# feature.udp-egress; without it sbx stores the rule but drops the traffic.
AMP_UDP_RELAYS=104.30.0.0/15

# The patched template. Amp's stock image can't run under sbx
# (FINDINGS.md, step 4). setup.sh installs the pin next to this script.
ORB_PIN=${ORB_PIN:-$(dirname "$(readlink -f "$0")")/amp-orb.pin}

START=$SECONDS
log() { printf 'sbx-dispatch %s %s: %s\n' "$ORB_OPERATION" "$ORB_ID" "$*" >&2; }
done_log() { log "$* ($((SECONDS - START)) s)"; }

# Record what Amp sent (never the tokens), so which-case-is-which is visible.
log "job: ORB_IMAGE=${ORB_IMAGE:-unset} ORB_SNAPSHOT_ID=${ORB_SNAPSHOT_ID:-unset} ORB_TYPE=${ORB_TYPE:-unset} AMP_URL=${AMP_URL:-unset}"

sandbox_exists() { sbx ls -q | grep -qxF -- "$ORB_ID"; }

# Keep-alive: sbx auto-stops a local sandbox 30 s after its last session ends,
# and the bootstrap runs detached, so hold one idle `sbx exec` session per orb.
# It runs on the host as agent inside amp-orb-provider.service's cgroup, so
# stopping the provider kills every keep-alive; sbx then stops the orbs within
# 30 s and Amp resumes them later. Orbs run only while the provider runs.
# (sbx's long-running@1 would be cleaner but needs a v3 workload kit; FINDINGS.)
KEEPALIVE_DIR=${KEEPALIVE_DIR:-$HOME/orb/run}
keepalive_pidfile() { printf '%s/%s.pid' "$KEEPALIVE_DIR" "$ORB_ID"; }
# Orb type and size as created, for ./setup.sh status (sbx doesn't keep it).
typefile() { printf '%s/%s.type' "$KEEPALIVE_DIR" "$ORB_ID"; }

# PID of this orb's keep-alive if it is alive and really ours (guards PID reuse).
keepalive_pid() {
  local pid
  pid=$(cat "$(keepalive_pidfile)" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && { tr '\0' ' ' <"/proc/$pid/cmdline"; } 2>/dev/null |
    grep -qF -- "sbx exec $ORB_ID sleep infinity" && printf '%s' "$pid"
}

keepalive_start() {
  mkdir -p "$KEEPALIVE_DIR"
  if keepalive_pid >/dev/null; then
    log "keep-alive already running (pid $(keepalive_pid))"
    return 0
  fi
  # setsid: own session, so job-level signals to the dispatch don't reach it.
  # All stdio redirected, so the provider isn't left waiting on our pipes.
  setsid sbx exec "$ORB_ID" sleep infinity </dev/null >>"$KEEPALIVE_DIR/$ORB_ID.log" 2>&1 &
  printf '%s\n' $! >"$(keepalive_pidfile)"
  log "keep-alive started (pid $!)"
}

keepalive_stop() {
  local pid
  if pid=$(keepalive_pid); then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null || true
    log "keep-alive stopped (pid $pid)"
  fi
  rm -f "$(keepalive_pidfile)" "$KEEPALIVE_DIR/$ORB_ID.log"
}

# Local sbx templates are listed with their registry; bare names mean docker.io.
qualify() { case ${1%%/*} in *.*|*:*|localhost) printf '%s' "$1" ;; *) printf 'docker.io/%s' "$1" ;; esac; }
# `sbx template inspect` is cloud-only; list local templates instead.
template_exists() { sbx template ls -q | grep -qxF -- "$(qualify "$1")"; }

# Local template name for a snapshot id (tag charset: [A-Za-z0-9_.-], max 128).
snapshot_tag() {
  local id
  id=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-120)
  printf 'localhost/amp-orb-snapshot:%s' "$id"
}

# Pick the image for a new sandbox, in this order:
#   1. a local snapshot saved under ORB_SNAPSHOT_ID
#   2. ORB_IMAGE, only if it names a local *snapshot* template (in case Amp
#      ever passes a snapshot that way)
#   3. the pinned template. The pin is the only authority on the base image:
#      the provider's ORB_IMAGE override is read when the provider starts, so
#      after update-orbs/rollback-orbs without a restart it names the old
#      template (FINDINGS: patch 3, verification thread).
choose_image() {
  local pinned q
  pinned=$(sed -n 's/^template=//p' "$ORB_PIN" 2>/dev/null)
  [[ -n $pinned ]] || { log "no template= in $ORB_PIN"; return 1; }
  q=$(qualify "${ORB_IMAGE:-none}")
  if [[ -n ${ORB_SNAPSHOT_ID:-} ]] && template_exists "$(snapshot_tag "$ORB_SNAPSHOT_ID")"; then
    log "image case 1: snapshot for ORB_SNAPSHOT_ID"
    snapshot_tag "$ORB_SNAPSHOT_ID"
  elif [[ $q == localhost/amp-orb-snapshot:* ]] && template_exists "$q"; then
    log "image case 2: ORB_IMAGE is a local snapshot template"
    printf '%s' "$q"
  else
    if [[ $q == localhost/amp-orb:* && $q != "$pinned" ]]; then
      log "WARNING: ORB_IMAGE names $q, not the pinned $pinned (stale provider override?); using the pin"
    fi
    log "image case 3: pinned template"
    printf '%s' "$pinned"
  fi
}

spawn() {
  : "${ORB_TOKEN:?ORB_TOKEN not set}"
  if sandbox_exists; then
    log "sandbox exists; starting it (resume)"
    local was
    was=$(cut -d' ' -f1 "$(typefile)" 2>/dev/null || echo unknown)
    [[ -z ${ORB_TYPE:-} || ${ORB_TYPE} == "$was" ]] ||
      log "WARNING: Amp asked for ORB_TYPE=$ORB_TYPE but this orb was created as $was; size is fixed at creation"
  else
    local image free_gb docker_gb
    image=$(choose_image)
    orb_size
    # Same check as the image build: free space on agent's disk.
    free_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)
    if ((free_gb < ORB_DOCKER_GB + ORB_MIN_FREE_HEADROOM_GB)); then
      log "WARNING: only ${free_gb} GB free, need $((ORB_DOCKER_GB + ORB_MIN_FREE_HEADROOM_GB)) GB for a ${ORB_DOCKER_GB} GB Docker volume; using 10 GB"
      ORB_DOCKER_GB=10
      # Alert the operator too, if the host names an alert unit in
      # ORB_LOW_DISK_ALERT_UNIT (an Environment= drop-in on the provider unit;
      # the dispatch inherits the provider's environment). The host must also
      # let agent start that one unit, e.g. with a polkit rule.
      # --no-block: never delay or fail the spawn for the alert.
      if [[ -n ${ORB_LOW_DISK_ALERT_UNIT:-} ]]; then
        systemctl start --no-block "$ORB_LOW_DISK_ALERT_UNIT" >/dev/null 2>&1 ||
          log "WARNING: could not trigger $ORB_LOW_DISK_ALERT_UNIT"
      fi
    fi
    log "creating $ORB_KIND orb ($ORB_CPUS CPU, $ORB_MEMORY, ${ORB_DOCKER_GB} GB Docker) from $image"
    # --pull never is the guard against registry pulls: a missing template
    # fails the spawn instead of being fetched. (The localhost/ namespace
    # points at no real registry either.)
    DOCKER_SANDBOXES_DOCKER_SIZE=${ORB_DOCKER_GB}g sbx create shell --name "$ORB_ID" \
      --template "$image" --pull never --cpus "$ORB_CPUS" --memory "$ORB_MEMORY" --no-progress
    mkdir -p "$KEEPALIVE_DIR"
    printf '%s %s %s %sg %s\n' "$ORB_KIND" "$ORB_CPUS" "$ORB_MEMORY" "$ORB_DOCKER_GB" "$image" >"$(typefile)"
    # Amp's hosts are default-deny under Balanced. Allow them for this orb
    # only; the rule goes away with `sbx rm`. If it can't be added, remove the
    # half-made sandbox so a retried spawn starts clean (spawn must be repeatable).
    if ! sbx policy allow network --sandbox "$ORB_ID" "$AMP_HOSTS" ||
      ! sbx policy allow network --sandbox "$ORB_ID" --protocol udp "$AMP_UDP_RELAYS"; then
      log "policy rule failed; removing sandbox"
      sbx rm --force "$ORB_ID" || true
      return 1
    fi
  fi

  # `sbx exec` starts a stopped sandbox first, and fails (125) if its runtime
  # can't start, which also catches a sandbox `create` wrongly reported as fine.
  # It has no --detach, so the bootstrap detaches itself inside the sandbox
  # (setsid + nohup, stdio closed) and exec returns at once. Runs as `user`.
  # Shim 2 (FINDINGS: systemd assumptions): /run is a fresh tmpfs on every sbx
  # boot and nothing runs systemd-tmpfiles, so recreate the image's /run entries
  # (notably /run/lock, which Desktop's install-app locks). --prefix=/run keeps
  # it off /etc, /root, /home, /var; no --boot, so /run/nologin is never made.
  # It never creates /run/systemd/system, which must stay absent. Runs on every
  # spawn, new or resume, before the bootstrap; idempotent.
  if ! sbx exec -u root "$ORB_ID" systemd-tmpfiles --create --prefix=/run; then
    log "systemd-tmpfiles failed; creating /run/lock only"
    sbx exec -u root "$ORB_ID" install -d -m 1777 -o root -g root /run/lock
  fi

  local env_args=(-e ORB_TOKEN -e HOME=/home/user -e USER=user)
  [[ -n ${AMP_URL:-} ]] && env_args+=(-e AMP_URL)
  # env -u: sbx puts a stand-in GH_TOKEN (GitHub-shaped, never swapped: no
  # github secret, github hosts are forward-bypass) in every sandbox's PID 1
  # environment. Amp's gh wrapper only fetches its repo-scoped token when
  # GH_TOKEN/GITHUB_TOKEN are empty, so drop them for the bootstrap and
  # everything it starts (FINDINGS: GH_TOKEN in orbs).
  sbx exec -u user -w /home/user "${env_args[@]}" "$ORB_ID" \
    bash -c 'setsid nohup env -u GH_TOKEN -u GITHUB_TOKEN amp orb bootstrap >>"$HOME/.orb-bootstrap.log" 2>&1 </dev/null &'
  keepalive_start
  docker_gb=$(sbx exec "$ORB_ID" df -BG --output=size /var/lib/docker 2>/dev/null | tail -1 | tr -dc 0-9)
  log "Docker volume in orb: ${docker_gb:-?} GB"
  done_log "bootstrap started"
}

# Record /usr/bin/git in a running orb (after Amp's bootstrap and setup have
# run: Amp's first pause comes right after repository setup). drift.sh fails
# if an orb created from the current pin reports < 2.40 (patch 3).
GITCHECK_LOG=${GITCHECK_LOG:-$KEEPALIVE_DIR/usr-bin-git.log}
SECRETNAMES_LOG=${SECRETNAMES_LOG:-$KEEPALIVE_DIR/amp-secret-names.log}
record_git() {
  local st v from
  st=$(sbx ls --format json | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["name"]==sys.argv[1]]; print(s[0]["status"] if s else "")' "$ORB_ID")
  [[ $st == running ]] || return 0 # never start a stopped orb just to check
  v=$(sbx exec "$ORB_ID" /usr/bin/git --version 2>/dev/null | awk '{print $3}')
  from=$(cut -d' ' -f5 "$(typefile)" 2>/dev/null)
  mkdir -p "$KEEPALIVE_DIR"
  { flock -w 30 9; printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$ORB_ID" "${from:-unknown}" "${v:-none}" >>"$GITCHECK_LOG"; } 9>"$GITCHECK_LOG.lock"
  if [[ -z $v || $(printf '%s\n' 2.40 "$v" | sort -V | head -1) != 2.40 ]]; then
    log "WARNING: /usr/bin/git is ${v:-missing} (< 2.40) in this orb (created from ${from:-unknown})"
  else
    log "/usr/bin/git $v"
  fi
  # Names (never values) of the secrets in the agent's environment
  # (AMP_SECRET_ENV_NAMES), as defense in depth; drift.sh alerts on any name
  # outside its allow-list.
  # no-agent: no amp --headless process (e.g. Amp's post-setup pause, before
  # the agent starts) = not checked. none: agent running, no secret names.
  local names
  # Find the agent by its own argv (argv0 = amp, then --headless=): `pgrep -f`
  # would also match this sh -c, whose command line contains the pattern.
  names=$(sbx exec -u root "$ORB_ID" sh -c 'p=; for d in /proc/[0-9]*; do case "$(tr "\0" " " <"$d/cmdline" 2>/dev/null)" in amp\ --dangerously-allow-all\ --headless=*|*/amp\ --dangerously-allow-all\ --headless=*) p=${d#/proc/}; break ;; esac; done; if [ -z "$p" ]; then echo no-agent; else n=$(tr "\0" "\n" <"/proc/$p/environ" | sed -n "s/^AMP_SECRET_ENV_NAMES=//p"); echo "${n:-none}"; fi' 2>/dev/null)
  names=${names:-no-agent}
  { flock -w 30 9; printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$ORB_ID" "$names" >>"$SECRETNAMES_LOG"; } 9>"$SECRETNAMES_LOG.lock"
  log "Amp secret env names: $names"
}

pause() {
  keepalive_stop
  if ! sandbox_exists; then
    done_log "no sandbox; nothing to pause"
    return 0
  fi
  record_git
  sbx stop "$ORB_ID"
  if [[ -n ${ORB_SNAPSHOT_ID:-} ]]; then
    local tag
    tag=$(snapshot_tag "$ORB_SNAPSHOT_ID")
    sbx template save "$ORB_ID" "$tag"
    log "saved snapshot $tag"
  fi
  done_log "stopped"
}

delete() {
  keepalive_stop
  if ! sandbox_exists; then
    rm -f "$(typefile)"
    done_log "no sandbox; nothing to delete"
    return 0
  fi
  sbx rm --force "$ORB_ID"
  rm -f "$(typefile)"
  done_log "removed"
}

case $ORB_OPERATION in
  spawn) spawn ;;
  pause) pause ;;
  delete) delete ;;
  *) log "unknown operation"; exit 1 ;;
esac
