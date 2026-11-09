#!/usr/bin/env bash
# Install and operate the sbx orb provider on one host. Idempotent; run as an
# admin user (uses sudo for the provider user's parts).
#
#   ORB_PIN_FILE=/abs/path/amp-orb.pin ./install.sh SECTION...
#
# The pin is the host's deployment state, so it lives with the caller: this
# script reads $ORB_PIN_FILE and $ORB_PIN_FILE.previous, and update-orbs and
# rollback-orbs rewrite them there (README.md has the format).
#
# Sections:
#   amp-cli         pinned Amp CLI for agent (~agent/.amp/bin/amp), self-update off
#   orb-image       patched sbx orb template for the pin
#   orb-provider    dispatch, provider wrapper, pin in ~agent/orb; systemd unit
#   canary          daily orb canary timer (dry run + drift)
#   canary-run      run the canary now (as its service) and show the result
#   update-orbs     re-pin Amp CLI + orb image to upstream, rebuild, canary, and
#                   switch only if it passes; keeps the previous pin
#   rollback-orbs   swap back to the previous pin (CLI binary + template)
#   status          versions, drift check, orb sandboxes, stale templates, timer
#   status-versions, status-orbs
#                   the two halves of status, for callers adding their own lines
#
# Not done here, on purpose: sbx-daemon.service (see examples/), creating the
# provider credential, and alerting (add OnFailure= with a systemd drop-in).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ ${ORB_PIN_FILE:-} == /* && -f ${ORB_PIN_FILE:-} ]] ||
  { echo "ERROR: set ORB_PIN_FILE to the absolute path of the pin file" >&2; exit 2; }
AMP_ORB_REPO=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb
AMP_CLI_BASE=https://static.ampcode.com/cli
AMP_ORB_PIN_FILE=$ORB_PIN_FILE
AMP_ORB_PIN_PREVIOUS=$ORB_PIN_FILE.previous
AMP_ORB_PIN_CANDIDATE=$ORB_PIN_FILE.candidate
ORB_BUILD_DOCKER_SIZE=20g
ORB_BUILD_MIN_FREE_GB=25
HOST_ORB=/home/agent/orb
HOST_AMP=/home/agent/.amp/bin/amp

# Which pin file the pin_* helpers read; update-orbs points it at the candidate.
PIN=$AMP_ORB_PIN_FILE

say() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Run a command as agent, from agent's home, so sbx talks to agent's sandboxd.
as_agent() { sudo -u agent -H bash -c 'cd ~ && exec "$@"' as_agent "$@"; }

# Every host-side Amp CLI call goes through this: as agent, with
# AMP_SKIP_UPDATE_CHECK=1 (as the provider unit has), stdin from /dev/null (no
# prompt can wait for input) and at most AMP_CALL_TIMEOUT s (TERM, then KILL
# 5 s later). A bare `amp --version` here once hung for good, ignoring Ctrl-C.
# On timeout: says so on stderr and returns 124. host_amp BINARY ARGS...
AMP_CALL_TIMEOUT=15
host_amp() {
  local rc=0
  as_agent env AMP_SKIP_UPDATE_CHECK=1 timeout -k 5 "$AMP_CALL_TIMEOUT" "$@" </dev/null || rc=$?
  if ((rc == 124 || rc == 137)); then
    echo "$*: timed out after ${AMP_CALL_TIMEOUT} s" >&2
    return 124
  fi
  return $rc
}

pin_get() { sed -n "s/^$1=//p" "${2:-$PIN}"; }

# Patch revision of orb_dockerfile. Bump it here whenever orb_dockerfile
# changes; update-orbs then builds a new template name. Each pin records its
# own patch=, and orb_dockerfile builds the recipe of that revision, so an
# older pin (rollback target) still rebuilds exactly.
ORB_PATCH_REV=3

# sbx template name for a digest and patch revision (local image store; never pushed).
orb_template() { local d=${1#sha256:}; printf 'localhost/amp-orb:%s-p%s' "${d:0:12}" "${2:-$ORB_PATCH_REV}"; }

# write_pin FILE DIGEST AMP_CLI_VERSION (patch = current ORB_PATCH_REV)
write_pin() {
  cat >"$1" <<EOF
# Amp orb stack this host runs: Amp's orb image (by digest) + the patch
# revision on top, and the host's Amp CLI version (provider). Written by
# ./setup.sh update-orbs; read by setup.sh, the dispatch and the canary.
# template = localhost/amp-orb:<first 12 of digest>-p<patch>
digest=$2
patch=$ORB_PATCH_REV
template=$(orb_template "$2")
amp_cli=$3
EOF
}

# The pin must be complete and its template line match what we'd build.
check_pin() {
  local file=${1:-$PIN} want
  [[ -n $(pin_get digest "$file") && -n $(pin_get amp_cli "$file") ]] || die "$file lacks digest= or amp_cli="
  want=$(orb_template "$(pin_get digest "$file")" "$(pin_get patch "$file")")
  [[ $(pin_get template "$file") == "$want" ]] || die "$file: template= should be $want"
}

upstream_digest() {
  curl -fsS -o /dev/null -D - \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://${AMP_ORB_REPO%%/*}/v2/${AMP_ORB_REPO#*/}/manifests/latest" |
    tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}'
}
upstream_cli() { curl -fsS "$AMP_CLI_BASE/cli-version.txt" | tr -d '[:space:]'; }

# install SRC DEST MODE OWNER; returns 1 if nothing changed.
install_file() {
  if sudo cmp -s "$1" "$2"; then return 1; fi
  sudo install -m "$3" -o "$4" -g "$4" "$1" "$2"
  echo "installed $2"
}

# Running orb sandboxes (restarting the provider pauses them; Amp resumes them
# on the next message, as tested in step 4 run 2).
running_orbs() {
  as_agent sbx ls --format json </dev/null | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if s.get("name", "").startswith("amp-") and s["name"] != "amp-dryrun" and s.get("status") == "running":
        print(s["name"])'
}

restart_provider() {
  local orbs
  orbs=$(running_orbs)
  [[ -z $orbs ]] || echo "note: restarting the provider pauses running orbs (they resume on the next message): $orbs"
  sudo systemctl restart amp-orb-provider
}

# The provider must come up and announce the expected version within 30 s.
provider_started_with() {
  local want=$1 inv
  for _ in $(seq 30); do
    inv=$(systemctl show -p InvocationID --value amp-orb-provider)
    if journalctl -q -o cat _SYSTEMD_INVOCATION_ID="$inv" 2>/dev/null |
        grep -q "Orb provider started.*\"spawnerVersion\":\"$want\""; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# amp_fetch VERSION DEST: download one Amp CLI build as agent, checksum-verified.
amp_fetch() {
  as_agent bash -c '
    set -euo pipefail
    v=$1 dest=$2 base=$3
    t=$(mktemp -p ~ .amp-dl.XXXXXX); trap "rm -f \"$t\"" EXIT
    curl -fsSL "$base/$v/amp-linux-x64" -o "$t"
    want=$(curl -fsSL "$base/$v/linux-x64-amp.sha256" | tr -dc 0-9a-f)
    got=$(sha256sum "$t" | cut -d" " -f1)
    [[ -n $want && $got == "$want" ]] || { echo "amp $v: checksum mismatch" >&2; exit 1; }
    chmod 0755 "$t"; mkdir -p "$(dirname "$dest")"; mv -f "$t" "$dest"; trap - EXIT
    rc=0; out=$(AMP_SKIP_UPDATE_CHECK=1 timeout -k 5 "$4" "$dest" --version </dev/null) || rc=$?
    ((rc != 124 && rc != 137)) || { echo "amp $v: --version timed out after $4 s" >&2; exit 1; }
    [[ ${out%% *} == "$v" ]] || { echo "amp $v: version check failed" >&2; exit 1; }
  ' amp_fetch "$1" "$2" "$AMP_CLI_BASE" "$AMP_CALL_TIMEOUT"
}

amp_cli() {
  say "amp-cli"
  check_pin
  local want have rc=0
  want=$(pin_get amp_cli)
  have=$(host_amp "$HOST_AMP" --version 2>/dev/null) || rc=$?
  ((rc != 124)) || die "$HOST_AMP --version timed out after ${AMP_CALL_TIMEOUT} s; not reinstalling over it (check it by hand)"
  have=${have%% *}
  if [[ $have == "$want" ]]; then
    echo "Amp CLI $want (pinned) installed"
  else
    echo "installing pinned Amp CLI $want (have: ${have:-none})"
    amp_fetch "$want" "$HOST_AMP"
  fi
  # Self-update off; updates happen only through update-orbs. The provider unit
  # also sets AMP_SKIP_UPDATE_CHECK=1.
  as_agent python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/amp/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
s = json.load(open(p)) if os.path.exists(p) else {}
if s.get("amp.updates.mode") != "disabled":
    s["amp.updates.mode"] = "disabled"
    json.dump(s, open(p, "w"), indent=2)
    print("set amp.updates.mode = disabled")
PY
}

# Patch on top of Amp's image (docs/design-notes.md):
# 1. sbx grants a sandbox Docker-in-Docker privileges (netfilter,
#    /var/lib/docker volume) only when the image carries this label, but starts
#    dockerd in every sandbox; without it the engine dies and sbx refuses exec.
# 2. Amp's daemon.json forces the systemd cgroup driver, which needs systemd as
#    PID 1; under sbx PID 1 is sh, so `docker run` fails. Use cgroupfs and keep
#    Amp's cgroup-parent. Heredoc COPY: no build context, no USER switch.
# 3 (patch rev 3): /usr/bin/git is Debian's 2.39.5 while PATH git is Amp's
#    /opt/git/bin/git (2.55); tests that hardcode /usr/bin/git need >= 2.40.
#    Make /usr/bin/git a symlink to /opt/git/bin/git (it finds its own
#    helpers via its exec-path); the image's default user stays `user`.
# orb_dockerfile DIGEST [PATCH_REV]: the recipe of that revision.
orb_dockerfile() {
  local rev=${2:-$ORB_PATCH_REV}
  cat <<EOF
FROM $AMP_ORB_REPO@$1
LABEL com.docker.sandboxes.start-docker=true
COPY <<'JSON' /etc/docker/daemon.json
{
	"cgroup-parent": "amp-workload.slice",
	"exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON
EOF
  if ((rev >= 3)); then
    cat <<'EOF'
USER root
RUN test -x /opt/git/bin/git && ln -sf /opt/git/bin/git /usr/bin/git && /usr/bin/git --version
USER user
EOF
  fi
}

# Build the template for $PIN unless it is already loaded.
orb_image() {
  say "orb-image ($(basename "$PIN"))"
  check_pin
  local digest template
  digest=$(pin_get digest)
  template=$(pin_get template)
  if as_agent sbx template ls -q </dev/null | grep -qxF "$template"; then
    echo "$template already loaded"
    return
  fi

  # Host room: builder VM disk (~8 GB unpacked image + layer), the ~2 GB tar,
  # and the loaded template.
  local free_gb
  free_gb=$(df -BG --output=avail /home/agent | tail -1 | tr -dc 0-9)
  ((free_gb >= ORB_BUILD_MIN_FREE_GB)) ||
    die "orb-image: only ${free_gb} GB free on /home/agent; need ${ORB_BUILD_MIN_FREE_GB} GB"

  # No Docker on the host: build on the Docker engine of a throwaway sandbox,
  # export, load into sbx. The tar goes in agent's home, not /tmp (tmpfs = RAM).
  local builder=orb-image-build tmpdir
  tmpdir=$(as_agent mktemp -d -p /home/agent .orb-image.XXXXXX)
  # shellcheck disable=SC2064
  trap "as_agent sbx rm --force $builder >/dev/null 2>&1 || true; as_agent rm -rf '$tmpdir'" EXIT
  trap 'exit 130' INT TERM
  as_agent sbx rm --force "$builder" >/dev/null 2>&1 || true

  # Adding a file unpacks Amp's whole image (~8 GB), more than the default
  # 10 GB /var/lib/docker volume. Enlarge it for the builder only, via sbx's
  # per-sandbox override; the global sandbox.disk.dockerVolume is not touched.
  local global_before docker_gb
  global_before=$(as_agent sbx settings get sandbox.disk.dockerVolume)
  as_agent env DOCKER_SANDBOXES_DOCKER_SIZE="$ORB_BUILD_DOCKER_SIZE" \
    sbx create shell --name "$builder" --cpus 4 --memory 4g --no-progress
  [[ $(as_agent sbx settings get sandbox.disk.dockerVolume) == "$global_before" ]] ||
    die "orb-image: global sandbox.disk.dockerVolume changed from $global_before"
  docker_gb=$(as_agent sbx exec "$builder" df -BG --output=size /var/lib/docker </dev/null | tail -1 | tr -dc 0-9)
  ((docker_gb >= ${ORB_BUILD_DOCKER_SIZE%g} - 1)) ||
    die "orb-image: builder got a ${docker_gb} GB docker volume, not $ORB_BUILD_DOCKER_SIZE"
  # Scoped to the builder only; removed with it.
  as_agent sbx policy allow network --sandbox "$builder" "${AMP_ORB_REPO%%/*}"
  orb_dockerfile "$digest" "$(pin_get patch)" |
    as_agent sbx exec -i "$builder" docker build --platform linux/amd64 -q -t "$template" -
  as_agent sbx exec "$builder" docker save -o /tmp/amp-orb.tar "$template" </dev/null
  as_agent sbx cp "$builder:/tmp/amp-orb.tar" "$tmpdir/"
  as_agent sbx template load "$tmpdir/amp-orb.tar"

  as_agent sbx rm --force "$builder"
  as_agent rm -rf "$tmpdir"
  trap - EXIT INT TERM
  echo "loaded $template"
}

orb_provider() {
  say "orb-provider"
  check_pin
  sudo install -d -m 0755 -o agent -g agent "$HOST_ORB"
  local f
  for f in dispatch.sh provider.sh dryrun.sh drift.sh canary.sh trimlogs.sh; do
    install_file "$HERE/$f" "$HOST_ORB/$f" 0755 agent || true
  done
  install_file "$AMP_ORB_PIN_FILE" "$HOST_ORB/amp-orb.pin" 0644 agent || true
  if [[ -f $AMP_ORB_PIN_PREVIOUS ]]; then
    install_file "$AMP_ORB_PIN_PREVIOUS" "$HOST_ORB/amp-orb.pin.previous" 0644 agent || true
  fi
  if install_file "$HERE/systemd/amp-orb-provider.service" \
      /etc/systemd/system/amp-orb-provider.service 0644 root; then
    sudo systemctl daemon-reload
    echo "unit changed: restart the provider to apply (sudo systemctl restart amp-orb-provider)"
  fi
  echo "orb-provider files in place"
}

canary() {
  say "canary"
  local changed=0 u
  for u in amp-orb-canary.service amp-orb-canary.timer; do
    install_file "$HERE/systemd/$u" "/etc/systemd/system/$u" 0644 root && changed=1 || true
  done
  ((changed)) && sudo systemctl daemon-reload
  sudo systemctl enable --now amp-orb-canary.timer >/dev/null 2>&1
  echo "next canary: $(systemctl show -p NextElapseUSecRealtime --value amp-orb-canary.timer)"
}

canary_run() {
  say "canary-run"
  local rc=0
  sudo systemctl start amp-orb-canary.service || rc=$?
  journalctl -q -o cat -u amp-orb-canary.service \
    _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value amp-orb-canary.service)" |
    grep -E '^(### |FAIL|ok |INFO|canary|DRY RUN|TIMING)' || true
  return $rc
}

# Re-pin to upstream (or keep parts), build + test the candidate, switch only
# on success. UPDATE_IMAGE=keep / UPDATE_CLI=keep hold that part at the current
# pin; a patch-rev bump alone (ORB_PATCH_REV > pin's patch) is also an update.
update_orbs() {
  say "update-orbs"
  check_pin
  local cur_digest cur_cli cur_patch new_digest new_cli
  cur_digest=$(pin_get digest) cur_cli=$(pin_get amp_cli) cur_patch=$(pin_get patch)
  if [[ ${UPDATE_IMAGE:-latest} == keep ]]; then new_digest=$cur_digest; else new_digest=$(upstream_digest); fi
  if [[ ${UPDATE_CLI:-latest} == keep ]]; then new_cli=$cur_cli; else new_cli=$(upstream_cli); fi
  [[ $new_digest == sha256:* && -n $new_cli ]] || die "could not read upstream versions"
  echo "current:   image $cur_digest, patch $cur_patch, CLI $cur_cli"
  echo "candidate: image $new_digest, patch $ORB_PATCH_REV, CLI $new_cli" \
    "(image ${UPDATE_IMAGE:-latest}, CLI ${UPDATE_CLI:-latest})"
  if [[ $new_digest == "$cur_digest" && $new_cli == "$cur_cli" && $ORB_PATCH_REV == "$cur_patch" ]]; then
    echo "already up to date"
    return
  fi

  # 1. candidate pin, template and CLI binary (nothing live changes yet)
  write_pin "$AMP_ORB_PIN_CANDIDATE" "$new_digest" "$new_cli"
  PIN=$AMP_ORB_PIN_CANDIDATE orb_image
  if [[ $new_cli == "$cur_cli" ]]; then
    echo "Amp CLI unchanged ($new_cli); candidate is a copy of the current binary"
    as_agent cp -p "$HOST_AMP" "$HOST_AMP.candidate"
  else
    echo "fetching candidate Amp CLI $new_cli"
    amp_fetch "$new_cli" "$HOST_AMP.candidate"
  fi
  host_amp "$HOST_AMP.candidate" orb provider --help >/dev/null
  install_file "$AMP_ORB_PIN_CANDIDATE" "$HOST_ORB/amp-orb.pin.candidate" 0644 agent || true

  # 2. canary gate: the dispatch dry run on the candidate template
  say "update-orbs: canary on candidate"
  if ! as_agent env ORB_PIN="$HOST_ORB/amp-orb.pin.candidate" "$HOST_ORB/dryrun.sh" </dev/null; then
    as_agent rm -f "$HOST_AMP.candidate" "$HOST_ORB/amp-orb.pin.candidate"
    rm -f "$AMP_ORB_PIN_CANDIDATE"
    die "canary failed on the candidate; nothing switched (candidate template kept for inspection: $(pin_get template "$HOST_ORB/amp-orb.pin.candidate" 2>/dev/null || true))"
  fi

  # 3. switch: current becomes previous, candidate becomes current
  say "update-orbs: switching"
  cp "$AMP_ORB_PIN_FILE" "$AMP_ORB_PIN_PREVIOUS"
  mv "$AMP_ORB_PIN_CANDIDATE" "$AMP_ORB_PIN_FILE"
  if [[ $new_cli != "$cur_cli" ]]; then
    as_agent bash -c "cp -p $HOST_AMP $HOST_AMP.previous && mv -f $HOST_AMP.candidate $HOST_AMP"
  else
    # Same version: leave the live binary file alone (replacing it would make
    # the running provider's executable "(deleted)").
    as_agent bash -c "cp -p $HOST_AMP $HOST_AMP.previous && rm -f $HOST_AMP.candidate"
  fi
  as_agent rm -f "$HOST_ORB/amp-orb.pin.candidate"
  install_file "$AMP_ORB_PIN_FILE" "$HOST_ORB/amp-orb.pin" 0644 agent || true
  install_file "$AMP_ORB_PIN_PREVIOUS" "$HOST_ORB/amp-orb.pin.previous" 0644 agent || true
  # The dispatch reads the pin on every job; only a new CLI needs a restart
  # (which would pause running orbs).
  if [[ $new_cli != "$cur_cli" ]]; then
    restart_provider
    if ! provider_started_with "$new_cli"; then
      echo "provider did not start on $new_cli within 30 s; rolling back" >&2
      rollback_orbs
      die "update-orbs rolled back"
    fi
  else
    echo "Amp CLI unchanged: provider not restarted (the dispatch reads the new pin on its next job)"
  fi
  as_agent timeout -k 5 60 "$HOST_ORB/drift.sh" </dev/null || true
  prune_orb_templates
  echo "switched to $new_cli / $(pin_get template). Commit $AMP_ORB_PIN_FILE and $AMP_ORB_PIN_PREVIOUS."
  echo "rollback: ./setup.sh rollback-orbs"
}

# Swap current and previous (so running it twice rolls forward again).
rollback_orbs() {
  say "rollback-orbs"
  [[ -f $AMP_ORB_PIN_PREVIOUS ]] || die "no previous pin ($AMP_ORB_PIN_PREVIOUS)"
  check_pin "$AMP_ORB_PIN_PREVIOUS"
  local prev_tpl prev_cli
  prev_tpl=$(pin_get template "$AMP_ORB_PIN_PREVIOUS") prev_cli=$(pin_get amp_cli "$AMP_ORB_PIN_PREVIOUS")
  as_agent sbx template ls -q </dev/null | grep -qxF "$prev_tpl" || die "previous template $prev_tpl is gone"
  as_agent test -x "$HOST_AMP.previous" || die "no previous Amp CLI binary ($HOST_AMP.previous)"
  [[ $(host_amp "$HOST_AMP.previous" --version | cut -d' ' -f1) == "$prev_cli" ]] ||
    die "$HOST_AMP.previous is not $prev_cli"

  local t
  t=$(mktemp)
  cp "$AMP_ORB_PIN_FILE" "$t"
  cp "$AMP_ORB_PIN_PREVIOUS" "$AMP_ORB_PIN_FILE"
  mv "$t" "$AMP_ORB_PIN_PREVIOUS"
  if [[ $prev_cli != "$(pin_get amp_cli "$AMP_ORB_PIN_PREVIOUS")" ]]; then
    as_agent bash -c "mv -f $HOST_AMP $HOST_AMP.swap && mv -f $HOST_AMP.previous $HOST_AMP && mv -f $HOST_AMP.swap $HOST_AMP.previous"
  fi
  install_file "$AMP_ORB_PIN_FILE" "$HOST_ORB/amp-orb.pin" 0644 agent || true
  install_file "$AMP_ORB_PIN_PREVIOUS" "$HOST_ORB/amp-orb.pin.previous" 0644 agent || true
  if [[ $prev_cli != "$(pin_get amp_cli "$AMP_ORB_PIN_PREVIOUS")" ]]; then
    restart_provider
    provider_started_with "$prev_cli" || echo "WARNING: provider did not announce $prev_cli within 30 s" >&2
  else
    echo "Amp CLI unchanged: provider not restarted"
  fi
  as_agent timeout -k 5 60 "$HOST_ORB/drift.sh" </dev/null || true
  echo "now on $prev_cli / $prev_tpl. Commit $AMP_ORB_PIN_FILE and $AMP_ORB_PIN_PREVIOUS."
}

# Keep only the current and previous orb templates, and only prune when no orb
# sandbox exists (an existing orb may have been created from an older one).
prune_orb_templates() {
  local keep_cur keep_prev t
  keep_cur=$(pin_get template "$AMP_ORB_PIN_FILE")
  keep_prev=$(pin_get template "$AMP_ORB_PIN_PREVIOUS" 2>/dev/null || true)
  if as_agent sbx ls -q </dev/null | grep -q '^amp-'; then
    echo "orb sandboxes exist; not pruning old templates (see ./setup.sh status)"
    return
  fi
  for t in $(as_agent sbx template ls -q </dev/null | grep '^localhost/amp-orb:' || true); do
    [[ $t == "$keep_cur" || $t == "$keep_prev" ]] && continue
    as_agent sbx template rm --force "$t" </dev/null
  done
}

# The first half of status: what is pinned, installed and running.
status_versions() {
  local cli running inv rc=0
  cli=$(host_amp "$HOST_AMP" --version 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    124) cli="timed out after ${AMP_CALL_TIMEOUT} s" ;;
    126 | 127) cli="not installed" ;;
    *) cli="failed (exit $rc)" ;;
  esac
  inv=$(systemctl show -p InvocationID --value amp-orb-provider 2>/dev/null)
  if [[ $(systemctl is-active amp-orb-provider 2>/dev/null) == active && -n $inv ]]; then
    running=$(journalctl -q -o cat _SYSTEMD_INVOCATION_ID="$inv" 2>/dev/null |
      sed -n 's/.*Orb provider started.*"spawnerVersion":"\([^"]*\)".*/\1/p' | tail -1)
    running=${running:-"running (version not in journal)"}
  else
    running="not running"
  fi
  printf '%-26s %s\n' "Amp CLI pinned:" "$(pin_get amp_cli)"
  printf '%-26s %s\n' "Amp CLI (host, agent):" "$cli"
  printf '%-26s %s\n' "Amp provider (running):" "$running"
  printf '%-26s %s\n' "Orb image pinned:" "$(pin_get digest)"
  printf '%-26s %s\n' "Orb template:" "$(pin_get template)"
  [[ -f $AMP_ORB_PIN_PREVIOUS ]] &&
    printf '%-26s %s\n' "Rollback target:" "$(pin_get amp_cli "$AMP_ORB_PIN_PREVIOUS") / $(pin_get template "$AMP_ORB_PIN_PREVIOUS")"
}

# The second half: drift check, orb sandboxes, stale templates.
status_orbs() {
  echo "-- drift check (same as the daily canary):"
  # Bounded too: the installed drift.sh may still have a bare `amp --version`.
  local drc=0
  as_agent timeout -k 5 60 "$HOST_ORB/drift.sh" </dev/null | sed 's/^/   /' || drc=$?
  if ((drc == 124 || drc == 137)); then echo "   drift check: timed out after 60 s"; fi

  # Orb sandboxes are named amp-<thread id>. Long-running orbs persist until
  # Amp sends delete, so one Amp no longer knows about is an orphan.
  local orbs
  # Type comes from the dispatch's ~agent/orb/run/<orb>.type (sbx doesn't keep
  # it); CPU and memory are what sbx actually gave the sandbox.
  orbs=$(as_agent bash -c 'sbx ls --format json </dev/null | python3 -c "
import json, os, sys
for s in json.load(sys.stdin):
    n = s.get(\"name\", \"\")
    if not n.startswith(\"amp-\"):
        continue
    try:
        t = open(os.path.expanduser(\"~/orb/run/\" + n + \".type\")).read().split()
        kind, docker = t[0], t[3]
    except (OSError, IndexError):
        kind, docker = \"type unknown\", \"?\"
    print(\"%s (%s, %s: %s CPU, %s MiB, %s Docker)\" % (n, s.get(\"status\", \"?\"), kind, s.get(\"cpus\", \"?\"), s.get(\"memory_mib\", \"?\"), docker))
"')
  if [[ -n $orbs ]]; then
    printf '%-26s %s\n' "Orb sandboxes:" "$(sed -n 1p <<<"$orbs")"
    sed -n '2,$p' <<<"$orbs" | sed 's/^/                           /'
    echo "                           (check each against live threads in Amp; delete orphans with the dispatch's delete)"
  else
    printf '%-26s %s\n' "Orb sandboxes:" "none"
  fi
  local stale keep_prev
  keep_prev=$(pin_get template "$AMP_ORB_PIN_PREVIOUS" 2>/dev/null || true)
  stale=$(as_agent sbx template ls -q </dev/null | grep '^localhost/amp-orb:' |
    grep -vxF "$(pin_get template)" | grep -vxF "${keep_prev:-none}" || true)
  [[ -z $stale ]] || printf '%-26s %s\n' "Stale orb templates:" "$(echo $stale) (sbx template rm --force once no orb uses them)"
}

[[ $# -gt 0 ]] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2; exit 2; }
while (($#)); do
  s=$1; shift
  case $s in
    amp-cli) amp_cli ;;
    orb-image) orb_image ;;
    orb-provider) orb_provider ;;
    canary) canary ;;
    canary-run) canary_run ;;
    update-orbs) update_orbs ;;
    rollback-orbs) rollback_orbs ;;
    status)
      say "status"
      status_versions
      status_orbs
      echo "-- timers:"
      systemctl list-timers --no-pager amp-orb-canary.timer 2>/dev/null | sed -n '1,2p' | sed 's/^/   /'
      ;;
    status-versions) status_versions ;;
    status-orbs) status_orbs ;;
    *) echo "unknown section: $s" >&2; exit 2 ;;
  esac
done
