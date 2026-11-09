#!/usr/bin/env bash
# Daily orb canary (its systemd service, as agent): dry run of the
# dispatch (spawn, pause, resume, delete a test orb) plus the drift check.
# Exit non-zero on any failure; the unit's OnFailure= mails the log.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
# Housekeeping first, so it runs even if the dry run fails.
"$here/trimlogs.sh" || echo "trimlogs failed (not fatal)"
echo "### canary $(date -u +%FT%TZ): orb dry run"
if ! "$here/dryrun.sh" </dev/null; then
  echo "FAIL: canary step: orb dry run"
  exit 1
fi
echo "### canary: version drift"
if ! "$here/drift.sh"; then
  echo "FAIL: canary step: version drift"
  exit 1
fi
echo "canary passed"
