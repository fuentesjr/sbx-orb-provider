# sbx orb provider

Amp runs each thread's agent in a machine called an orb. This repo is a
self-hosted orb provider: it runs every orb in its own Docker Sandboxes (sbx)
microVM on a Linux host you control, with its own Docker and a network
limited to an allowlist. It's for people who use Amp's
[self-hosted orbs](https://ampcode.com/docs/orbs/self-hosted) and want each
thread isolated in a VM on their own hardware.

- **How it works:** the illustrated
  [walkthrough](https://fuentesjr.github.io/sbx-orb-provider/).
- **Why it's built this way:** [docs/design-notes.md](docs/design-notes.md).

This README covers two jobs: [using an orb](#use-an-orb) and
[running the host](#run-the-host). Lookup tables are in the
[reference](#reference).

| Term | Meaning |
|---|---|
| orb | The machine a thread's agent runs in. Here, an sbx sandbox named `amp-<thread id>`. |
| provider | `amp orb provider`, run by `amp-orb-provider.service` as the user `agent`. It receives jobs from Amp. |
| dispatch | `dispatch.sh`. The provider runs it once per job: spawn, pause or delete. |
| template | The pinned local sbx image a new orb boots from when its project has no snapshot: Amp's orb image plus this repo's patches. |
| pin | The file that names the template and the host's Amp CLI version. |
| canary | A daily check: a dry run of the dispatch on a test orb, then the drift check. |

## Use an orb

- **Web:** New Thread → the provider chip → your provider under Self-Hosted
  → optionally an orb type.
- **CLI:**

  ```sh
  amp -ox "<message>" --orb-provider <name> [--orb-size small]
  ```

The dispatch creates the orb, pauses it, resumes it on the thread's next
message, and deletes it when you delete the thread.

### Orb types

| Type | CPU | Memory | Docker volume | For |
|---|---|---|---|---|
| **large** (default) | 4 | 8 GB | 20 GB | most threads: the Rails suite with Postgres and Redis on the orb's own Docker |
| small | 2 | 4 GB | 10 GB | light threads: docs, small scripts, no service containers |

- The type is fixed when the orb is created. To change it, start a new
  thread.
- An unset or unknown type gets large, with a warning in the provider log.

### What every orb has

- Docker, for service containers.
- Amp's git at `/usr/bin/git`, not the base image's older one.
- No `GH_TOKEN` or `GITHUB_TOKEN` from sbx in Amp's bootstrap. sbx sets a
  stand-in `GH_TOKEN` in every sandbox; the dispatch removes it so that it
  can't override Amp's own GitHub token.
- A network limited to sbx's global policy plus Amp's own hosts. See
  [Network](#network) for what is and isn't reachable.

### How long an orb lives

- An orb exists, running or stopped with its disk kept, until you delete its
  thread.
- Orbs run only while the provider runs. If the provider restarts, running
  orbs pause and resume on the thread's next message.

## Run the host

Every `./install.sh` command needs `ORB_PIN_FILE` set to the absolute path
of the pin file. The examples assume you exported it, as install step 5
does.

### Install

You need:

- An x86-64 Linux host with systemd, and a user `agent` with the home
  directory `/home/agent`. The scripts and units use both names as written.
- An admin user with `sudo` to run `install.sh`, plus `curl` and `python3`.
- sbx, with its global network policy set to Balanced. The host needs no
  Docker of its own: the template is built inside a throwaway sandbox.
- 25 GB free on `/home/agent` for the template build.
- A self-hosted orb provider and its token, created in Amp.

Steps:

1. Run the sbx daemon as its own unit, `sbx-daemon.service`.
   [examples/sbx-daemon.service](examples/sbx-daemon.service) is a starting
   point for a host that runs nothing else on sbx.
2. Enable sbx's experimental UDP egress, which Amp's Desktop needs:

   ```sh
   sudo -u agent sbx settings set feature.udp-egress true
   ```

3. Store the provider token as an encrypted credential. With TPM binding,
   run this and give the token on standard input:

   ```sh
   sudo systemd-creds encrypt --with-key=host+tpm2 --name=amp-orb-provider-token \
     - /etc/credstore.encrypted/amp-orb-provider-token
   ```

4. Write the first pin file by hand. Copy
   [examples/amp-orb.pin.example](examples/amp-orb.pin.example) to where
   the host keeps its configuration, not into this repo. Its values are
   placeholders, so replace them as the [pin format](#pin-file) describes.
   These commands print the current upstream CLI version and image digest:

   ```sh
   curl -fsS https://static.ampcode.com/cli/cli-version.txt
   curl -fsS -o /dev/null -D - \
     -H 'Accept: application/vnd.oci.image.index.v1+json' \
     https://us-central1-docker.pkg.dev/v2/amp-prod-0/amp-orb/amp-orb/manifests/latest |
     grep -i '^docker-content-digest'
   ```

5. Install the Amp CLI, build the template, and install the scripts, the
   units and the canary timer:

   ```sh
   export ORB_PIN_FILE=/abs/path/amp-orb.pin
   ./install.sh amp-cli orb-image orb-provider canary
   ```

6. Start the provider. `install.sh` installs the unit but doesn't enable it:

   ```sh
   sudo systemctl enable --now amp-orb-provider
   ```

7. In Amp, open the provider's **Edit** dialog and define the orb types
   `large` (default) and `small`.
8. Check the result:

   ```sh
   ./install.sh status canary-run
   ```

Optional, and left to the host:

- **Canary alerting.** The canary unit sets no alerting of its own. Add
  `OnFailure=` with a systemd drop-in.
- **Low-disk alerting.** Set `ORB_LOW_DISK_ALERT_UNIT=<unit>` in an
  `Environment=` drop-in on `amp-orb-provider.service`, and let `agent` start
  exactly that unit, for example with a polkit rule. If it's unset, the
  dispatch only logs the warning.
- **The secret-name allowlist.** Put `ALLOWED_SECRET_NAMES=NAME1,NAME2` in
  `~agent/orb/drift.env`. The list is empty by default, so the drift check
  fails on any secret name until you list it.

### Update or roll back

To move to the latest Amp CLI and orb image:

1. Run `./install.sh update-orbs`. It:
   - builds a candidate template and fetches the candidate CLI, changing
     nothing live;
   - runs the dispatch dry run on the candidate, and switches only if the
     dry run passes;
   - restarts the provider only if the CLI version changed, which pauses
     running orbs;
   - rolls back by itself if the provider doesn't start on the new CLI
     within 30 seconds.
2. Commit the pin file and the previous pin (`$ORB_PIN_FILE.previous`)
   wherever the host keeps them.
3. [Refresh snapshots](#refresh-snapshots), or new threads keep booting the
   old image.

To hold one part at its pinned version, set `UPDATE_IMAGE=keep` (Amp's
image digest) or `UPDATE_CLI=keep`. A higher `ORB_PATCH_REV` still builds a
new template.

To go back, run `./install.sh rollback-orbs`. It swaps the current and
previous pins, CLI binary and template included. Run it again to roll
forward.

The Amp CLI's self-update is off on the host, so the CLI changes only when
you run `update-orbs` or `rollback-orbs`. The amp inside each orb isn't
pinned: Amp's bootstrap updates it.

### Refresh snapshots

Amp saves a project snapshot at the pause after repository setup, and new
threads in that project boot from it. They get the image the snapshot was
taken from, not the current pin, and the host can't delete Amp's side of a
snapshot.

After an image update, or after a change to a repo's `.agents/setup`:

1. Wherever you use the Amp CLI, delete Amp's snapshots for the project:

   ```sh
   amp projects snapshots delete <owner/repo>
   ```

2. On the host, find and remove the local copy. `./install.sh status`
   doesn't list snapshot templates.

   ```sh
   sudo -u agent sbx template ls
   sudo -u agent sbx template rm --force localhost/amp-orb-snapshot:<id>
   ```

The next thread boots the pinned template, reruns setup, and saves a new
snapshot. Existing orbs keep their image until their threads are deleted.

If a snapshot template disappears from the host for any other reason, do
step 1 as well. Otherwise every new thread reruns setup.

### Check on it

- `./install.sh status` shows:
  - the Amp CLI: pinned, installed, and running in the provider;
  - the pinned orb image and template, and the rollback target;
  - the [drift check](#drift-check);
  - every orb with its state, type, CPU, memory and Docker volume;
  - stale orb templates, and the canary timer.
- `journalctl -u amp-orb-provider -f` shows the dispatch's jobs as they
  happen.
- The canary runs daily at 11:00 UTC, plus a random delay of up to 15
  minutes. `./install.sh canary-run` runs it now and prints the result.

`status` lists every orb, so orphans are visible: an orb whose thread no
longer exists in Amp. Check each orb against your live threads.

### Restart with care

| Action | Effect |
|---|---|
| Restart `amp-orb-provider` | Running orbs pause. Each resumes on its thread's next message. The sbx daemon isn't touched. |
| Restart or stop `sbx-daemon` | **Every sandbox on the host stops**, and the provider stops or restarts with it. |

The provider depends on `sbx-daemon.service` but doesn't own it.

## Reference

### Network

An orb reaches sbx's global network policy (Balanced) plus the per-orb rules
the dispatch adds at creation. The rules are removed with the orb. Nothing
else is reachable.

| Reachable | Through | Used for |
|---|---|---|
| `rubygems.org` | global policy | gems |
| `github.com` and its release-asset hosts | global policy | mise and mise's prebuilt Ruby |
| `mise-versions.jdx.dev` | global policy | mise's version lists |
| `storage.googleapis.com` | global policy | already in Balanced; no setup step depends on it |
| `ampcode.com`, `static.ampcode.com`, `tunnel.ampcode.com` | per-orb rule (`AMP_HOSTS` in `dispatch.sh`) | Amp |
| UDP to Amp's Desktop relays | per-orb rule (`AMP_UDP_RELAYS`), which needs `feature.udp-egress` | Desktop |

Some hosts are blocked, and repository setup works anyway:

| Blocked | What happens |
|---|---|
| `index.rubygems.org` | Bundler tries it first, then falls back to `rubygems.org`. |
| `mise.jdx.dev` | mise falls back to GitHub. The `mise.run` installer fails: install mise from GitHub releases instead. |
| `cache.ruby-lang.org` | Never needed: Ruby comes prebuilt. |
| `googlechromelabs.github.io` | Chrome for Testing can't be installed. There is no Chrome yet. |

If an orb needs another host, add it to the dispatch's per-orb rules, never
to the global policy: widening the global policy widens every sandbox on the
host. Details are in docs/design-notes.md, "Orb network: what setup really
needs".

### Low disk

Before creating an orb, the dispatch checks the free space on `agent`'s
disk. If there is less than the Docker volume size plus 10 GB, a large orb
gets a 10 GB Docker volume instead. The dispatch logs a warning and starts
the host's low-disk alert unit, if one is set.

### `install.sh` sections

Give one or more sections in one command; they run in order.

| Section | What it does |
|---|---|
| `amp-cli` | Installs the pinned Amp CLI for `agent` and turns its self-update off. |
| `orb-image` | Builds the template the pin names, unless it's already loaded. |
| `orb-provider` | Copies the scripts and the pin to `~agent/orb`, and the provider unit to `/etc/systemd/system`. |
| `canary` | Installs the canary units and enables the daily timer. |
| `canary-run` | Runs the canary now and prints the result. |
| `update-orbs` | Re-pins to upstream and switches if the dry run passes. |
| `rollback-orbs` | Swaps the current and previous pins. |
| `status` | Shows versions, the drift check, orbs, stale templates and the timer. |

### Pin file

This repo carries no pin. The pin is the host's deployment state:
`update-orbs` and `rollback-orbs` rewrite it where you keep it, and write the
previous pin next to it as `$ORB_PIN_FILE.previous`.

| Key | Meaning |
|---|---|
| `digest` | Amp's orb image, by digest. |
| `patch` | The patch revision applied on top (`ORB_PATCH_REV` in `install.sh`). |
| `template` | `localhost/amp-orb:<first 12 of digest>-p<patch>`. `install.sh` rejects a pin whose `template` doesn't match its `digest` and `patch`. |
| `amp_cli` | The host's Amp CLI version. |

The `localhost/` namespace is deliberate: it points at no real registry, and
the dispatch boots orbs with `--pull never` anyway.

### Canary

The canary fails if either part fails.

**Dry run.** On a throwaway test orb, with no Amp involved: spawn, repeat
spawn, pause with snapshot, resume, delete, spawn from snapshot, and spawn
from the pinned template. It checks the size of each orb type and that a
host outside the allowlist is denied. At the end it checks that no sandbox,
rule or keep-alive is left.

#### Drift check

`./install.sh status` runs the same check.

| Fails when | Detail |
|---|---|
| The pinned template is missing | Rebuild it with `./install.sh orb-image`. |
| The pinned image can't be resolved upstream | A rebuild or a new host would need it. Any answer but HTTP 200 counts. |
| The installed Amp CLI isn't the pinned one | A self-update or a manual change. |
| The provider is down, or runs a replaced binary that differs from the installed one | Restart it. |
| The provider lacks `AMP_SKIP_UPDATE_CHECK=1`, or updates aren't disabled | The CLI could update itself. |
| `feature.udp-egress` is off | Desktop's UDP is blocked. |
| `/usr/bin/git` is below 2.40 in an orb from the current template | Recorded in the last 24 hours. |
| An orb's agent had a secret name outside the allowlist | Recorded in the last 24 hours. Defense in depth: names only, never values. |

A newer upstream CLI or image is only reported, as `INFO`.

## License

MIT. See [LICENSE](LICENSE).
