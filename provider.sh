#!/usr/bin/env bash
# Start `amp orb provider` for amp-orb-provider.service (as agent).
# The token comes from systemd's decrypted credential (TPM-bound, host+tpm2)
# and lives only in this process's environment. dispatch.sh unsets it.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")

AMP_ORB_PROVIDER_TOKEN=$(<"${CREDENTIALS_DIRECTORY:?not run by systemd}/amp-orb-provider-token")
export AMP_ORB_PROVIDER_TOKEN

# Offer our patched template as the provider's image override; the dispatch
# still checks it is a local template before using it.
ORB_IMAGE=$(sed -n 's/^template=//p' "$here/amp-orb.pin")
export ORB_IMAGE

exec /home/agent/.amp/bin/amp orb provider "$here/dispatch.sh"
