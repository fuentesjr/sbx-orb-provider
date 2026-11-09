# sbx orb provider

Amp's self-hosted orb provider (`amp-orb-provider.service`, as `agent`)
runs each orb in its own Docker Sandboxes microVM through
`dispatch.sh`. An illustrated walkthrough is at
[fuentesjr.github.io/sbx-orb-provider](https://fuentesjr.github.io/sbx-orb-provider/)
(source: [docs/index.html](docs/index.html)), and the reasons behind all of this are in [docs/design-notes.md](docs/design-notes.md).

## Use it

- **Web:** New Thread → the provider chip → your provider under Self-Hosted
  → optionally an orb type (**large** is the default).
- **CLI:**

  ```sh
  amp -ox "<message>" --orb-provider <name> [--orb-size small]
  ```

The dispatch does the rest: it creates, pauses, resumes and deletes the orb
as Amp asks, deleting it when the thread is deleted.

- Orbs run only while the provider runs. Restarting it pauses running orbs;
  they resume on the thread's next message.
- The sbx daemon runs as its own unit, `sbx-daemon.service`; the provider
  depends on it but doesn't own it. Restarting the provider leaves the
  daemon alone. **Restarting or stopping `sbx-daemon` stops every sandbox**
  and restarts the provider with it.
- An orb lives, running or stopped with its disk kept, until Amp deletes its
  thread. `./install.sh status` lists every orb, so orphans are visible.

## Orb types

| Type | CPU | Memory | Docker volume | For |
|---|---|---|---|---|
| **large** (default) | 4 | 8 GB | 20 GB | most threads: the Rails suite with Postgres/Redis on the orb's own Docker |
| small | 2 | 4 GB | 10 GB | light threads: docs, small scripts, no service containers |

- The types are defined in the provider's **Edit** dialog in Amp.
- An unset or unknown type gets large, with a warning in the log.
- The size is fixed when the orb is created.
- If the disk is short, a large orb gets a 10 GB Docker volume instead, and
  the dispatch logs a warning and starts the host's low-disk alert unit.

What every orb gets:
- the patched template named by the pin;
- git 2.55 at `/usr/bin/git`;
- Docker for service containers.

Amp's bootstrap runs without sbx's stand-in `GH_TOKEN`, so Amp's own
repo-scoped GitHub token is used.

## What an orb can reach

- sbx's global network policy (Balanced). It
  already covers what repository setup needs:
  - `rubygems.org` for gems;
  - `github.com` and its release-asset hosts, for mise and mise's prebuilt
    Ruby;
  - `mise-versions.jdx.dev`;
  - `storage.googleapis.com`.
- Per orb, added at creation and removed with it:
  - `ampcode.com`, `static.ampcode.com` and `tunnel.ampcode.com` (`AMP_HOSTS`
    in `dispatch.sh`);
  - UDP to Amp's Desktop relays (`AMP_UDP_RELAYS`). This needs sbx's
    experimental `feature.udp-egress`, which the drift check watches.
- Nothing else is reachable. Some hosts are blocked, but setup still works:
  - `index.rubygems.org` and `mise.jdx.dev`: Bundler and mise try them
    first, then fall back to `rubygems.org` and GitHub.
  - `cache.ruby-lang.org`: Ruby comes prebuilt, so it's never needed.
  - mise's `mise.run` installer fails here: install mise from GitHub
    releases instead.
  - `googlechromelabs.github.io` (Chrome for Testing): no Chrome yet.

  Details: docs/design-notes.md, "Orb network: what setup really needs".
- Orb hosts go in the dispatch's per-orb rules, never in the global
  policy: widening it widens every sandbox on the host.

## Snapshots

Amp saves a project snapshot at the pause after repository setup, and new
threads in that project boot from it. That means they keep the image the
snapshot was taken from, not the current pin. The host can't delete Amp's
side of a snapshot (no job reaches the provider). So **after an image
update, or a change to a repo's `.agents/setup`**:

1. Wherever you use the Amp CLI: `amp projects snapshots delete <owner/repo>`.
2. On the host, remove the local copy:
   `sudo -u agent sbx template ls`, then
   `sudo -u agent sbx template rm --force localhost/amp-orb-snapshot:<id>`.
   `./install.sh status` doesn't list snapshot templates.

The next thread then boots the pinned template, reruns setup, and saves a
fresh snapshot. Existing orbs keep their image until their threads are
deleted.

## Update or roll back

- `./install.sh update-orbs`:
  - re-pins the Amp CLI and Amp's orb image to upstream, and builds the
    patched template;
  - runs the dispatch dry run on that candidate, and switches only if it
    passes;
  - restarts the provider only if the CLI changed, which pauses running
    orbs;
  - keeps the previous pin. Commit both pin files wherever the host keeps
    them.
- `./install.sh rollback-orbs` swaps back to the previous pin (CLI binary and
  template); run it again to roll forward.
- The Amp CLI's self-update is off; updates happen only through
  `update-orbs`. The amp inside each orb isn't pinned: Amp's bootstrap
  updates it.

## Check on it

- `./install.sh status`:
  - the Amp CLI: pinned, installed and running in the provider;
  - the pinned orb image and template, and the rollback target;
  - the drift check;
  - every orb sandbox with its state, type, CPU, memory and Docker volume;
  - stale orb templates; the canary timer.
- `journalctl -u amp-orb-provider -f`: the dispatch's jobs, as they happen.
- Daily orb canary (the timer `./install.sh canary` installs, 11:00–11:15 UTC;
  `./install.sh canary-run` runs it now). It sets no alerting of its own: add
  `OnFailure=` with a systemd drop-in on the host.
  - **Dry run:** spawn, repeat spawn, pause with snapshot, resume, spawn
    from snapshot, pinned spawn and delete, on a throwaway test orb, with
    the size of each type checked. It then checks that no sandbox, rule or
    keep-alive is left.
  - **Drift check, fails on:** the pinned template missing; the pinned image
    gone upstream; the installed CLI not the pinned one; the provider down,
    on a replaced binary, or without `AMP_SKIP_UPDATE_CHECK=1`; updates
    not disabled; `feature.udp-egress` off; `/usr/bin/git` below 2.40 in an
    orb from the current template; any secret name in an orb's agent
    outside its allowlist (defense in depth: names only, never values; the
    allowlist is per host, see below).
  - A newer upstream CLI or image is only reported (INFO).

## Install

`install.sh` copies the scripts to `~agent/orb` and the units to
`/etc/systemd/system`, and builds the template. Some messages and comments in
the scripts still say `./setup.sh SECTION`; read that as
`./install.sh SECTION`.

```sh
ORB_PIN_FILE=/abs/path/amp-orb.pin ./install.sh amp-cli orb-image orb-provider canary status
```

This repo carries no pin: it is the host's deployment state, and
`update-orbs` / `rollback-orbs` rewrite it where the caller keeps it, plus
`amp-orb.pin.previous` next to it. Format
([example](examples/amp-orb.pin.example)):

| Key | Meaning |
|---|---|
| `digest` | Amp's orb image, by digest |
| `patch` | patch revision applied on top (`ORB_PATCH_REV` in `install.sh`) |
| `template` | `localhost/amp-orb:<first 12 of digest>-p<patch>`, checked by `install.sh`. The `localhost/` namespace is deliberate: it points at no real registry, and the dispatch boots with `--pull never` anyway |
| `amp_cli` | the host's Amp CLI version |

Left to the host:

- **`sbx-daemon.service`.** The units have `Requires=`/`After=` on it.
  [examples/sbx-daemon.service](examples/sbx-daemon.service) is a starting
  point for a host that runs nothing else on sbx.
- **The provider credential.** The unit loads
  `/etc/credstore.encrypted/amp-orb-provider-token`. Create the token in Amp,
  then, with TPM binding:
  `systemd-creds encrypt --with-key=host+tpm2 --name=amp-orb-provider-token - <that path>`.
- **Alerting.** The canary's `OnFailure=` (above). For the dispatch's
  low-disk alert, set `ORB_LOW_DISK_ALERT_UNIT=<unit>` in an `Environment=`
  drop-in on `amp-orb-provider.service` and let agent start exactly that
  unit (a polkit rule); unset, the dispatch only logs the warning.
- **The secret-name allowlist.** `~agent/orb/drift.env` with
  `ALLOWED_SECRET_NAMES=NAME1,NAME2`. Empty by default, so any secret name in
  an orb fails the drift check until it's listed.

## License

MIT. See [LICENSE](LICENSE).
