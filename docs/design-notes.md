# Design notes

Why the orb provider is built the way it is: findings, test logs and numbers
from getting Amp's self-hosted orbs running under Docker Sandboxes (sbx).
Moved here from the notebook of the host this first ran on, with
host-specific and credential notes left behind. "FINDINGS" in script comments
means this file, and `./setup.sh` in script comments means `./install.sh`.
"The operator" is the person who runs the host.

## Phase 2 work

- **Done: the low-disk alert is a hook the host configures.** The dispatch
  starts `$ORB_LOW_DISK_ALERT_UNIT` (set in an `Environment=` drop-in on the
  provider unit) and skips the alert when it's unset.
- **Stale comments.** Phase 1 kept scripts and the provider unit byte-identical,
  so comments still say `FINDINGS`, `setup.sh` and `orb/amp-orb.pin`.
- **Done: neutral names.** Canary units are `amp-orb-canary.*`; templates
  are `localhost/amp-orb*`, a namespace that points at no real registry
  (the real guard is the dispatch's `--pull never`). Older entries below
  still show the first host's names, written `<host>`. The secret-name
  allowlist moved from a default in `drift.sh` to the host's
  `~agent/orb/drift.env`.

## Orbs under sbx

### Summary (2026-11-02): done, sbx works as the orb isolation layer

**Done criteria met through the sbx dispatch:** spawn, pause (with snapshot), resume and delete all worked with real Amp threads (runs 1–2), plus recovery after a provider restart. Thread "Orb recovery check" was deleted at 05:10:41 UTC: delete took 6.1 s, the keep-alive and sandbox are gone, and the rule count is back to the 9 baseline. No orphans; the project snapshot template is kept by design.

What it took beyond Amp's documented contract:
1. **Image label** `com.docker.sandboxes.start-docker=true`, so sbx grants DinD (patch 1).
2. **Shim 1:** cgroupfs Docker driver (patch 2, image).
3. **Keep-alive `sbx exec` per orb**, because sbx auto-stops sandboxes 30 s after the last session and `long-running@1` needs a v3 workload kit.
4. **Shim 2:** `systemd-tmpfiles --create --prefix=/run` on every spawn (`/run/lock` for Desktop's dock).
5. **Desktop:** the experimental global `feature.udp-egress` flag plus a per-orb UDP rule to `104.30.0.0/15`.
5a. **Patch 3:** `/usr/bin/git` → `/opt/git/bin/git` (2.55) for tests that hardcode it.
6. Per-orb TCP rules for Amp's three hosts; nothing added to global policy.

The orb image is pinned by digest (Amp's `:latest` moved 6+ times today). Job times are 0.1–9 s against the 5-minute budget. The provider's memory peak over its first 1 h 25 min was 859 MB (systemd accounting, including dispatch children).

### Contract vs. sbx, read from the docs before testing (2026-11-02)

Amp's orb contract has three idempotent operations, five minutes each: spawn, pause and delete. sbx v0.50.1 has a verb for each:

| Orb operation | sbx | Fit |
|---|---|---|
| spawn (new) | `create shell --template $ORB_IMAGE` | Untested. Unknown whether sbx accepts a foreign image (Amp's image, default user `user`, not sbx's agent image) and still sets up its proxy and CA. |
| spawn (existing) | `exec` starts a stopped sandbox first | Good. sbx has no separate start verb. |
| bootstrap, detached | `exec` **has no `-d`** | Gap. Amp's Docker example uses `docker exec -d`. Workaround: `setsid nohup … &` inside the sandbox. Unknown whether the process outlives the exec session. |
| pause | `stop` keeps disk | Good. Memory is lost, the same as Amp's Docker and Apple examples. |
| pause + snapshot | `template save` into the local image store | Untested. Unknown whether it works on a stopped sandbox. Snapshots stay local to this host, as with Docker. |
| delete | `rm --force` | Good. |

Expected friction:
- **Default sandbox memory is 50% of host RAM (16 GB here).** Without an explicit `--memory`, two orbs would take all 32 GB. The dispatch pins 4 CPUs / 8 GB, the same size as Amp's own examples.
- **Network policy.** Orbs need `ampcode.com` (HTTPS + WSS), `static.ampcode.com`, `tunnel.ampcode.com` and the Git host. Unknown what Balanced allows. Unknown whether sbx's HTTPS proxy breaks long-lived WSS or TLS for a binary that doesn't trust the sbx CA. Leave `storage.googleapis.com` out (very broad; only needed if the image lacks `rg`) and `*.nscluster.cloud` (macOS satellites only).
- **Where the provider runs.** `amp orb provider` must call `sbx` on the host, so it can't sit inside a sandbox without handing that sandbox control of sbx. It's a small outbound-only dispatcher, not an agent. Resolved: launchers belong on the host by design; see Decisions.
- **Provider token must be an env var.** `AMP_ORB_PROVIDER_TOKEN` is how the CLI reads it. Plan: keep it encrypted at rest and set it only in the provider's process environment.
- **Snapshot cleanup has no hook.** `delete` removes the orb, but project snapshots are managed with `amp projects snapshots delete`. Unknown whether Amp then sends a job that lets the dispatch drop the local template. Watch disk.

### Decisions

#### Systemd assumptions shimmed for Amp orbs under sbx

Under sbx, PID 1 is sbx's own `sh` init, not systemd. Each row is something Amp's orb image expects systemd to provide.

| # | Assumption | Symptom without it | Shim | Where | Status |
|---|---|---|---|---|---|
| 1 | Docker uses the **systemd cgroup driver** (`native.cgroupdriver=systemd`, `cgroup-parent: amp-workload.slice`) | `docker run` in the orb: `systemd not running on this host, cannot use systemd cgroups manager` | `/etc/docker/daemon.json` → `cgroupfs`, keeping `cgroup-parent` | image, patch 2 (`install.sh orb_dockerfile`) | in use |
| 2 | **`/run` entries from systemd-tmpfiles**, notably `/run/lock` (`/run` is a fresh tmpfs per boot) | every Desktop dock click / app install: `install-app: /run/lock/amp-desktop-install.lock: No such file or directory`, "Desktop command exited with code 1" | `systemd-tmpfiles --create --prefix=/run` as root on every spawn (fallback: `install -d -m 1777 /run/lock`) | dispatch, every spawn and resume, before bootstrap; falls back to `install -d` if tmpfiles fails | adopted (dry run: `/run/lock` present after new spawn and after resume; `/run/systemd/system` absent) |

Observed but **not** shimmed (Amp already copes, or they aren't needed):
- `launch-app` uses `systemd-run` only if `/run/systemd/system` exists, and otherwise falls back to `setsid -f`. **Keep `/run/systemd/system` absent** (tmpfiles doesn't create it; only PID-1 systemd does), or Desktop apps break.
- `amp-headless*.service`, `amp-control.slice`, `amp-workload.slice` and `amp-desktop.service` are unused: the self-hosted bootstrap and Desktop start everything with `runuser`/`setsid`.
- The executor's `XDG_RUNTIME_DIR=/run/user/1000` exists (`user:user 0700`) without logind; the desktop session uses its own runtime dir anyway.
- No journald: Amp logs to files under `~/.cache/amp/logs` and `~/.cache/amp/desktop`.

- **Launchers run on the host, workloads run in sbx** (operator, 2026-11-02). Untrusted code (agent sessions, CI job steps, orb workloads) runs only inside sbx sandboxes. The launchers that start those sandboxes (`amp orb provider`, later the runner launcher) run on the host as `agent` under systemd. They are outbound only, hold only their own tokens, and never execute workload code themselves. The dispatch script lives in agent's home.

### Test log

**Probe 1: Amp's stock orb image as an sbx template. Fails.**
- `sbx create shell --template <amp-orb:latest>` took 72 s, mostly the first pull. It exits 0 and `sbx ls` shows the sandbox as *running*, but every `sbx exec` then fails with exit 125: `docker daemon failed to start inside the sandbox`.
- Cause, from sandboxd's `daemon.log`: **sbx starts dockerd inside every sandbox** (it treats all sandboxes as Docker-in-Docker). Amp's image ships dockerd with iptables 1.8.9 in nf_tables mode. Inside the sbx microVM that fails: `iptables -t nat -N DOCKER: Could not fetch rule set generation id: Permission denied`. The engine aborts, and sbx won't let you exec into a sandbox whose runtime failed.
- So "bring any image" doesn't hold for sbx: a template must be one whose inner dockerd sbx can start. sbx's own templates come from `docker/sandbox-templates` and show a FLAVOR column; Amp's image has none.
- `sbx create` reported success for a sandbox that can't run. A dispatch can't trust create's exit code, so it has to check with a real exec.
- `sbx template inspect` is cloud-only in v0.50.1 (locally it says to use `docker image inspect`, and the host has no Docker). Snapshot existence checks must use `sbx template ls`.
- The default Balanced policy denies `ampcode.com`, `static.ampcode.com` and `tunnel.ampcode.com`. It already allows `github.com` and `storage.googleapis.com`. The dispatch will add per-sandbox allow rules for the Amp hosts rather than widening every sandbox.
- `sbx rm --force` took 0.5 s.

**Diagnosis: the cause is a missing image label, not the iptables backend.**
- sandboxd logs a `dind` flag when it creates each sandbox's container: `spike-claude` (sbx's own template) got `dind=True`, `orb-probe` (Amp's image) got `dind=False`.
- The flag comes from an image label. sbx's templates carry `com.docker.sandboxes.start-docker=true`, plus `com.docker.sandboxes=templates` and `com.docker.sandboxes.flavor=<name>`; the sbx code path is `hasDinDLabel`. Amp's image has no `com.docker.sandboxes.*` labels.
- Without the label, sbx creates the sandbox's container without what DinD needs: no netfilter privileges and no `/var/lib/docker` volume. It still starts and health-checks dockerd (the image ships one), so the engine fails, and sbx then refuses every exec.
- This isn't nf_tables vs legacy. The `nft` binary itself fails (`cache initialization failed: Operation not permitted`), not just `iptables-nft`. EPERM means the process lacks the permission; a kernel without nf_tables would fail with "protocol not supported". The same microVM kernel (`nerdbox-kernel-x86_64`) runs dockerd fine in `spike-claude`. Switching to iptables-legacy needs the same `CAP_NET_ADMIN`, so it most likely fails the same way.
- Evidence came from sandboxd's `daemon.log`. With the runtime down, sbx relays the in-sandbox `/var/log/dockerd.log` there but allows no exec.
- **Tested image:** `us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:d64c8fb7b6c9a0bded61adc97876fa83ebdd1c2378cc382525c7edbdbd69ccfb` (index; amd64 manifest `sha256:4072388…20ac3`), default user `user`, Cmd `python3`, no entrypoint, ~1.7 GB compressed. **`:latest` had already moved** within the hour (`sha256:04f8e004…`), so the patch must pin by digest.

**Patch 1: add the DinD label. The sandbox works.**
- Fix: a two-line build on top of the pinned image: `FROM …amp-orb@sha256:d64c8fb7…` and `LABEL com.docker.sandboxes.start-docker=true`. The result is loaded as the local sbx template `docker.io/<host>/amp-orb:d64c8fb7b6c9`. Built by `./install.sh orb-image`; the pin lives in `amp-orb.pin`.
- **Security note: the label grants the orb Docker-in-Docker privileges inside its microVM**: netfilter / `CAP_NET_ADMIN`, its own dockerd and a `/var/lib/docker` volume. That's the same as our Claude sandboxes (`claude-code-docker` carries the same label), so it adds no new class of privilege. The microVM stays the boundary.
- Build path: the host has no Docker, so the image is built on the Docker engine of a throwaway `shell` sandbox. A rule scoped to that sandbox allows the registry; then `docker save`, `sbx cp`, `sbx template load`, and the builder is removed. A full rebuild takes 71 s: build ~38 s (pull 1.7 GB), save 18 s, cp 4 s, load 4 s. The re-run when already loaded takes 0.4 s. The rebuilt image ID differs each time (config timestamp), so the template name keys on the *base* digest.
- Cleanup checked: the builder's sandbox-scoped rule disappears with `sbx rm` (`policy inspect <rule id>` → not found). `sbx policy ls` still shows only the two original policies (195 global allows) and the registry is still default-deny globally, so **no global rule was added**. The tar went to agent's home, not `/tmp`, which is tmpfs (RAM) on this box. The stock Amp template is removed. sbx state is 5.0 GB.
- Results: `sbx create` from the template takes 1.8 s (vs 72 s for the cold first pull). `dind=True`, `exec` works as `user` (uid 1000, passwordless sudo, docker group), inner dockerd 29.9.2 is up, and amp, git 2.55, node 26, tmux, rg, gh, `/opt/amp-wayland`, Xwayland, pulseaudio and ffmpeg are all present.

**Second problem: Amp's image assumes systemd as PID 1. Fixed by patch 2 (below).**
- With the engine up, `docker run` fails: `runc create failed: systemd not running on this host, cannot use systemd cgroups manager`.
- Amp's `/etc/docker/daemon.json` sets `native.cgroupdriver=systemd` and `cgroup-parent: amp-workload.slice`. The image also ships systemd units (`amp-headless*.service`, `amp-control.slice`, `amp-workload.slice`) that keep the Amp control process and workload containers in separate cgroups. Under sbx, PID 1 is `sh` (sbx's own init); there is no systemd and no `/run/systemd/system`.
- In-sandbox experiment (throwaway, image unchanged): switching the inner dockerd to `native.cgroupdriver=cgroupfs` and restarting it makes containers run. An inner Alpine container reached `github.com` and **was blocked from `example.org` (fails at DNS)**, so sbx's network policy also covers containers inside the orb.
- The `amp-headless*` units look like Amp's hosted-orb path. The self-hosted contract starts `amp orb bootstrap` by hand (Amp's own Docker example uses `sleep infinity` as PID 1, so it would hit the same cgroup problem). Unknown until a real bootstrap: whether the desktop (`/opt/amp-wayland`) needs any of those units.

**Patch 2: cgroupfs driver. Containers inside the orb run.**
- Fix: the build adds `/etc/docker/daemon.json` with `native.cgroupdriver=cgroupfs`, keeping Amp's `cgroup-parent: amp-workload.slice`. It's written as a heredoc `COPY`, so there's no build context and no `USER` switch. Template: `docker.io/<host>/amp-orb:d64c8fb7b6c9-p2`. `amp-orb.pin` now holds `digest=`, `patch=` and `template=`. The dispatch boots from the pin's `template=` and ignores Amp's `ORB_IMAGE` (it only logs it).
- Verified from the image with no manual steps: inner dockerd uses cgroupfs, `docker run alpine` works (2.2 s including pull), GitHub is reachable and `example.org` is blocked.
- **Build-disk surprise:** a label-only patch never unpacks the base image, but adding a file does. Amp's image unpacks to 6.2 GB on top of 1.8 GB of compressed layers, which overflows sbx's default 10 GB `/var/lib/docker` volume per sandbox (`no space left on device`). sbx has a per-sandbox override, `DOCKER_SANDBOXES_DOCKER_SIZE`, set in `sbx create`'s environment. It's documented only in the description of `sandbox.disk.dockerVolume`; I'd first said no per-sandbox option existed. The builder uses 20g. `install.sh` checks there's ≥25 GB free on the host, that the builder really got the 20 GB volume, and that the global setting is unchanged (still `10g`). Each check fails loudly.
- Rebuild takes 86 s. Patch-1 template removed. sbx state: 8.9 GB (two sbx templates + the p2 orb template + `spike-claude`).
- **Amp's `:latest` moves several times an hour.** Three different digests in about two hours today (`d64c8fb7…` tested, then `04f8e004…`, then `fc878663…`). Pinning is necessary, and `./install.sh status` will nearly always show drift. Re-pin deliberately, not on every change.

**Dry run of the dispatch, no Amp (`dryrun.sh`, fake token). Passed.**

| Job | Time | Notes |
|---|---|---|
| spawn, new sandbox | 2.9–8.0 s | create + 3 per-orb rules + exec |
| spawn, already running | 0.6 s | starts a second bootstrap, as Amp's Docker example does |
| pause + snapshot | 0.8–0.9 s | `sbx stop` + `sbx template save` on the stopped sandbox (save itself "0 s") |
| resume (spawn on stopped) | 1.6 s | disk kept (marker file survived) |
| spawn from snapshot | 2.3 s | snapshot content restored |
| delete | 0.3–0.6 s | repeat delete: 0.1 s no-op |

All jobs are far inside the 5-minute budget. Each orb gets three rules scoped to that sandbox only (`ampcode.com`, `static.ampcode.com`, `tunnel.ampcode.com`). `sbx rm` removes them, and `sbx policy ls -q` matches the before-list exactly, so no global rule remains (`ampcode.com` is still default-deny globally). The fake token reached Amp through sbx's proxy and was rejected properly (`ORB_TOKEN was rejected by Amp … expires after 15 minutes`). So the amp binary's TLS works through the sbx MITM proxy, and the per-orb rule is effective. WSS is still unproven until a real token is used.

**Image cases (dispatch `choose_image`), as designed, before seeing what Amp actually sends:**
1. `ORB_SNAPSHOT_ID` names a local snapshot (`docker.io/<host>/amp-orb-snapshot:<id>`): boot from it.
2. `ORB_IMAGE` names a local sbx template (our provider override, or a snapshot image Amp passes in `ORB_IMAGE`): boot from it.
3. Otherwise (Amp's stock image or unknown): the pinned template.

Resume never chooses an image: the sandbox still exists, so `spawn` just starts it. An image only matters when the sandbox is gone, i.e. a new thread or one whose orb was deleted. The dispatch logs `ORB_IMAGE`/`ORB_SNAPSHOT_ID`/`ORB_TYPE` (never tokens) on every job, so the real end-to-end test shows which case Amp triggers.

**sbx gotcha: `sbx exec` reads stdin.** Running a script via `bash -s < script` let the first `sbx exec` swallow the rest of the script, which died silently. The dispatch now does `exec </dev/null`, so an open stdin from the provider can't hang a job or be read by it.

**End-to-end run 1 (real thread, orb `amp-01a19a7c-…`), 2026-11-02 04:19–04:23 UTC. Spawn works; two blockers.**

Provider journal and sandboxd log (UTC):

| Time | Event |
|---|---|
| 04:19:53 | spawn, new: Amp sent `ORB_IMAGE=docker.io/<host>/amp-orb:d64c8fb7b6c9-p2` (our provider override) and no snapshot, so **image case 2**. Job 3.6 s. |
| 04:20:06 | **pause from Amp**, 13 s after spawn, with `ORB_SNAPSHOT_ID=snap-665cbc87-…-dd649cf4`. Stop + `template save` took 4.4 s. Snapshot template `docker.io/<host>/amp-orb-snapshot:snap-665cbc87-…` saved. |
| 04:20:12 | spawn (resume): sandbox exists, so it's started; no snapshot ID sent. 2.0 s. |
| 04:20:44 | **sbx auto-stop**: `auto-stop grace period expired … auto-stopped runtime after last session disconnected`. Not a dispatch job. |
| 04:21:32 | spawn (resume) again from Amp (it noticed the orb dropped). 2.1 s. |
| 04:21:41–45 | 105 × `VM Network: BLOCKED direct UDP connection attempt, proxy enforcement` to `104.30.x.x` (9 addresses, Cloudflare range) and the viewer's public IP. This is Desktop/WebRTC trying UDP. |
| 04:22:04 | **sbx auto-stop** again, 30 s after the resume's exec session ended. Amp then showed the orb as paused (the operator saw it ~20:23 local). |

- **Blocker 1: sbx auto-stops a local sandbox 30 s after its last session disconnects.** The dispatch's bootstrap is detached by design (`sbx exec` has no `-d`), so once the exec returns, sbx sees no session and stops the VM under the running orb. The dry run missed this because every step ran within 30 s of the previous exec. The fix exists in sbx: the kit capability **`com.docker.sandbox/long-running@1`**, which "keeps a local sandbox running after its last session disconnects" (local only, sbx ≥ v0.47.0). It must be set **at creation** (no `kit add` on an existing sandbox), so it goes on `sbx create` via a mixin kit (`--kit`). Exact descriptor syntax is in `docker/sandbox-kit-spec` (`docs/spec/SPEC-v3.md`, `schema/capabilities/`); not yet read.
- **Blocker 2: Desktop never rendered; sbx blocks direct UDP.** The only Desktop-related signal in sbx's logs is the burst of blocked UDP right after the resume. That fits WebRTC media trying TURN relays (`104.30.0.0/15` is a Cloudflare range) and a peer/srflx address (the viewer's public IP, possibly the operator's); both are inference. sbx's architecture docs only describe TCP through the proxy; UDP isn't covered. **Not yet determined:** whether amp-wayland itself started or failed, and whether it depends on Amp's systemd units. Checking means starting the sandbox (an unrequested resume) with only 30 s before auto-stop, so it wasn't done. The evidence so far points to network (UDP), not systemd.
- **Which image case Amp uses:** a new orb gets Amp's `ORB_IMAGE` = our provider override, so case 2. Pause sends `ORB_SNAPSHOT_ID` (named `snap-<uuid>-<hash>`, which looks like a *project* snapshot). Resume of an existing sandbox sends no snapshot ID and picks no image. **Amp has not yet sent a snapshot in `ORB_IMAGE`.** Case 1 (spawn with `ORB_SNAPSHOT_ID`) should come from a *new* thread in the same project; untested. Hypothesis: the early pause at 04:20:06 is Amp capturing the project snapshot right after repository setup, not Orb Saver.
- Spawn, pause-with-snapshot and resume all took ≤4.4 s in the real run.

**Real delete (the operator deleted the thread, 04:31:09 UTC).** Delete job done in 0.76 s; sandbox removed; its three rules gone (`policy inspect <id>` → not found; rule count back to the 9 baseline). **The project snapshot template stays**: `delete` is per orb, and the snapshot (`snap-<uuid>-…`) belongs to the project, cleaned up via `amp projects snapshots delete`. A new thread in the same project should boot from it (image case 1). Unknown whether deleting a project snapshot in Amp sends any job to the provider. `./install.sh status` now lists `amp-*` sandboxes, so orphans are visible.

**Provider self-update.** At 04:26 the running provider logged `Update installed, but amp on PATH differs; restart the provider manually`. amp updated `~/.amp/bin/amp` in place, but systemd's default PATH lacks `~/.amp/bin`. The unit now sets `PATH=/home/agent/.amp/bin:…`. A restart is still needed to pick up an update; whether it restarts itself with the PATH fix is untested.

**Long-running orbs persist until Amp deletes them.** Whatever keeps an orb up past sbx's 30 s auto-stop also means sbx never reclaims it. An orb lives (running or stopped, disk kept) until Amp sends `delete`. If Amp loses track (provider down during a delete, a thread deleted while another provider holds the token), the sandbox is an orphan, so check `./install.sh status`.

**Attempt: `long-running@1` kit. Doesn't fit; reverted.**
- A v3 *mixin* can't be combined with a built-in agent: `sbx create shell --kit <mixin>` fails with `no kit in the set defines the sandbox itself … built-in agents such as "shell" are not v3 kits`. The v1/v2 kit formats (what `shell` uses) have no long-running field.
- A v3 *workload* kit would have to define the sandbox itself. The spec has no field naming an existing image: the kit builder builds the image from a Dockerfile recipe, so it would rebuild `FROM` our 6 GB template, and from each snapshot image. Also, the v3 runtime floor requires default user `agent` (uid 1000, `/home/agent`), while Amp's image is built on user `user` with `/home/user`.
- First use created `sbx-kit-builder`, a shared builder sandbox left **running detached** (itself long-running), and pulled `docker/sandbox-kit:3`. The kit build took 21 s. The builder, `sbx-kit-src` and `sandbox-kit-assembled` images were removed afterwards. The dispatch is back to no kit.

**Fix for auto-stop: one keep-alive session per orb.** On spawn, the dispatch starts `setsid sbx exec <orb> sleep infinity` on the host (as agent, stdio closed, pidfile in `~/orb/run/`). Pause and delete stop it first. It lives in `amp-orb-provider.service`'s cgroup, and the unit uses the default `KillMode=control-group` (no override), so **stopping or restarting the provider kills every keep-alive**. sbx then auto-stops the orbs within 30 s, and Amp resumes them on the next message. Orbs only run while the provider runs: a crashed provider can't leave orbs running indefinitely, though stopped orb sandboxes stay until Amp deletes them.
- Dry run with 45 s idle checks: the orb stays `running` with no other session, a repeated spawn reuses the keep-alive, and no keep-alive survives pause or delete.
- Cost: the `sbx exec` CLI ignores SIGTERM, so the dispatch waits 5 s and then SIGKILLs. Pause now takes 3–9 s and delete 1–5 s, still far inside 5 min.
- Restarting the provider for the new amp build worked: the running version moved from `0.0.1793577666-g2e4e3d` to `0.0.1793592041-g8ba069`. `./install.sh status` shows the running provider version next to the CLI and flags it when older.

**UDP for Desktop: sbx can allow it per sandbox.** `sbx policy check network --protocol udp --sandbox <orb> <ip:port>` evaluates UDP in a sandbox's context (both `104.30.136.165:21885` and `the viewer's public IP:27950` → denied, default deny; no UDP rules exist). `sbx policy allow network --sandbox <orb> --protocol udp <CIDR>` is the documented form. Untested: whether the VM's "direct UDP … proxy enforcement" honors an allow rule. The operator confirmed the viewer's public IP is their own, so that's WebRTC trying to reach the viewing browser directly (host/srflx candidate). `104.30.0.0/15` would be the relay path.

**End-to-end run 2 (thread "Orb recovery check", orb `amp-01a19a8f-…`), 04:40–04:50 UTC.**
- **Snapshot case seen live:** a new thread in the same project sent `ORB_SNAPSHOT_ID=snap-665cbc87-…` plus `ORB_IMAGE=<our override>`, so case 1: booted from the project snapshot in 2.4 s. **Amp passes snapshots in `ORB_SNAPSHOT_ID`, not in `ORB_IMAGE`.**
- **Keep-alive held the orb up:** still running more than 60 s after spawn, with one keep-alive in `/system.slice/amp-orb-provider.service`.
- **Recovery:** `systemctl restart amp-orb-provider` with the orb live. The provider waited for running jobs and stopped 6 s later, killing the keep-alive (`session disconnected` 04:43:21). **No keep-alive processes remained.** sbx auto-stopped the orb 30 s later (04:43:51). Amp did not re-spawn on its own. On the operator's next message, Amp showed "Reconnecting to orb" and sent spawn (resume, 2.0 s); one new keep-alive started. **`~/orb-resume-check.txt` read `resume-check-1793594445`, the same as before the restart.** A stale pidfile is left by the restart; harmless, because the dispatch checks `/proc/<pid>/cmdline` before trusting it.
- **Per-orb rules survive stop/resume, including the UDP rule:** `ampcode.com`, `static.ampcode.com` and `tunnel.ampcode.com` (tcp) plus `104.30.0.0/15` (udp) were all present while stopped and after resume.
- **UDP needs an experimental global flag.** `sbx policy allow network --sandbox <orb> --protocol udp 104.30.0.0/15` saved the rule but warned `UDP egress is disabled; enable experimental features and feature.udp-egress`. The flag isn't listed in `sbx settings ls`, reads `{"enabled":false,"variant":"","variantPayload":""}`, and **is settable locally** (`sbx settings set feature.udp-egress true`, source `override`). With it on, UDP is still default-deny: `104.30.136.165`, the viewer's public IP and `1.1.1.1:443` are all Denied globally and for `spike-claude`, and for the orb only `104.30.0.0/15` is Allowed.
- **Desktop with relay UDP allowed:** it **rendered** (wallpaper, thread name, dock) about 20 s after opening, at ~04:48. Since 04:47, sbx logged **zero** blocked UDP to `104.30.x.x` (vs 70 in run 1) and only 3 to the viewer's IP (direct path, still blocked as intended). sbx doesn't log allowed UDP, so "relay allowed" is inferred from the absent blocks. The desktop stack is started by `runuser … /opt/amp-desktop/supervise` (labwc, Xwayland, pulseaudio, `waymote-gateway` on 127.0.0.1:5900, `waymote-streamd`, ffmpeg x264/opus). **It does not use Amp's systemd units.**
- **Clicking the dock terminal did nothing, and the click never reached the orb.** No `foot` process, no `~/.cache/amp/desktop/terminal.log`, and no `launch-app` run. `launch-app` has an explicit no-systemd fallback ("self-hosted orbs boot their own init" → `setsid -f`), so systemd is not the cause. At the same moment the browser↔orb connection was flapping: waymote video client 2 closed at 04:48:47 (`read side closed: context canceled`), client 4 connected at 04:49:15 with a new frame size (1008×1168 vs 1120) and closed again at 04:49:22. The executor's ~10 s file-tree polling also gapped from 04:48:46 to 04:49:14. The control client (input) stayed connected throughout.
- **Side issue, systemd absence:** `/opt/amp-desktop/install-app` fails with `/run/lock/amp-desktop-install.lock: No such file or directory`. sbx's `/run` has no `/run/lock`, which systemd-tmpfiles would normally create. `start-session` calls it to install Chrome, so app installs fail. A candidate for a patch-3 build step (create `/run/lock` at start); not done.

**Shim 2 trial: `systemd-tmpfiles --create --prefix=/run` on the live orb.** The image has `systemd-tmpfiles` (systemd 252, Debian 12; no `--dry-run`, which arrived in 256), so the rules were reviewed with `--cat-config` instead. A full `--create` would also act outside `/run`: `L+ /etc/mtab` (force-replace), `d- /root/.ssh`, mode/owner resets on existing `/home`, `/var`, `/var/log` and `/tmp`, empty `wtmp`/`btmp`/`lastlog`, and journal rules using `%m`. Boot-only rules (`!`: `/run/nologin`, which would block non-root logins, and `/run/utmp`) only fire with `--boot`, which isn't used. Hence `--prefix=/run`. A before/after diff of `/run` showed exit 0, **only creations** (nothing changed or removed): `/run/lock` (0755, as parent of `/run/lock/subsys`), `/run/lock/subsys`, `/run/dbus{,/containers}`, `/run/log`, `/run/sendsigs.omit.d`, `/run/sudo` (0711), `/run/shm → /dev/shm`, and `/run/systemd/{ask-password,machines,netif{,/leases,/links,/lldp},seats,sessions,shutdown,users}`. `/run/systemd/system` is still absent. `install-app`'s lock now succeeds.

**Dock click: diagnosed. `install-app` fails on the missing `/run/lock`.**
- New evidence from the operator: Amp showed "Desktop command exited with code 1". The click does reach the orb, over Amp's executor relay (`executor_relay_open`/`executor_relay_data`; the payload isn't logged). My earlier "the click never reached the orb" was wrong.
- Running `/opt/amp-desktop/launch-app terminal` by hand as `user`, with the executor's exact environment (pid 444: `WAYLAND_DISPLAY=wayland-0`, `XDG_RUNTIME_DIR=/run/user/1000`, later overridden by `~/.cache/amp/desktop/environment`), **works**: exit 0, foot starts, `terminal.log` appears. The environment and the no-systemd fallback in `launch-app` (`setsid -f`) are fine.
- `sudo -n /opt/amp-desktop/install-app terminal` as `user` **exits 1**: `line 9: /run/lock/amp-desktop-install.lock: No such file or directory`. Every dock app has an install step (`terminal) install_terminal`), and the script takes `exec 9>/run/lock/…; flock 9` before anything else. `start-session` uses the same `install-app X` then `launch-app X` pattern for Chrome, which failed the same way at desktop start. Conclusion (inferred; the packed JS call site isn't readable): the dock runs `install-app <app>` before `launch-app <app>`, and the first step fails.
- Root cause: **`/run` in an sbx sandbox is a fresh tmpfs per boot** (`tmpfs rw,nosuid,size=65536k,mode=755`), and nothing creates `/run/lock`. On a systemd host `systemd-tmpfiles` does (`d /run/lock 1777 root root`; `/var/lock` → `../run/lock`). It's another systemd-provided piece missing under sbx, like the cgroup driver in patch 2. An image layer can't fix it, because the tmpfs hides anything baked under `/run`.
- Desktop processes are started by `runuser … /opt/amp-desktop/supervise`, not systemd, and the bootstrap rewrites `/opt/amp-desktop/*` at desktop start, so patching Amp's scripts in the image would be overwritten.

**Desktop result (run 2, ~05:00 UTC): renders, streams and takes keyboard input; dock launch not yet proven on a clean click.**
- Operator: the terminal icon brought up foot with no error, and typing `echo desktop-input-ok` printed the expected output. **Video stream, keyboard input and the Desktop session work** in an sbx orb.
- Orb side: there was **no new foot** process. The window was the foot I had started by hand at 04:55:54 (pid 2060) while testing `launch-app`. Nothing else started after 04:58 apart from a video-encoder restart (view reconnect at 04:59:56), and `install-app` didn't run. So the click either focused the existing window or launched nothing. The dock's `install-app` + `launch-app` path still needs one clean click with no terminal open.
- **Desktop depends on an experimental global sbx flag.** WebRTC media needs UDP to Amp's relays, and sbx drops all direct UDP unless `feature.udp-egress` is enabled (`sbx settings set feature.udp-egress true`; experimental, global, not listed in `sbx settings ls`, set locally as an override). With the flag on, UDP stays default-deny and each orb still needs its own `--protocol udp 104.30.0.0/15` rule. Since 05:08 the dispatch adds it as the **fourth per-orb rule** at create (removed with the orb; spawn rolls back the sandbox if any rule fails). Dry run: 4 new rules per orb; orb→`104.30.136.165` UDP Allowed, orb→viewer IP Denied, global→relay Denied; back to baseline after delete. Kept on by the operator's decision. Risk: an experimental flag can change or vanish in any sbx update, which would silently break Desktop again.

**Dock launch path: proven on a clean click (05:06 UTC).** With no terminal running (my hand-started pid 2060 killed at 05:05:04), the tester clicked the terminal icon once. The operator saw no error toast and a new foot window within ~20 s. In the orb at 05:06:14: `install-app` took `/run/lock/amp-desktop-install.lock` and left `/tmp/amp-desktop-install-app.log` **empty** (previously the `/run/lock` error); `launch-app` detached foot via its no-systemd `setsid -f` path (pid 2745, PPID 1, shell 2746); `terminal.log` was rewritten. No apt run was needed (foot ships in the image). **Desktop now works end to end on an sbx orb**: render, stream, keyboard input and app launch, given shim 2 and `feature.udp-egress` plus the per-orb relay rule.

### Orb types (2026-11-02, operator)

| Type | CPU | Memory | Docker volume (`/var/lib/docker`) | Use |
|---|---|---|---|---|
| **large** (default) | 4 | 8 GB | 20 GB | most threads: the Rails suite with Postgres/Redis (DinD) on the orb's own Docker engine |
| small | 2 | 4 GB | 10 GB (sbx's default) | light threads: docs, small scripts, no service containers |

- **Why large is the default:** most threads run the Rails test suite, which pulls and starts Postgres and Redis containers, maybe builds an app image, and stores bundle and asset caches. 8 GB and 4 CPUs is Amp's own example size, and the 10 GB default Docker volume is tight once service images, build layers and caches add up.
- **Mechanics (dispatch):** Amp sends the type name as `ORB_TYPE` on spawn. Unset or unknown → large with a logged `WARNING`, never a failure. Size is fixed at creation; a resume asking for a different type only logs a warning. The large volume uses sbx's per-sandbox `DOCKER_SANDBOXES_DOCKER_SIZE=20g` (global `sandbox.disk.dockerVolume` untouched). Before creating, the dispatch checks free space on agent's disk the same way the image build does (`df` on `/home/agent`) and needs volume + 10 GB headroom. If short, it logs a warning and uses 10 GB rather than failing.
- **Disk:** sbx volumes are **sparse**: `spike-claude`'s 10 GB Docker volume and 50 GB workspace image occupy ~0 bytes until written, so the check guards against overcommitting the host disk, not against an immediate allocation. With 67 GB free, a few large orbs filling 20 GB each would fit, but not many; watch `df` once real Rails runs happen.
- **Bookkeeping:** the dispatch writes `~agent/orb/run/<orb>.type` (`large 4 8g 20g`) at creation and removes it on delete. `./install.sh status` shows each orb's type plus the CPU/MiB sbx actually reports.
- **Low-disk alert:** when the check drops a large orb to 10 GB, the dispatch also starts the host's alert unit, `<host>-alert@orb-disk-low.service` (`--no-block`, never fails the spawn). That unit mails a low-disk alert with the dispatch's `WARNING: only N GB free` lines and `df -h /`. The dispatch runs as agent and can't read the mail credential, so a polkit rule lets **agent `start` exactly that one unit, nothing else**. This works through D-Bus, so the provider unit's `NoNewPrivileges=yes` doesn't block it the way it would a sudo rule.
- **Canary checks from inside each orb too:** `nproc` must equal the type's CPUs, and `MemTotal` must be 85–100% of the VM size, as well as sbx's reported `cpus`/`memory_mib` and the Docker volume size.
- **In Amp:** define orb types `large` (default) and `small` in the provider's **Edit** dialog (names are permanent identifiers). Until then Amp sends no `ORB_TYPE`, and every orb is large with a warning in the log.

**How many fit under a memory cap (planned `MemoryMax` ≈ 26 GB on the sbx service), by configured VM size:**

| Also running | Left for orbs | Large orbs | or small | or a mix |
|---|---|---|---|---|
| nothing else | 26 GB | **3** (24 GB) | 6 | 2 large + 2 small |
| a runner sandbox (assumed 8 GB) | 18 GB | **2** (16 GB) | 4 | 1 large + 2 small |
| runner + one other sandbox (8 GB) | 10 GB | **1** (8 GB) | 2 | — |

**Installed and tested 2026-11-02 ~22:45–22:52 UTC** (after the operator deleted the Amp project snapshots for the test repo and added orb types `large` (default) and `small` in Amp; local snapshot template `amp-orb-snapshot:snap-665cbc87-…` removed; Amp CLI not updated).
- **Polkit rule, decisions for an agent process** (`pkcheck` run as root on behalf of an agent PID; polkit refuses details from non-root callers):

  | verb | unit | result |
  |---|---|---|
  | start | `<host>-alert@orb-disk-low.service` | **allowed** |
  | stop / restart / reload | `<host>-alert@orb-disk-low.service` | denied |
  | start | `<host>-alert@test` / `@heartbeat` / `@x` | denied |
  | start / stop | `amp-orb-provider.service` | denied |
  | start | `amp-orb-canary.service` | denied |

  "Denied" is polkit's `auth_admin` challenge, which agent can't answer. The rule allows exactly one unit, not `<host>-alert@*`: a wildcard would let agent pick any instance name, and `<host>-alert@<unit>` mails that unit's journal.
- **Real low-disk alert, end to end:** one manual spawn as agent, `ORB_MIN_FREE_HEADROOM_GB=1000` on that command only, output fed to the journal. Results:
  - (1) The orb **spawned, large at 10 GB**: dispatch exit 0, `WARNING: only 68 GB free, need 1020 GB … using 10 GB`, `df` in the orb showed 10G, type file `large 4 8g 10g`.
  - (2) The alert unit was started through polkit and **the mail provider accepted the mail at 22:48:21 UTC** (`smtpstatus=250`, 893 bytes). The body (regenerated with `ALERT_DRY_RUN=1` from the same journal) has "Reported: … UTC (… PST)", the dispatch's WARNING line and `df -h /`, and nothing secret-shaped.
  - (3) Afterwards no override remained: `systemctl show amp-orb-provider -p Environment` = `PATH=… AMP_SKIP_UPDATE_CHECK=1`; no `HEADROOM` in the provider's process environment, the units, `provider.sh` or `install.sh`; the installed dispatch has only its default `${ORB_MIN_FREE_HEADROOM_GB:-10}`.
  - The test orb was deleted through the dispatch (rules, keep-alive and type file gone; rule count 9).
  - Fixes found on the way: the alert first matched only provider/canary journal lines, and now matches the dispatch's warning from any source after a 2 s wait. Alerts now show UTC and Pacific.
- **Canary with types (22:49–22:52 UTC): passed.**
  - Large orb: sbx 4 CPU / 8192 MiB / 20 GB volume; **inside: `nproc` 4, `MemTotal` 8023 MiB (98%)**.
  - `ORB_TYPE` unset and `bogus` both warned and gave the same large size.
  - Small orb: sbx 2 CPU / 4096 MiB / 10 GB; **inside: `nproc` 2, `MemTotal` 3997 MiB (98%)**; its 4 rules and keep-alive went with it.

CPU isn't the limit (24 host threads; 3 large orbs = 12 vCPUs). The cap counts what the VMs actually use, not their configured size. If idle orbs use much less than 8 GB, more would start, but they'd risk OOM kills under load, so planning by configured size is the safe count. Measured idle host memory of one large and one small orb: see Numbers.

### Orb network: what setup really needs (2026-11-03, checked)

The operator: last night's orb setup ran mise, the Ruby download and `bundle install` fine, although the README said those hosts were blocked.
- **Global policy** (`sbx policy check network <host>:443`, global context):
  - **allowed:** `rubygems.org`, `mise-versions.jdx.dev`, `mise.run`, `github.com`, `objects.githubusercontent.com`, `storage.googleapis.com`;
  - **denied:** `index.rubygems.org`, `cache.ruby-lang.org`, `mise.jdx.dev`, `googlechromelabs.github.io`.
- **sbx's policy log for orbs:** blocked attempts to `index.rubygems.org` (18), `mise.jdx.dev` (15), `googlechromelabs.github.io` (17) and `cache.ruby-lang.org` (1), through 05:16 UTC. Setup still succeeded. sbx keeps only the last 100 *allowed* entries, so the orbs' allowed traffic was gone.
- **Reproduced** in a throwaway sandbox (`net-probe`, runner template, no per-sandbox rules: the global policy only, as an orb minus Amp's hosts; deleted afterwards, 0 rules left):
  - **mise:** the binary from GitHub releases (`github.com` → `release-assets.githubusercontent.com`) works. The `curl https://mise.run | sh` installer **fails** (403): it reads its release index from `mise.jdx.dev`.
  - **Ruby:** `mise install ruby@4.0.9` took 6 s. It downloaded a **prebuilt** `ruby-4.0.9.x86_64_linux.tar.gz` from GitHub release assets, with versions from `mise-versions.jdx.dev` (and `tuf-repo-cdn.sigstore.dev`, allowed). No `cache.ruby-lang.org`, no compile.
  - **Bundler:** `bundle install` (rake, nokogiri) completed. Bundler tried `index.rubygems.org` (blocked twice) and fell back to `rubygems.org` (allowed).
  - The only blocks were `index.rubygems.org` ×2 and `mise.jdx.dev` ×2, the same harmless fallbacks seen in the orbs.
- **So per-orb rules for RubyGems, ruby-lang and mise aren't needed;** the decision above is dropped.
- **Chrome for Testing stays blocked** (`googlechromelabs.github.io`; its binaries are on the allowed `storage.googleapis.com`). It is still the open "no Chrome" gap, not a setup problem.
- The runner's own list (`GHR_ALLOW_HOSTS`) still names these hosts. That is redundant but harmless, and it keeps the runner independent of the global policy.

**How a denied request looks (2026-11-09 UTC, checked).** An orb's `curl -sI https://example.com` printed a 200 and looked like a policy gap. It wasn't: `sbx policy log` has that request blocked, and no rule (global or per-orb) covers the host. Reproduced in throwaway sandboxes from the pinned orb template and the runner template (with the launcher's allow list); both behaved the same.
- **HTTPS: CONNECT 200, then a TLS-terminated 403.** For a denied host the proxy answers `CONNECT` with `HTTP/1.1 200 OK`, completes TLS itself with a certificate from "Docker Sandboxes Proxy CA", and returns `403 Forbidden` to the request inside the tunnel. `curl -I` prints both responses, so the first line says 200, and curl exits 0 either way. Read the final status with `-w '%{http_code}'`, or use `curl -f`. `%{http_connect}` is the 200. An allowed `forward-bypass` host answers `HTTP/1.0 200 Connection established` and shows its real certificate.
- **Plain HTTP:** a direct 403 from the proxy, with no CONNECT.
- **Traffic that skips the proxy settings is still policed.** With `--noproxy '*'`, sbx intercepts the connection transparently (`transparent` in `sbx policy log`) and applies the same policy: an allowed host works; a denied host or a bare IP gets a TLS reset or an empty reply. A bare TCP connect can succeed, but only locally: nothing is forwarded once data is sent, so a connect alone proves nothing. A `github.com` SNI aimed at another host's IP reached the real GitHub, not that IP.
- **DNS is blocked for denied hosts.** `--noproxy https://example.com` fails to resolve (`DNS lookup blocked by proxy` in the log). Direct DNS to `8.8.8.8:53` over TCP and UDP gets no reply and is logged as blocked.
- **The 403's body is misleading.** It reads `Approval required for example.com:443. Review and respond with: sbx policy approval ls`. That is a host-side command an orb can't run, and it isn't listed in `sbx policy --help`. Noted only; orb instructions are unchanged.
- **Checked by the dry run** (`egress_check`, step 1): `https://example.com` from the test orb must return 403 and leave a matching blocked entry in `sbx policy log`. The log keeps entries across sandboxes of the same name, so only an entry from that run counts.

**GH_TOKEN in orbs is invalid: diagnosed, not yet changed.**
- **The sbx proxy doesn't strip or rewrite `Authorization` for this sandbox.** `sbx policy log` shows `github.com` and `api.github.com` as **`forward-bypass`** (no TLS interception, so the proxy can't see headers). A fake bearer token gets **401 "Bad credentials"** and no header gets 200/60-per-hour, **identically from the host and from inside the orb**. A Docker-dispatch comparison wasn't needed.
- **The token itself is sbx's stand-in.** `GH_TOKEN` is set in the sandbox's **PID 1 environment** (so every process inherits it): GitHub-shaped, 40 chars, while `SBX_CRED_GITHUB_MODE=none` and sbx holds no `github` secret. The `shell` kit declares a `github` credential (`GH_TOKEN`), and sbx sets the stand-in anyway. With no secret and the hosts bypassed, the stand-in goes to GitHub as-is.
- **Why that breaks Amp's working path:** Amp installs `~/.amp/bin/gh`, a wrapper that, **only if `GH_TOKEN` and `GITHUB_TOKEN` are empty**, fetches a repo-scoped token through Amp's git credential helper. sbx's stand-in is never empty, so the wrapper skips Amp's credential. git itself is unaffected: it uses Amp's credential helper directly, so clone and push work.
- **Proof, no token copied:** in the repo, `~/.amp/bin/gh api rate_limit` with the stand-in fails. The same with `env -u GH_TOKEN -u GITHUB_TOKEN` returns a limit of **15000** (authenticated) and sees the test repo as private with **`admin: true`**. **Note: the token from the GitHub account connected in Amp has admin on the repo**, broader than an orb needs.
- **Fix applied (2026-11-02 23:30 UTC, operator):** the dispatch starts the bootstrap as `env -u GH_TOKEN -u GITHUB_TOKEN amp orb bootstrap`, so the headless agent and everything it starts inherit no stand-in, and Amp's wrapper supplies the repo-scoped token. PID 1 keeps sbx's stand-in, so anything started via plain `sbx exec` still sees it. The dry run now checks that the bootstrap's environment has neither variable while PID 1 still does, and fails if the dispatch loses the `env -u`. **Canary passed with it.** **Real-thread verification** (T-01a19e9d…, "GitHub auth status check", 2026-11-02 ~23:38 UTC; booted from the new project snapshot `snap-64b19024…`, image case 1, large):
  - Operator: `gh auth status` / `gh api rate_limit` show **the operator's account, limit 15000** in the **agent's shell, a Terminal session and the Desktop terminal (foot)**.
  - Process environments (names only): **no `GH_TOKEN`/`GITHUB_TOKEN`** in `amp orb bootstrap`, the headless supervisor and `amp --headless`, the Terminal (`tmux -L amp-terminal`, its login shell), the whole Desktop stack (`runuser … supervise`, labwc, Xwayland, waymote, pulseaudio) or foot and its shell. Everything Amp starts descends from the bootstrap.
  - **Still carrying sbx's stand-in, as expected:** PID 1 and its `sleep infinity`, dockerd/containerd (sbx starts them; containers don't inherit dockerd's env), and the keep-alive's in-orb `sleep infinity` (an `sbx exec` session). None run user work.
  - **After pause and resume:** Amp's idle pause at 2026-11-02 23:57:07 UTC (no snapshot ID; keep-alive stopped, 4 per-orb rules kept); it was resumed by hand, spawn (resume) at 23:59:49 UTC took 7.1 s. Operator: the agent's shell shows **the operator's account, limit 15000**. Process environments after the resume: `amp orb bootstrap`, the headless supervisor and `amp --headless` have **no `GH_TOKEN`/`GITHUB_TOKEN`**. Only sbx's own processes, restarted at 23:59:49 (PID 1, `sleep`, dockerd, containerd, the keep-alive's `sleep`), carry the stand-in. Terminal and Desktop weren't reopened after the resume; they start under the same clean bootstrap.
  - **All four places pass** (agent shell, Terminal, Desktop terminal, after pause/resume). The auth-check thread (T-01a19e9d…) is kept for now; the operator decides later whether to delete it.
- **`admin: true` is the operator's role, not the token's permission.** The token from Amp's credential helper is a **GitHub App user-to-server token (`ghu_`)** (classified by prefix inside the orb; never printed). For that token type the repo's `permissions` object reflects the *user's* role (the operator owns the repo). Read-only probes, with GitHub's `X-Accepted-GitHub-Permissions` header naming what each endpoint needs:
  - **200:** repo metadata, README (`contents=read`), **webhooks (`repository_hooks=read`)**, `/user`.
  - **403:** Actions settings, deploy keys, branch protection, runners (all `administration=read`), Actions secrets (`secrets=read`), `installation/repositories` (not an installation token).
  - So the token has **no administration permission** (it can't change settings or delete the repo) and no secrets access, but it **can read webhook configuration**. Writes weren't probed; push works, so it has contents write.

**The Amp pin doesn't reach inside orbs.**
- The pinned image `5d3181e4` ships Amp `0.0.1793599532-g4b614a`. At the first `amp orb bootstrap` (no settings file in the orb, so default update mode) the CLI **self-updated to upstream's latest, `0.0.1793649628-g18d621`, and restarted into it** (cli.log: "Binary updated successfully … Restarting into the installed update"). Amp's setup then made `/usr/local/bin/amp` a symlink to `~/.amp/bin/amp`.
- Amp's headless supervisor also runs `/usr/local/bin/amp-headless-update-binary` before each `amp --headless` start; it consults `static.ampcode.com/cli/cli-version.txt` (plus Amp's "prepared release" and "skip next update" files).
- **So `update-orbs` / `rollback-orbs` control:** the host Amp CLI that runs `amp orb provider` (pinned, self-update off), and the orb image digest (base OS, Desktop stack, baked-in Amp, Docker, our patches). **They don't control the Amp CLI version running inside orbs**: that becomes upstream's latest at each orb's first bootstrap, and a project snapshot freezes whatever ran when it was taken (until its next update).
- Pinning it would mean passing `AMP_SKIP_UPDATE_CHECK=1` into the bootstrap and defeating the supervisor's updater. Not done: the in-orb CLI talks to Amp's server, and Amp may require a current client. Question added to the Amp report.

### Patch 3: `/usr/bin/git` → Amp's git (2026-11-03)

- **Why:** tests that hardcode `/usr/bin/git` got Debian's 2.39.5, while PATH git is Amp's `/opt/git/bin/git` 2.55.0; they need ≥ 2.40.
- **Patch** (patch rev 3 in `install.sh orb_dockerfile`): `USER root` → `ln -sf /opt/git/bin/git /usr/bin/git` (with `test -x` and a `--version` run in the build) → `USER user`, so the image's default user is unchanged. The binary resolves its own helpers, so `/usr/bin/git` subcommands work.
- **Recipe per revision:** each pin carries its own `patch=`, and `orb_dockerfile DIGEST REV` builds that revision's recipe. Rev 2 output is byte-for-byte the old recipe, so the `-p2` rollback target still checks out and would rebuild identically.
- **Rollout:** the normal cycle, holding the other two inputs so only the patch changes: `UPDATE_IMAGE=keep UPDATE_CLI=keep ./install.sh update-orbs` (new options; a patch-rev bump alone now counts as an update).
  - It built `<host>/amp-orb:5d3181e4c7f5-p3`, then ran the canary on it. Passed, including the **new check: `/usr/bin/git --version` = 2.55.0 (≥ 2.40), and `init` + `commit` with it work**.
  - Switched (pin `5d3181e4c7f5-p3`; rollback target `5d3181e4c7f5-p2`) in 4 min 9 s.
  - **Amp CLI not updated** (still `0.0.1793592041-g8ba069`; upstream has `0.0.1793664053-ga6248e`).
  - **No provider restart:** the dispatch reads the pin per job, and only a CLI change restarts the provider (which would pause running orbs).
- **Bug found and fixed in the same cycle:** with the CLI unchanged, the switch still moved a copy of the binary into place. That left the running provider's executable "(deleted)", and the drift check reported `FAIL provider runs a replaced binary`, which tomorrow's canary would have mailed as a false alarm. Fixes: (1) `update-orbs`/`rollback-orbs` leave the live binary file alone when the version doesn't change; (2) `drift.sh` compares content when the running exe is unlinked: an identical copy is ok, a different binary still fails. Drift is all ok now, without a restart.
- **Stale snapshot deleted:** `amp-orb-snapshot:snap-64b19024-…` (the test repo's project snapshot, taken from `-p2`, with the old `/usr/bin/git`). The next thread in that repo gets that ID from Amp, finds no local template, and boots the `-p3` template (image case 2, repository setup re-runs). Amp's post-setup pause then saved a fresh snapshot under the same ID from `-p3`. That didn't happen again on 2026-11-08 (see "A snapshot missing on the host" under Operations), so don't count on it.
- **Deleting a template doesn't break orbs created from it** (tested before deleting, on throwaway orbs): A from `-p3` → pause with snapshot T → B from T + marker file → pause → delete A and T → **resume B: started, marker intact**; cleanup left no sandbox, rule, state file or keep-alive. So the three existing orbs created from `snap-64b19024…` (`amp-01a19e9d…`, `amp-01a19ed4…`, `amp-01a19ede…`, all stopped) stay usable. **They keep the old `/usr/bin/git` 2.39.5** until their threads are deleted; only new orbs get patch 3.
- **Still stale:** template `d64c8fb7b6c9-p2` (no longer the rollback target). `prune_orb_templates` skips while any orb sandbox exists. Given the test above, that guard is over-cautious and could become "never prune the current or previous template".
- sbx gotcha, again: a script fed on stdin (`bash -s <<EOF`) was cut off by an `sbx exec` inside it during the template test. Pass scripts as arguments with `</dev/null`.

### Operations

**Daily canary.**
- `amp-orb-canary.timer`, 11:00 UTC ± 15 min, `Persistent=true`, runs `amp-orb-canary.service` as agent: `~agent/orb/canary.sh` = `dryrun.sh` (spawn, repeat spawn, pause+snapshot, resume, delete, spawn-from-snapshot, pinned spawn) then `drift.sh`. It mails only on failure (the host's `OnFailure=` alerting).
- The dry run's EXIT trap deletes the test orb through the dispatch (keep-alive included) and its snapshot, then fails if any sandbox, per-orb rule or keep-alive is left. It holds `~/orb/run/dryrun.lock`, and its rule checks only count rules scoped to `amp-dryrun`, so a real orb spawning meanwhile can't cause false failures.
- `drift.sh` fails on: the pinned template missing; the pinned image no longer resolvable upstream; installed CLI ≠ pinned; provider not running, or running a replaced binary; `AMP_SKIP_UPDATE_CHECK=1` missing from the provider; `amp.updates.mode` not `disabled`; `feature.udp-egress` off. A newer upstream CLI or image is only `INFO` (no mail), because Amp's `:latest` moves several times an hour.
- First run: passed in 2 min 24 s (05:52 UTC).
- **History logs capped at ~30 days (2026-11-03):** the dispatch's `~agent/orb/run/usr-bin-git.log` and `amp-secret-names.log` are trimmed by `trimlogs.sh`. `canary.sh` calls it first, so it runs daily even if the dry run fails. It keeps lines whose leading UTC timestamp is within 30 days (`TRIM_DAYS`) and drops older or malformed lines, using only awk, flock and mv. The dispatch's appends and the trim take the same `flock` on `<log>.lock`, so a pause writing mid-trim can't lose a line. Tested on a fixture (40-day-old and malformed lines dropped; 29-day-old and current kept) and in a canary run (trim ran, locked appends still wrote).
- **If the host has other modes of use, tie the canary timer to the mode that allows orbs**, so the canary **never spawns an orb when orbs shouldn't run**. Same for the provider.

**A snapshot missing on the host (2026-11-08).**
- After the template rename, Amp kept sending the project's existing snapshot ID (`snap-8cb5afe6…`, refreshed the same day). Under the new name no such template existed, so both test threads booted the pinned template (image case 3) and ran full setup, and **Amp sent no post-setup snapshot pause**: it still considered its snapshot valid. Every thread in the project would have rerun setup until the snapshot's 72-hour refresh.
- Fix: `amp projects snapshots delete <owner/repo>` (all sizes; `--resource` for one). The next thread ran setup, Amp paused it right after (`saved snapshot localhost/amp-orb-snapshot:snap-e02489a4…`, 53 s save), and the following thread booted from it (image case 1): first output in ~20 s instead of ~3 min.
- Applies whenever a snapshot template disappears from the host: a rename, manual cleanup, a rebuilt host. Delete the project's snapshots in Amp afterwards.

**Amp CLI pinned, self-update off.**
- Two controls, both set: `AMP_SKIP_UPDATE_CHECK=1` in `amp-orb-provider.service` ("disables automatic update checking. Manual updates will still work") and `"amp.updates.mode": "disabled"` in `~agent/.config/amp/settings.json` (also stops `--no-tui` runner self-updates).
- `amp-orb.pin` now holds `amp_cli=`. `./install.sh amp-cli` installs exactly that build from `static.ampcode.com/cli/<version>/amp-linux-x64`, checks the published `linux-x64-amp.sha256` and the reported version, and no longer runs Amp's installer (which edits `.bashrc` and `~/.local/bin`). The provider restarted on the pinned build at 05:51:46 with the env var present.
- **Not pinned: the amp inside each orb.** Amp's bootstrap updates the in-orb copy (`/home/user/.amp/bin/amp`) itself. Pinning it could break threads against Amp's server.

**Update procedure (on the operator's schedule).**
1. `./install.sh status`: the drift section lists `INFO newer …` when upstream moved.
2. `./install.sh update-orbs`. It:
   - reads upstream `cli-version.txt` and the orb image `:latest` digest, and stops if both match the pin;
   - writes `amp-orb.pin.candidate`, builds that template (~90 s), and downloads and verifies the candidate CLI as `~agent/.amp/bin/amp.candidate` (nothing live changes);
   - **canary gate:** runs the full dry run against the candidate template. On failure it drops the candidate pin and binary and stops, with nothing switched;
   - **switch:** current pin → `amp-orb.pin.previous`, candidate → `amp-orb.pin`; `amp` → `amp.previous`, `amp.candidate` → `amp`; installs both pins in `~agent/orb`; restarts the provider (running orbs pause and resume on the next message, as tested in run 2);
   - if the provider doesn't log `Orb provider started` with the new version within 30 s, it **rolls back automatically**;
   - prunes orb templates other than current and previous, only when no orb sandbox exists.
3. Commit `amp-orb.pin` and `amp-orb.pin.previous`.
4. Optionally start one real thread. The dry run covers the image and dispatch, not the CLI↔Amp protocol; the provider's start-up is the CLI's first real test.

**Rollback (one command): `./install.sh rollback-orbs`.** It checks that the previous template is loaded and that `amp.previous` reports the previous version, then swaps current ↔ previous (pin files and binaries), reinstalls the pins, restarts the provider and runs the drift check. Running it again rolls forward. Commit the two pin files afterwards. Not exercised yet: it needs a first real update to create a previous pin.

### Notes to send upstream (final, 2026-11-02)

#### To Docker: Docker Sandboxes (sbx) v0.50.1

**Subject:** sbx local sandboxes: custom template that ships dockerd is created without DinD and then bricked; plus auto-stop, UDP and CLI issues

Environment: sbx v0.50.1 (`ddb0268d`, apt `docker-sbx 0.50.1-1~ubuntu.26.04~resolute`), Ubuntu Server 26.04, x86_64, local sandboxes (nerdbox microVMs). Use case: running Amp's self-hosted orb image as an sbx template, launched by a host-side dispatcher.

1. **A custom template with dockerd but no DinD label is created "successfully" and then can't be used.** `sbx create shell --template <image>` on an image that ships `dockerd` but lacks `com.docker.sandboxes.start-docker=true` logs `created sandbox container … dind=False`. The sandbox gets no netfilter privileges and no `/var/lib/docker` volume. sbx then starts and health-checks dockerd anyway. dockerd dies (`iptables --wait -t nat -N DOCKER: … Could not fetch rule set generation id: Permission denied (you must be root)`; `nft: cache initialization failed: Operation not permitted`), and every later `sbx exec` exits 125 with `docker daemon failed to start inside the sandbox`. Meanwhile `sbx create` exits 0 and `sbx ls` shows the sandbox as running.
   - Expected: don't start dockerd when DinD isn't granted, or fail `create` with a message naming the label.
   - Please document `com.docker.sandboxes.start-docker` for custom templates.
   - Repro image: `us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:d64c8fb7b6c9a0bded61adc97876fa83ebdd1c2378cc382525c7edbdbd69ccfb`. Adding only that label fixes it.
2. **Detached workloads need long-running, which built-in agents can't get.** Local sandboxes auto-stop 30 s after the last session disconnects (`auto-stop grace period expired … auto-stopped runtime after last session disconnected`). `com.docker.sandbox/long-running@1` exists only for v3 kits, and `sbx create shell --kit <v3 mixin with long-running@1>` is rejected (`no kit in the set defines the sandbox itself … built-in agents such as "shell" are not v3 kits`). A v3 workload kit can't reference an existing image; it rebuilds from a recipe, and the first use leaves `sbx-kit-builder` running detached. We now hold an idle `sbx exec <sandbox> sleep infinity` per sandbox as a workaround. Please offer long-running for built-in agents and existing templates: a `sbx create` flag, a setting, or a v1/v2 kit field.
3. **UDP egress silently needs an undocumented experimental flag.** `sbx policy allow network --sandbox <name> --protocol udp 104.30.0.0/15` saves the rule but warns `UDP egress is disabled; enable experimental features and feature.udp-egress`; traffic stays blocked (`VM Network: BLOCKED direct UDP connection attempt, proxy enforcement`). `feature.udp-egress` doesn't appear in `sbx settings ls`, but `sbx settings set feature.udp-egress true` works. Please list and document it, and say whether it will become a stable setting (we depend on it for WebRTC). It would also help if allowed UDP flows were logged, not only blocked ones.
4. **An sbx CLI call reads stdin when it shouldn't.** A script fed with `bash -s < script.sh` that calls `sbx create`, `sbx policy allow` and `sbx exec <sandbox> <cmd>` (no `-i`) stops partway, silently: one of those calls consumes the rest of the script from stdin. It died right after an `sbx exec` without `-i`, but we didn't isolate which call it was. With `</dev/null` on the sbx calls it runs to the end. Expected: only `exec -i` reads stdin, as with `docker exec`.
5. **`sbx exec` doesn't exit promptly on SIGTERM.** A long-running `sbx exec <sandbox> sleep infinity` is still alive 5 s after SIGTERM, every time; SIGKILL ends it. Expected: SIGTERM ends the session and the CLI exits.
6. **Clone mode is invisible until it's too late.** For a sandbox created with `--clone`, neither `sbx ls --json` nor the host repo shows it while the sandbox is stopped (the `sandbox-<name>` remote is only present while running). The only signal is a warning printed *by* `sbx rm --force` after removal (`commits the agent made inside it are lost on removal unless fetched first`). Please show the workspace mode in `sbx ls`, and warn or refuse in `sbx rm` *before* removing a clone with unfetched work.
7. **Local inspection and per-sandbox disk size.** `sbx template inspect` is cloud-only (`requires --cloud in v1; local templates are docker images; inspect them with Docker`), so a host without Docker can't see a local template's labels. And the per-sandbox override `DOCKER_SANDBOXES_DOCKER_SIZE` is documented only inside the `sandbox.disk.dockerVolume` setting's description; a `sbx create --docker-volume-size` flag would be clearer.
8. **`sbx kit builder rm` leaves a volume behind.** After a single v3 kit build (`sbx create shell --kit <dir>` creates `sbx-kit-builder`) and `sbx kit builder rm --force`, a `sandbox-volume-80aac671…img` (10 GB sparse, 0.5 GB used) remains under sandboxd's `com.docker.volume.driver.v1.block/images/`, last written when the builder ran. No local command lists or removes it (`sbx volume` is cloud-only). Expected: removing the builder removes its volume, or a local `sbx volume ls/rm`.
9. **A useless, harmful GitHub stand-in.** With `SBX_CRED_GITHUB_MODE=none` (no `github` secret stored), sbx still puts a GitHub-shaped stand-in `GH_TOKEN` into the sandbox's PID 1 environment, while `github.com`/`api.github.com` are `forward-bypass` (nothing could ever swap it). Tools that prefer `GH_TOKEN` then fail with "Bad credentials" instead of falling back to their own auth (Amp's `gh` wrapper, for example). Expected: don't set the stand-in when no secret is configured for that service.

#### To Amp: self-hosted orbs

**Subject:** Self-hosted orbs on Docker Sandboxes (sbx): what the stock orb image needs, plus Desktop and provider questions

Context: we run `amp orb provider` (CLI `0.0.1793592041-g8ba069`) under systemd with a dispatch that creates each orb as a Docker Sandboxes (sbx v0.50.1) microVM from the stock orb image (`amp-orb@sha256:d64c8fb7b6c9…`). Spawn, pause with snapshot, resume, delete, project snapshots and recovery after a provider restart all work, and so does Desktop, after the changes below. Most of them come from the image assuming systemd as PID 1. Your own Docker dispatch example (`sleep infinity` as PID 1) would hit items 2 and 3 too.

1. **Add the sbx DinD label to the orb image.** sbx only grants Docker-in-Docker to images labelled `com.docker.sandboxes.start-docker=true`. The orb image ships dockerd, so without the label the sandbox can't be used at all. The label is harmless elsewhere.
2. **cgroup driver.** `/etc/docker/daemon.json` sets `"exec-opts": ["native.cgroupdriver=systemd"]` with `"cgroup-parent": "amp-workload.slice"`. Without systemd as PID 1, `docker run` inside the orb fails (`systemd not running on this host, cannot use systemd cgroups manager`). We patch it to `cgroupfs`. Could the image fall back to cgroupfs when `/run/systemd/system` is absent?
3. **Desktop dock clicks fail without `/run/lock`.** `/opt/amp-desktop/install-app` does `exec 9>/run/lock/amp-desktop-install.lock` first. Where systemd-tmpfiles hasn't run (`/run` is a fresh tmpfs), it exits 1, the UI shows "Desktop command exited with code 1", and `launch-app` never runs. Chrome's install at desktop start fails the same way. We run `systemd-tmpfiles --create --prefix=/run` on every spawn. Could install-app create its lock directory, or lock under `$XDG_RUNTIME_DIR`? (`launch-app`'s existing no-systemd fallback works well.)
4. **Desktop's network needs.** Desktop renders, streams and takes input only once the orb may send **UDP** to relays in `104.30.0.0/15`; it also tries direct UDP to the viewer's public IP, which we keep blocked. Please document the hosts and ports Desktop needs. Can it fall back to TURN over TCP/TLS on 443 when UDP is unavailable? Many sandboxes and corporate egress proxies are TCP-only.
5. **Provider self-update under a service manager.** A provider running under systemd logged `Update installed, but amp on PATH differs; restart the provider manually`: the binary was replaced underneath it, and it kept running the old one. We now pin the CLI and set `AMP_SKIP_UPDATE_CHECK=1` plus `"amp.updates.mode": "disabled"`. Please document the recommended update setup for providers, and whether provider and server versions must stay in step.
6. **Snapshot lifecycle docs.** Observed: `pause` sends `ORB_SNAPSHOT_ID` (`snap-<uuid>-<hash>`), the first time about 13 s after the initial spawn. Resume of an existing orb sends no snapshot ID. A *new* thread in the same project sends that ID on `spawn`, and `ORB_IMAGE` always carries the provider's override. `delete` doesn't mention the snapshot, so a provider that stores snapshots locally never learns when one is obsolete. Does deleting a project snapshot in Amp send any job? If not, could it (e.g. `ORB_OPERATION=delete-snapshot`)? A sentence in the docs on which operations carry which variables would help too.
7. **`gh` in orbs vs. sandbox runtimes that set `GH_TOKEN`.** Your `~/.amp/bin/gh` wrapper only fetches the repo-scoped token when `GH_TOKEN`/`GITHUB_TOKEN` are empty. Docker Sandboxes sets a stand-in `GH_TOKEN` in every sandbox, so `gh` ends up with an invalid token, while git (credential helper) works. Could the bootstrap or wrapper prefer Amp's credential inside orbs? Separately: the orb's token (a GitHub App user-to-server `ghu_` token) has no administration permission, but it does have `repository_hooks=read`. Does an orb need webhook read? A narrower default would be welcome.
8. **Amp CLI version inside orbs.** The bootstrap self-updates the image's Amp CLI to upstream latest at first start, and the headless supervisor updates it again. A provider that pins its host CLI and orb image still gets a moving in-orb CLI. Is there a supported way to pin it (e.g. `AMP_SKIP_UPDATE_CHECK=1` for bootstrap), and must the in-orb CLI match the server's current release?

### Numbers

| What | Value |
|---|---|
| First pull of Amp orb image into sbx | 72 s, 1.78 GB compressed, 6.19 GB unpacked |
| Patched template rebuild, label only (p1) | 71 s |
| Patched template rebuild, label + daemon.json (p2) | 86 s |
| `sbx create` from local template | 1.8 s |
| `sbx rm --force` | 0.5 s |
| Host memory of one idle **large** orb VM (nerdbox shim RSS, 3 s samples during the canary) | 0.93–1.39 GB; peak 2.04 GB (during the spawn/pause/resume steps); host MemAvailable −1.4 GB |
| Host memory of one **small** orb VM | ~1.18 GB (single sample during its ~13 s life) |
| sbx state on disk (2 sbx templates + orb template) | 5.0 GB |

### Proposal: root-owned orb install (separate change, not done)

Same shape as the runner change, orb side only. Nothing below is shared with the runner side.

1. **Install dir `/usr/local/lib/<host>/orb/`, root:root:** `dispatch.sh`, `provider.sh`, `dryrun.sh`, `drift.sh`, `canary.sh`, `trimlogs.sh`, `amp-orb.pin`, `amp-orb.pin.previous`. State stays in `~agent/orb/run` (keep-alive and type files, `usr-bin-git.log`, `amp-secret-names.log`, `dryrun.lock`).
2. **Hard-coded paths to change:**
   - `dryrun.sh` (`D=~/orb/dispatch.sh`, `~/orb/amp-orb.pin.previous`) and the `ORB_PIN` defaults in `dryrun.sh`/`drift.sh` → relative to the script's own directory.
   - In `install.sh`, split `HOST_ORB` into an install dir and a state dir.
   - `update-orbs` currently stages `amp-orb.pin.candidate` as agent in `~agent/orb`; root would install it into the lib dir instead.
   - `orb_provider` installs root:root and removes the old copies once the provider no longer runs them.
   - Units: `amp-orb-provider.service` `ExecStart=/usr/local/lib/<host>/orb/provider.sh`, `amp-orb-canary.service` `ExecStart=…/orb/canary.sh`.
3. **The Amp CLI binary, the bigger gap.** The provider execs `~agent/.amp/bin/amp`, which agent can overwrite (and which a self-update would replace; PATH has `~/.amp/bin` first for that reason). Proposal: install the pinned CLI root-owned as `/usr/local/lib/<host>/orb/bin/amp`, plus `amp.previous` for rollback. `amp_fetch` would download and verify as agent into a temp file, then root installs it.
   - Point `provider.sh` and `drift.sh` at it, and put that `bin/` first on the unit's PATH instead of `~/.amp/bin`.
   - Drift's "provider runs a replaced binary" check then only guards against root-level changes.
   - **To test first:** that `amp orb provider` doesn't complain ("amp on PATH differs") or try to write next to its binary, and that `amp orb bootstrap` inside orbs is unaffected (it uses the orb image's own amp, not the host's).
4. **Status/drift:** the same ownership check as `ghr_status` (every file root:root, nothing group/other-writable; the running provider's executable is under the lib dir). Also fix the unit's "readable only by this service" credential comment.
5. **Rollout:**
   - Needs a provider restart, which pauses running orbs (they resume on the next message): do it when `status` shows no running orb. The evidence orb `amp-01a19f86…` is stopped and not touched.
   - Verify with the canary (dispatch dry run + drift), then one real thread.
   - Needs the operator's go-ahead and permission for `./install.sh orb-provider` and `systemctl restart amp-orb-provider`, which are outside the current allow list.
   - It also installs the fixed `drift.sh`.
