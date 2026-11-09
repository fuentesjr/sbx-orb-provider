#!/usr/bin/env bash
# Sample one real orb's memory while it works (sizing, memory cap).
# Run as an admin user: ./loadsample.sh LOGFILE. Read-only: ps on the host, and short
# `sbx exec` reads inside the orb (/proc/meminfo, docker stats).
#   - waits up to 2 h for a running amp-* orb (not the canary's amp-dryrun*)
#   - every 5 s: host RSS of all sbx nerdbox VM processes (one orb running =
#     that orb), plus host MemAvailable
#   - every 30 s: guest MemTotal/MemAvailable and per-container memory
#   - stops when the orb is stopped/gone for 15 s, or after 3 h
set -uo pipefail
log=${1:?usage: loadsample.sh LOGFILE}
as_agent() { sudo -u agent -H bash -c 'cd ~ && exec "$@"' as_agent "$@" </dev/null; }
orbs() { as_agent sbx ls --format json | python3 -c 'import json,sys; [print(s["name"], s["status"]) for s in json.load(sys.stdin) if s["name"].startswith("amp-") and not s["name"].startswith("amp-dryrun")]'; }

echo "# $(date -u +%FT%TZ) waiting for an orb" >"$log"
orb=
for _ in $(seq 1440); do
  orb=$(orbs | awk '$2=="running"{print $1; exit}')
  [[ -n $orb ]] && break
  sleep 5
done
[[ -n $orb ]] || { echo "# no orb appeared within 2 h" >>"$log"; exit 1; }
echo "# $(date -u +%FT%TZ) sampling $orb" >>"$log"
echo "# host: time vm_procs vm_rss_mib host_avail_mib | guest: time guest_total_mib guest_avail_mib containers..." >>"$log"

gone=0 i=0 end=$((SECONDS + 3 * 3600))
while ((SECONDS < end)); do
  st=$(orbs | awk -v o="$orb" '$1==o{print $2}')
  if [[ $st != running ]]; then
    ((++gone >= 3)) && { echo "# $(date -u +%FT%TZ) $orb ${st:-gone}; done" >>"$log"; break; }
  else
    gone=0
  fi
  printf 'host %s %s %s\n' "$(date -u +%T)" \
    "$(ps -u agent -o rss=,args= | awk '/nerdbox/ && !/awk/ {s+=$1; n++} END {printf "%d %d", n, s/1024}')" \
    "$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)" >>"$log"
  if ((i++ % 6 == 0)) && [[ $st == running ]]; then
    printf 'guest %s %s | %s\n' "$(date -u +%T)" \
      "$(as_agent sbx exec "$orb" awk '/^MemTotal|^MemAvailable/{printf "%d ", $2/1024}' /proc/meminfo 2>/dev/null)" \
      "$(as_agent sbx exec "$orb" docker stats --no-stream --format '{{.Name}}={{.MemUsage}}' 2>/dev/null | cut -d/ -f1 | tr '\n' ' ')" >>"$log"
  fi
  sleep 5
done
echo "# $(date -u +%FT%TZ) end" >>"$log"
