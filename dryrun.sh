#!/usr/bin/env bash
# Local dry run of the orb dispatch, no Amp involved. Installed by install.sh as
# ~agent/orb/dryrun.sh; run as agent with stdin closed (sbx exec reads stdin):
#   sudo -u agent -H ~agent/orb/dryrun.sh </dev/null
# Uses a fake ORB_TOKEN, so `amp orb bootstrap` fails auth; that is expected.
# ORB_PIN selects the pin (default ~/orb/amp-orb.pin); update-orbs passes a
# candidate. Leaves nothing behind, also on failure: the EXIT trap deletes the
# test orb (via the dispatch, so its keep-alive goes too) and its snapshot.
set -euo pipefail
cd ~
D=~/orb/dispatch.sh
ID=amp-dryrun
SMALL=amp-dryrun-small
SNAP=dryrun-snap
export ORB_PIN=${ORB_PIN:-$HOME/orb/amp-orb.pin}
PINNED=$(sed -n 's/^template=//p' "$ORB_PIN")
[[ -n $PINNED ]] || { echo "FAIL: no template= in $ORB_PIN"; exit 1; }
# One dry run at a time (daily canary vs. update-orbs share the test orb).
mkdir -p ~/orb/run
exec 8>~/orb/run/dryrun.lock
flock -w 900 8 || { echo "FAIL: another dry run holds ~/orb/run/dryrun.lock"; exit 1; }
STOCK=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest
export ORB_TOKEN=dryrun-not-a-token

step() { printf '\n### %s\n' "$*"; }
run() { # run OP [VAR=VALUE...]: time one dispatch job
  local op=$1 t0 ms rc=0; shift
  t0=$(date +%s%N)
  env ORB_OPERATION="$op" ORB_ID="${RUN_ID:-$ID}" "$@" "$D" || rc=$?
  ms=$((($(date +%s%N) - t0) / 1000000))
  printf 'TIMING %s %s: %d.%01d s (exit %d)\n' "$op" "$*" $((ms / 1000)) $((ms % 1000 / 100)) "$rc"
  return $rc
}
# Rules scoped to the test orb only, so a real orb spawning meanwhile can't
# make the counts wrong.
rules() { sbx policy ls --wide 2>/dev/null | grep -F "sandbox:${1:-$ID} " | awk '{print $(NF-1), $NF}' | sort || true; }
amp_check() { { sbx policy check network ${1:+--sandbox "$1"} ampcode.com:443 2>&1 || true; } | grep -E 'Allowed|Reason' | sed 's/^ */  /'; } # exits non-zero on deny
fail() { echo "FAIL: $*"; exit 1; }
# egress_check ORB: a host on neither allow list must get the proxy's 403, and
# sbx's log must show this request as blocked. Read the status with -w, not
# curl -I: the proxy answers CONNECT with 200 even for a denied host
# (docs/design-notes.md, "How a denied request looks"). The log outlives
# sandboxes of the same name, so only an entry from this run counts.
EGRESS_HOST=example.com
egress_logged() { # egress_logged ORB SINCE
  sbx policy log "$1" --json </dev/null 2>/dev/null | python3 -I -c '
import json, sys
sb, host, since = sys.argv[1:]
blocked = json.load(sys.stdin).get("blocked") or []
sys.exit(0 if any(e.get("sandbox_id") == sb and e.get("host") == host and e.get("last_seen", "")[:19] >= since for e in blocked) else 1)' "$1" "$EGRESS_HOST:443" "$2"
}
egress_check() {
  local t0 code _
  t0=$(date -u +%FT%T)
  code=$(sbx exec -u user "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$EGRESS_HOST" </dev/null) || true
  [[ $code == 403 ]] || fail "egress check: https://$EGRESS_HOST from $1 returned HTTP '${code:-none}', expected 403 (000: no answer through the proxy; anything else: the host may be reachable)"
  for _ in 1 2 3 4 5 6; do
    if egress_logged "$1" "$t0"; then
      echo "egress: $EGRESS_HOST denied with HTTP 403 and logged as blocked: yes"
      return 0
    fi
    sleep 2
  done
  fail "egress check: $1 got 403 from $EGRESS_HOST, but sbx policy log has no blocked $EGRESS_HOST:443 entry for it since $t0"
}
keepalives() { pgrep -u "$(id -u)" -f "sbx exec ${1:-$ID} sleep infinity" || true; }
# check_size ORB TYPE CPUS MEMORY_MIB DOCKER_GB: as created by the dispatch
# git_check ORB WHEN: patch 3, /usr/bin/git must be Git >= 2.40 and work.
git_check() {
  local gv
  gv=$(sbx exec "$1" /usr/bin/git --version | awk '{print $3}')
  [[ $(printf '%s\n' 2.40 "$gv" | sort -V | head -1) == 2.40 ]] || fail "/usr/bin/git is $gv $2, need >= 2.40"
  sbx exec -u user "$1" bash -c 'd=$(mktemp -d) && /usr/bin/git -C "$d" init -q && /usr/bin/git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m t && /usr/bin/git -C "$d" log --oneline | grep -q t && rm -rf "$d"' \
    || fail "/usr/bin/git can't init/commit $2"
  echo "/usr/bin/git $2: $gv (>= 2.40), init/commit work: yes"
}
check_size() {
  local got vol t
  got=$(sbx ls --format json | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["name"]==sys.argv[1]]; print(s[0]["cpus"], s[0]["memory_mib"]) if s else print("gone")' "$1")
  vol=$(sbx exec "$1" df -BG --output=size /var/lib/docker | tail -1 | tr -dc 0-9)
  t=$(cut -d' ' -f1 ~/orb/run/"$1".type 2>/dev/null || echo none)
  [[ $got == "$3 $4" ]] || fail "$1: expected $3 CPU / $4 MiB, got $got"
  ((vol >= $5 - 1 && vol <= $5 + 1)) || fail "$1: expected ~$5 GB Docker volume, got ${vol} GB"
  [[ $t == "$2" ]] || fail "$1: type file says $t, expected $2"
  # What the orb itself sees: vCPUs and guest RAM (MemTotal is a little under
  # the VM size; the guest kernel keeps some, so accept 85-100%).
  local in_cpus in_kb
  in_cpus=$(sbx exec "$1" nproc)
  in_kb=$(sbx exec "$1" awk '/^MemTotal:/{print $2}' /proc/meminfo)
  [[ $in_cpus == "$3" ]] || fail "$1: nproc inside is $in_cpus, expected $3"
  ((in_kb >= $4 * 1024 * 85 / 100 && in_kb <= $4 * 1024)) ||
    fail "$1: MemTotal inside is ${in_kb} kB, expected 85-100% of $(($4 * 1024)) kB"
  echo "$1: $2 = $3 CPU, $4 MiB, ${vol} GB Docker volume; inside: nproc $in_cpus, MemTotal $((in_kb / 1024)) MiB: yes"
}
cleanup() {
  local rc=$?
  trap - EXIT
  local o
  for o in "$ID" "$SMALL"; do
    env ORB_OPERATION=delete ORB_ID="$o" "$D" >/dev/null 2>&1 || sbx rm --force "$o" >/dev/null 2>&1 || true
  done
  sbx template rm --force "localhost/amp-orb-snapshot:$SNAP" >/dev/null 2>&1 || true
  rm -f /tmp/dryrun.8 /tmp/dryrun.9 /tmp/dryrun.9b
  for o in "$ID" "$SMALL"; do
    if grep -qxF "$o" <(sbx ls -q 2>/dev/null); then echo "FAIL: cleanup left sandbox $o"; rc=1; fi
    if [[ -n $(rules "$o") ]]; then echo "FAIL: cleanup left rules for $o"; rc=1; fi
    if [[ -n $(keepalives "$o") ]]; then echo "FAIL: cleanup left keep-alive for $o"; rc=1; fi
    if [[ -e ~/orb/run/$o.type ]]; then echo "FAIL: cleanup left type file for $o"; rc=1; fi
  done
  exit "$rc"
}
trap cleanup EXIT
no_keepalive() { [[ -z $(keepalives) ]] || fail "keep-alive still running after $1: $(keepalives)"; echo "no keep-alive left after $1: yes"; }
# sbx auto-stops a sandbox 30 s after its last session ends, unless the orb kit
# (long-running@1) applied. Wait past that and check it is still running.
idle_check() {
  echo "idle ${1}s with no session..."
  sleep "$1"
  sbx ls --format json | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["name"]=="'"$ID"'"]; print("status after idle:", s[0]["status"] if s else "gone"); sys.exit(0 if s and s[0]["status"]=="running" else 1)' \
    || fail "orb did not stay running without a session"
}

sbx rm --force "$ID" >/dev/null 2>&1 || true
sbx rm --force "$SMALL" >/dev/null 2>&1 || true
sbx template rm --force "localhost/amp-orb-snapshot:$SNAP" >/dev/null 2>&1 || true
[[ -z $(rules) && -z $(rules "$SMALL") ]] || fail "leftover rules for $ID or $SMALL before start"

step "1. spawn new large orb, Amp's stock ORB_IMAGE (expect image case 3)"
run spawn ORB_IMAGE="$STOCK" ORB_TYPE=large
grep -qxF "$ID" <(sbx ls -q) || fail "sandbox not created"
check_size "$ID" large 4 8192 20
git_check "$ID" "on the image"
echo "per-orb rule:"; amp_check "$ID"
echo "global:";       amp_check
rules | sed 's/^/  per-orb rule: /'
n=$(rules | wc -l); [[ $n -eq 4 ]] || fail "expected 4 per-orb rules, got $n"
udp_check() { { sbx policy check network --protocol udp ${1:+--sandbox "$1"} "$2" 2>&1 || true; } | grep -oE '^ *(Allowed|Denied)' | tr -d ' '; }
[[ $(udp_check "$ID" 104.30.136.165:21885) == Allowed ]] || fail "orb UDP to relay not allowed"
[[ $(udp_check "$ID" 203.0.113.10:27950) == Denied ]] || fail "orb UDP to viewer IP allowed"
[[ $(udp_check "" 104.30.136.165:21885) == Denied ]] || fail "global UDP to relay allowed"
echo "UDP: orb->relay Allowed, orb->viewer Denied, global->relay Denied: yes"
egress_check "$ID"
sbx exec "$ID" test -d /run/lock || fail "/run/lock missing after spawn"; echo "/run/lock after spawn: yes"
idle_check 45
echo "bootstrap detached and still running or ran:"
sbx exec -u user "$ID" bash -c 'pgrep -af "amp orb bootstrap" || echo "  (not running)"; tail -3 ~/.orb-bootstrap.log 2>/dev/null | sed "s/^/  log: /"'
sbx exec -u user "$ID" bash -c 'echo dryrun >~/marker'
# The dispatch must start the bootstrap without sbx's stand-in GH_TOKEN. The
# fake-token bootstrap may already have exited, so start the same command line
# the dispatch uses with a harmless probe in place of amp.
sbx exec -u user "$ID" bash -c 'setsid nohup env -u GH_TOKEN -u GITHUB_TOKEN sh -c "env > ~/.bootstrap-env" </dev/null >/dev/null 2>&1 & sleep 1; grep -q "^GH_TOKEN=" /proc/1/environ && echo "stand-in present in PID 1 (expected)"; ! grep -qE "^(GH_TOKEN|GITHUB_TOKEN)=" ~/.bootstrap-env' \
  || fail "bootstrap environment still has GH_TOKEN/GITHUB_TOKEN"
grep -qF 'env -u GH_TOKEN -u GITHUB_TOKEN amp orb bootstrap' "$D" || fail "dispatch does not unset GH_TOKEN for the bootstrap"
echo "bootstrap starts without GH_TOKEN/GITHUB_TOKEN: yes"
git_check "$ID" "after the bootstrap ran"

step "2. spawn again while running (repeat safety)"
run spawn ORB_IMAGE="$STOCK"

step "3. pause with snapshot"
run pause ORB_SNAPSHOT_ID="$SNAP"
sbx ls | grep "$ID"
# The dispatch records /usr/bin/git at pause (real orbs: after Amp's setup).
gl=$(grep " $ID " ~/orb/run/usr-bin-git.log | tail -1)
[[ $gl == *" $PINNED "* ]] || fail "pause did not record git for $ID from $PINNED: '$gl'"
v=${gl##* }; [[ $(printf '%s\n' 2.40 "$v" | sort -V | head -1) == 2.40 ]] || fail "pause recorded /usr/bin/git $v"
echo "pause recorded /usr/bin/git $v (from the pinned template): yes"
# The test orb never runs Amp's agent (fake token), so its secret-name record
# must say no-agent; "none" would mean the check matched something else.
sn=$(grep " $ID " ~/orb/run/amp-secret-names.log | tail -1 | awk '{print $3}')
[[ $sn == no-agent ]] || fail "pause recorded secret names '$sn' for an orb without an agent (expected no-agent)"
echo "pause recorded secret names: no-agent (no agent in the test orb): yes"
no_keepalive pause
sbx template ls -q | grep -xF "localhost/amp-orb-snapshot:$SNAP" || fail "snapshot template missing"

step "4. pause again (repeat safety)"
run pause ORB_SNAPSHOT_ID="$SNAP"

step "5. resume (spawn on stopped sandbox)"
run spawn ORB_IMAGE="$STOCK"
sbx exec -u user "$ID" cat /home/user/marker | grep -qx dryrun || fail "disk not kept across pause"
echo "disk kept across pause: yes"
sbx exec "$ID" test -d /run/lock || fail "/run/lock missing after resume"; echo "/run/lock after resume (fresh tmpfs): yes"
sbx exec "$ID" test ! -e /run/systemd/system || fail "/run/systemd/system exists"; echo "/run/systemd/system absent: yes"
git_check "$ID" "after resume (bootstrap ran again)"
idle_check 45

step "6. delete; per-orb rule must go with it"
run delete
no_keepalive delete
grep -qxF "$ID" <(sbx ls -q) && fail "sandbox still there"
[[ -z $(rules) ]] || fail "per-orb rules left after delete"; echo "per-orb rules gone: yes"

step "7. delete again (repeat safety)"
run delete

step "8. spawn from snapshot (expect image case 1)"
run spawn ORB_IMAGE="$STOCK" ORB_SNAPSHOT_ID="$SNAP" 2>&1 | tee /tmp/dryrun.8 >&2
grep -q "WARNING: ORB_TYPE unset; using large" /tmp/dryrun.8 || fail "no warning for unset ORB_TYPE"
check_size "$ID" large 4 8192 20
echo "ORB_TYPE unset: warned and used large: yes"
sbx exec -u user "$ID" cat /home/user/marker | grep -qx dryrun || fail "snapshot lacks marker"
echo "snapshot content restored: yes"
run delete

step "9. spawn with ORB_IMAGE = pinned template (expect image case 3, the pin)"
run spawn ORB_IMAGE="$PINNED" ORB_TYPE=bogus 2>&1 | tee /tmp/dryrun.9 >&2
grep -q "WARNING: unknown ORB_TYPE 'bogus'; using large" /tmp/dryrun.9 || fail "no warning for unknown ORB_TYPE"
check_size "$ID" large 4 8192 20
echo "ORB_TYPE=bogus: warned and used large: yes"
run delete

step "9b. stale provider override: ORB_IMAGE = previous template must still get the pin"
PREV=$(sed -n 's/^template=//p' ~/orb/amp-orb.pin.previous 2>/dev/null || true)
if [[ -n $PREV && $PREV != "$PINNED" ]] && sbx template ls -q | grep -qxF "$PREV"; then
  run spawn ORB_IMAGE="$PREV" ORB_TYPE=large 2>&1 | tee /tmp/dryrun.9b >&2
  grep -q "WARNING: ORB_IMAGE names $PREV, not the pinned $PINNED" /tmp/dryrun.9b || fail "no warning for stale ORB_IMAGE"
  [[ $(cut -d' ' -f5 ~/orb/run/"$ID".type) == "$PINNED" ]] || fail "stale ORB_IMAGE won: created from $(cut -d' ' -f5 ~/orb/run/"$ID".type)"
  git_check "$ID" "with a stale override"
  echo "stale ORB_IMAGE $PREV ignored, pinned template used: yes"
  run delete
else
  echo "(no separate previous template loaded; skipped)"
fi

step "10. spawn and delete a small orb"
RUN_ID=$SMALL run spawn ORB_IMAGE="$PINNED" ORB_TYPE=small
check_size "$SMALL" small 2 4096 10
n=$(rules "$SMALL" | wc -l); [[ $n -eq 4 ]] || fail "small orb: expected 4 per-orb rules, got $n"
RUN_ID=$SMALL run delete
[[ -z $(keepalives "$SMALL") && -z $(rules "$SMALL") ]] || fail "small orb left keep-alive or rules"
grep -qxF "$SMALL" <(sbx ls -q) && fail "small orb still there"
echo "small orb gone with its rules and keep-alive: yes"

no_keepalive "final delete"
step "11. cleanup"
sbx template rm --force "localhost/amp-orb-snapshot:$SNAP"
[[ -z $(rules) ]] || fail "per-orb rules left after delete"; echo "per-orb rules gone: yes"
echo "global:"; amp_check
echo; echo "DRY RUN PASSED"
