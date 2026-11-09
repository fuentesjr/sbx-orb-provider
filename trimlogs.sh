#!/usr/bin/env bash
# Keep ~30 days of the dispatch's history logs in ~/orb/run (pause-time
# /usr/bin/git record, Amp secret-name record). Run by canary.sh, as agent.
# Lines start with a UTC timestamp (2026-11-03T05:03:24Z); older lines and
# lines without one are dropped. flock matches the dispatch's appends.
set -euo pipefail
days=${TRIM_DAYS:-30}
cutoff=$(date -u -d "-$days days" +%FT%TZ)
for f in "${@:-$HOME/orb/run/usr-bin-git.log $HOME/orb/run/amp-secret-names.log}"; do
  for log in $f; do
    [[ -f $log ]] || continue
    (
      flock -w 60 9 || { echo "trimlogs: lock busy: $log" >&2; exit 0; }
      before=$(wc -l <"$log")
      awk -v c="$cutoff" '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ && $1 >= c' "$log" >"$log.tmp"
      mv -f "$log.tmp" "$log"
      echo "trimlogs: $(basename "$log"): kept $(wc -l <"$log") of $before lines (cutoff $cutoff)"
    ) 9>"$log.lock"
  done
done
