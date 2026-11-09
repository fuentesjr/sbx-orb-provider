#!/usr/bin/env bash
# Version-drift check for the orb stack, run as agent (canary, ./install.sh status).
# FAIL (exit 1) only when something is actually wrong; a newer upstream Amp
# CLI or orb image is reported as INFO, since updates happen on the operator's schedule
# via ./install.sh update-orbs.
set -uo pipefail
PIN=${ORB_PIN:-$HOME/orb/amp-orb.pin}
REPO=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb
AMP=$HOME/.amp/bin/amp
pin() { sed -n "s/^$1=//p" "$PIN"; }
rc=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; rc=1; }
info() { printf 'INFO  %s\n' "$*"; }

digest=$(pin digest) template=$(pin template) cli=$(pin amp_cli)
[[ -n $digest && -n $template && -n $cli ]] || { bad "pin $PIN lacks digest/template/amp_cli"; exit 1; }

# 1. pinned template present locally
if sbx template ls -q </dev/null | grep -qxF "$template"; then ok "orb template $template loaded"
else bad "orb template $template missing (./install.sh orb-image)"; fi

# 2. pinned image still resolvable upstream (a rebuild or new machine needs it)
code=$(curl -fsS -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://${REPO%%/*}/v2/${REPO#*/}/manifests/$digest" 2>/dev/null || true)
[[ $code == 200 ]] && ok "pinned orb image $digest still upstream" || bad "pinned orb image $digest not resolvable upstream (HTTP ${code:-none})"

# 3. installed CLI is the pinned one
# (no update check, no stdin, bounded: a bare `amp --version` once hung for good)
vrc=0
have=$(AMP_SKIP_UPDATE_CHECK=1 timeout -k 5 15 "$AMP" --version </dev/null 2>/dev/null) || vrc=$?
have=${have%% *}
if ((vrc == 124 || vrc == 137)); then bad "installed Amp CLI: --version timed out after 15 s"
elif [[ $have == "$cli" ]]; then ok "installed Amp CLI $have = pin"
else bad "installed Amp CLI ${have:-missing} != pin $cli (self-update or manual change?)"; fi

# 4. provider running, on the installed binary, with self-update off
pid=$(systemctl show -p MainPID --value amp-orb-provider 2>/dev/null)
if [[ $(systemctl is-active amp-orb-provider 2>/dev/null) != active || ${pid:-0} -eq 0 ]]; then
  bad "amp-orb-provider not running"
else
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  if [[ $exe != *"(deleted)" ]]; then
    ok "provider runs $exe"
  elif cmp -s "/proc/$pid/exe" "$AMP"; then
    ok "provider runs an identical copy of $AMP (file replaced, same content)"
  else
    bad "provider runs a replaced binary ($exe) that differs from $AMP; restart it"
  fi
  if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx 'AMP_SKIP_UPDATE_CHECK=1'; then ok "provider has AMP_SKIP_UPDATE_CHECK=1"
  else bad "provider lacks AMP_SKIP_UPDATE_CHECK=1"; fi
fi
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("amp.updates.mode")=="disabled" else 1)' \
  "$HOME/.config/amp/settings.json" 2>/dev/null && ok "amp.updates.mode = disabled" || bad "amp.updates.mode not disabled in ~/.config/amp/settings.json"

# 6. /usr/bin/git in real orbs, recorded by the dispatch at each pause (after
#    bootstrap and Amp's setup): < 2.40 in an orb from the current template
#    means something undid patch 3. Orbs from older templates are only listed.
gl=$HOME/orb/run/usr-bin-git.log
if [[ -f $gl ]]; then
  since=$(date -u -d '-1 day' +%FT%TZ)
  while read -r ts orb from v; do
    [[ $ts > $since && $orb != amp-dryrun* ]] || continue
    if [[ $(printf '%s\n' 2.40 "$v" | sort -V | head -1) == 2.40 ]]; then continue; fi
    if [[ $from == "$template" ]]; then bad "/usr/bin/git $v (< 2.40) in $orb at $ts, created from the current template"
    else info "/usr/bin/git $v in $orb at $ts (created from older ${from}; recreate its thread to get patch 3)"; fi
  done < <(sort -u "$gl")
fi
# 7. Secret NAMES in real orbs' agent environment (recorded by the dispatch at
#    each pause from AMP_SECRET_ENV_NAMES), as defense in depth. Any name
#    outside ALLOWED_SECRET_NAMES in an orb in the last 24 h is a failure, and
#    so a mail.
#    The list is host-specific: set ALLOWED_SECRET_NAMES=NAME1,NAME2 in
#    ~/orb/drift.env (not installed by install.sh). A file, not the
#    environment, because install.sh runs this through sudo, which drops the
#    environment. Empty by default, so any secret name fails until listed.
[[ -f $HOME/orb/drift.env ]] && . "$HOME/orb/drift.env"
ALLOWED_SECRET_NAMES=${ALLOWED_SECRET_NAMES:-}
sl=${SECRETNAMES_LOG:-$HOME/orb/run/amp-secret-names.log}
if [[ -f $sl ]]; then
  # no-agent = not checked (no agent process at that pause): never a pass.
  # none = checked, agent had no secret names.
  since=$(date -u -d '-1 day' +%FT%TZ) n=0 nc=0 extra=
  while read -r ts orb names; do
    [[ $ts > $since && $orb != amp-dryrun* ]] || continue
    if [[ $names == no-agent ]]; then nc=$((nc + 1)); continue; fi
    n=$((n + 1))
    [[ $names == none ]] && continue
    for nm in ${names//,/ }; do
      [[ ,$ALLOWED_SECRET_NAMES, == *",$nm,"* ]] || extra+=" $nm($orb $ts)"
    done
  done < <(sort -u "$sl")
  if [[ -n $extra ]]; then bad "orb agents have secret env names outside the allow-list ($ALLOWED_SECRET_NAMES):$extra"
  elif ((n)); then ok "Amp secret env names checked in $n orb record(s), last 24 h: none outside the allow-list (${ALLOWED_SECRET_NAMES:-empty})$( ((nc)) && echo " (plus $nc not checked: no agent at pause)")"
  elif ((nc)); then info "Amp secret env names not checked: $nc record(s) in the last 24 h had no agent running at pause"
  fi
fi
# 5. Desktop's UDP relies on an experimental sbx flag that an update could drop
sbx settings get feature.udp-egress </dev/null 2>/dev/null | grep -q '"enabled":true' \
  && ok "sbx feature.udp-egress enabled" || bad "sbx feature.udp-egress not enabled (Desktop UDP blocked)"

# INFO: newer upstream versions
latest_cli=$(curl -fsS https://static.ampcode.com/cli/cli-version.txt 2>/dev/null || true)
latest_img=$(curl -fsS -o /dev/null -D - -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://${REPO%%/*}/v2/${REPO#*/}/manifests/latest" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
[[ -n $latest_cli && $latest_cli != "$cli" ]] && info "newer Amp CLI upstream: $latest_cli (./install.sh update-orbs)"
[[ -n $latest_img && $latest_img != "$digest" ]] && info "newer orb image upstream: $latest_img (./install.sh update-orbs)"
exit $rc
