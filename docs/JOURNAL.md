# 🛠️ Homelab Build Journal

This is my running log of building the homelab — every command, every thing that
broke, and the fix that actually worked. It's written for future-me: when something
breaks again at 1am, I want to **Ctrl-F the error** ("401", "no route to host",
"NO-CARRIER") and jump straight to what solved it last time.

**How to read this**
- Newest session is at the top.
- Each session: what I set out to do, the exact commands, what went wrong, and how I
  fixed it.
- The 🔥 **Gotchas index** at the very bottom is the fast lookup for "this happened again."

> Public copy — my real domains are redacted to `your-domain.example` /
> `your-mail.example`. The un-redacted version lives in my private notes repo.

**Fleet quick reference**

| Node | IP | Role | Status |
|---|---|---|---|
| k8plus | 192.168.0.11 | family-prod (Jellyfin, Nextcloud, **Immich**, media, PBS) | 🟢 live · clustered |
| g11 | 192.168.0.12 | core-infra (**DNS, proxy, monitoring, GitLab** — done) | 🟢 live · clustered |
| macbook | 192.168.0.13 | lab (**K3s cluster + ArgoCD — live**) | 🟢 live · clustered |
| K3s VMs | k3s-server .41 · k3s-agent1 .42 · k3s-agent2 .43 | disposable lab tier (Terraform + Ansible) | 🟢 live |
| Z13 (control) | 192.168.0.239 (DHCP) | Ansible control node (WSL) | 🟢 |
| VMs | family-vm .21 · media-vm .22 · **runner-vm .25** · monitor-vm .31 · gitlab-vm .32 | Docker hosts | 🟢 live |

- **LAN / subnet:** 192.168.0.0/24, gateway 192.168.0.1
- **Switch:** **MikroTik CRS310-8G+2S+** (RouterOS, managed) in place → VLAN segmentation in progress (JetKVM out-of-band console on k8plus)
- **Web:** your-domain.example (Cloudflare Tunnel) · **Email:** Proton Mail on your-mail.example
- **Cluster:** 3-node Proxmox VE 9, quorate (survives losing any one node)
- **Repo:** homelab-infra (public) ← the whole build as code

---

## Session 13 — 2026-08-03/05 · The lab tier: K3s, then ArgoCD, then commit-to-deploy

**Goal:** Phase 3. The repo has promised a GitOps pipeline since day one and had no Kubernetes in it.

**Outcome:** ✅ 3-node K3s cluster on the MacBook — Terraform for the VMs, Ansible for K3s.
✅ ArgoCD installed and authenticated to my own GitLab with a read-only deploy token.
✅ **Commit-to-deploy proven** — pushed a replica count change, watched a third pod appear, no
`kubectl` anywhere. The README's central claim is finally demonstrable.

### What I did
1. **Fixed and applied `k3s-lab.tf`** — written in Phase 0, never applied, and carrying four
   mistakes I've learned since (below).
2. **Wrote `k3s_server` + `k3s_agent` roles** with a cross-host join-token handoff.
3. **Installed ArgoCD**, created a GitLab deploy token, wired up the repo credential.
4. **Proved the loop** — then proved `selfHeal` by scaling by hand and watching ArgoCD undo it.

### Errors & fixes 🔥

**`k3s-lab.tf` had aged badly sitting still**

Four things it was missing, each one a lesson I'd already paid for elsewhere:

- **No `dns {}`** — VMs would boot with a static IP and no resolver (the 07-25 bug).
- **`clone {}` with no `node_name`** — template 9000 is on k8plus, these land on macbook. Cross-node
  clone needs the source named.
- **No `full = true`** — changing that flag later forces VM replacement (Session 7).
- **No `cpu { type = "host" }`** — would have got `qemu64`, the model that crash-looped Immich's ML.

> **Unapplied IaC is a snapshot of what you knew when you wrote it. Re-read old files before applying.**

---

**`terraform plan` said "3 to add, 5 to change"**

The 5 were my existing family VMs, carrying `dns{}`/`cpu.type` drift I'd deliberately parked.

A plain apply would have rebooted all five — including monitor-vm (AdGuard, so LAN DNS) and
gitlab-vm, which is slow to come back. Used `-target=proxmox_virtual_environment_vm.k3s`.

> **Read the change count, not just the add count.**

---

**Getting the join token from the server play to the agent play**

The server generates a token the agents need, so this isn't one role applied three times. Split the
inventory into `k3s_server` and `k3s_agents` children; two roles, two plays, ordered.

```yaml
- name: Read the join token
  ansible.builtin.slurp:
    src: /var/lib/rancher/k3s/server/node-token
  register: k3s_token_raw
  no_log: true

- name: Expose the token to the agent play
  ansible.builtin.set_fact:
    k3s_node_token: "{{ k3s_token_raw.content | b64decode | trim }}"
  no_log: true
```

`slurp` always returns base64, hence `| b64decode`. The `| trim` drops a trailing newline that would
otherwise be part of the token and cause a baffling auth failure.

> **`set_fact` crosses hosts; `register` doesn't.** A registered var belongs to the host that ran the
> task; a fact is readable as `hostvars['k3s-server'].k3s_node_token`.

Installed with `get_url` + a separate `command` and a `creates:` guard — never `curl | sh`, same
pipefail reason as the tailscale role. No `docker` role: K3s ships its own containerd.

---

**`ok=1, changed=0` on every host**

Every play runs `Gathering Facts` regardless of tags, so `ok=1` means *only* that ran.

Cause: I hadn't added the k3s plays to `site.yml` yet. Ansible reported success because nothing
failed. Nothing ran either.

> **Same family as the `compose_stack` bug: a green result that didn't do the thing.**

---

**`nslookup git.lab` from a pod printed an address AND an NXDOMAIN**

Both true. busybox queries A and AAAA; the A record returned `192.168.0.31`, the AAAA returned
NXDOMAIN because my AdGuard rewrite is IPv4-only. busybox prints the failure and exits non-zero.

---

**`alpine/git` couldn't resolve it at all**

Alpine is **musl libc**, whose resolver issues A and AAAA in parallel and can fail the whole lookup
when one comes back empty. glibc images are fine.

> **If a container can't resolve what the host resolves, check the base image before blaming DNS.**

---

**`git.lab` resolved from a pod at 09:31 but not 09:29**

`ndots:5`. Kubernetes gives pods a resolv.conf with a search list, and a 1-dot name gets tried
against the cluster domains **first**:

```
git.lab.argocd.svc.cluster.local   ← NXDOMAIN
git.lab.svc.cluster.local          ← NXDOMAIN
git.lab.cluster.local              ← NXDOMAIN
git.lab                            ← finally
```

Three wasted round-trips against AdGuard. It works, but falls over under any latency.

Fix (not yet applied): `hostAliases` on the repo-server, or a trailing dot — `http://git.lab./…` —
to mark the name absolute.

> **That's the fourth DNS layer: router/AdGuard → VM → Docker daemon → CoreDNS + ndots.**

---

**ArgoCD needed credentials, and one of them can never live in git**

The GitLab project is private. Used a **deploy token scoped to `read_repository`** rather than making
the project public — least privilege, revocable separately from my account.

ArgoCD finds repo credentials from secrets in its own namespace labelled
`argocd.argoproj.io/secret-type: repository`, matched to Applications by `url`, which must equal
`repoURL` character for character. Created with `--from-literal` so the token never touched disk.

> **That secret has to be applied by hand, outside git. You can't store the credential that lets
> ArgoCD read git *in* git.** Every GitOps setup has this bootstrap gap — it belongs in a runbook,
> not quietly skipped.

---

**Root Application stuck at `SYNC STATUS: Unknown`** 🔥

Meaning it never read the repo at all. The `HEALTH: Healthy` beside it was meaningless — reporting
on zero resources.

repo-server logs showed it fetching `gitlab.your-domain.example`, the **redaction placeholder**. My
working copy was already fixed, so the useful move was to check the commit:

```bash
git show 3e0ad71:kubernetes/argocd/apps/demo-app.yaml | grep repoURL   # placeholder
git show HEAD:kubernetes/argocd/apps/demo-app.yaml     | grep repoURL   # correct
```

The fix had landed *after* the commit ArgoCD read.

> **Rule:** ArgoCD only sees what's in git — the working copy is invisible. With `kubectl apply` the
> local file is the source of truth; here it's just a draft. Debug **Application → commit → file at
> that commit**, never "check the file".

Forced a re-read with the `argocd.argoproj.io/refresh: hard` annotation rather than waiting out the
3-minute poll.

---

**Then it worked**

`root` → creates `demo-app` → creates the namespace, Deployment and Service. **One manual
`kubectl apply`, ever.** That's app-of-apps, and why the root Application's `path` points at a
directory of Applications rather than at workloads.

Changed `replicas: 2` → `3`, committed, pushed, watched a third pod appear. Commit-to-deploy, on
hardware in my flat.

---

**The Service EXTERNAL-IP stayed `<pending>`**

K3s's klipper-lb implements LoadBalancers by binding a hostPort on every node, and Traefik (installed
by K3s) already owns :80. Not a bug — two things wanting one port.

NodePort works meanwhile. The right fix is an Ingress through that Traefik, which also fits my
existing `*.lab` pattern.

---

**ENTRYPOINT, third time in three days**

`kubectl run --image=alpine/git -- git ls-remote …` → *"git is not a git command"*. The image sets
`git` as ENTRYPOINT, so my args were appended to it.

Args after `--` become `args` (appended); `--command` makes them `command` (replacing). Docker calls
the pair `entrypoint`/`cmd`; GitLab CI is `entrypoint: [""]`.

> **When a tool image says your command isn't a valid command, you're fighting its ENTRYPOINT.**

### Left open
- Ingress for demo-app via Traefik (`demo.lab`) instead of a LoadBalancer on port 80.
- `hostAliases` or absolute-name fix for the `ndots:5` flakiness.
- ArgoCD itself is installed imperatively from the upstream URL — it should manage its own
  installation declaratively.
- The lab is in Prometheus under `job_name: lab`; the node-down alert rule still needs scoping to
  `job="nodes"` so monthly teardown drills don't page.

---

## Session 12 — 2026-07-31 · First CI pipeline (and the DNS layer I forgot about)

**Goal:** Work-day session, remote. Get a first `.gitlab-ci.yml` running on my own runner.

**Outcome:** ✅ Pipeline green. ✅ `ansible-lint` from **46 findings to 0, on the `production`
profile**. Two were real bugs — one had been silently broken for weeks.

### What I did

1. **Split the CI work.** GitHub Actions keeps the public smoke test (fmt, yamllint, shellcheck)
   and the green badge; **GitLab does the deeper checks that benefit from the LAN** — ansible-lint,
   terraform validate, tflint. Two systems checking identical things would just drift apart.
2. **Wrote the smallest possible pipeline first** — one `hello` job on alpine, `echo` + `ls -la`.
   Useless on purpose: prove GitLab → runner → tags → container → result before anything real can
   muddy the diagnosis.
3. **Triaged 46 ansible-lint findings** into three buckets: real bugs, style I agree with, style I
   don't. The last get silenced *deliberately*, in a committed config with the reason in a comment.

### Errors & fixes 🔥

**Pipeline #1 died before my `script:` ran**

`Could not resolve host: git.lab` — exit code 128.

Every job **clones the repo first** (fresh container, nothing in it), so a failed fetch kills the
job before my commands get a turn.

The real cause: **runner-vm resolves `git.lab` fine, its containers don't.** Ubuntu's
systemd-resolved puts the loopback stub `127.0.0.53` in resolv.conf. Docker strips loopback when
building a container's resolv.conf, finds nothing left, and falls back to `8.8.8.8` — which has
never heard of `git.lab`.

Reproduce it in two lines on one machine:

```bash
getent hosts git.lab                                 # works
docker run --rm alpine:3.20 getent hosts git.lab     # fails
```

Fix at the daemon so every container inherits it:

```json
// /etc/docker/daemon.json
{ "dns": ["192.168.0.31", "1.1.1.1"] }
```

Validate with `python3 -m json.tool` **before** restarting — bad JSON and Docker won't start at all.

I could have pointed the clone URL at `192.168.0.32:8929` and skipped DNS entirely, but that fixes
this symptom only. The next job needing `grafana.lab` breaks again.

> **Rule:** three DNS layers — router/AdGuard → VM → Docker daemon. Fixing one doesn't fix the others.

---

**`nano /etc/docker/daemon.json` refused to save**

"Permission denied", but only at write time. `/etc` is root-owned; nano lets you type first.

`sudo nano`. For longer files: Ctrl+O to `/tmp/…`, then `sudo cp` into place.

---

**`requirements.yml` was incomplete**

ansible-lint couldn't resolve `ansible.posix.authorized_key`.

Works on the Z13 because the full `ansible` pip package bundles hundreds of collections. The repo
only declared `community.docker`, so anyone cloning and following my README would have failed.

CI itself also needs `ansible-galaxy collection install -r ansible/requirements.yml` — `pip install
ansible-lint` only brings `ansible-core`, the engine, with no collections.

> **A reproducibility bug, caught on the first clean-machine run. Exactly what CI is for.**

---

**The tailscale `when:` guard had never worked** 🔥

The find of the day:

```yaml
when: ts_status.rc != 0 or '"NeedsLogin" in ts_status.stdout' or ...
```

`when:` is **already** a Jinja context — Ansible wraps it in `{{ }}` for me. Quoting a
sub-expression makes it a **string literal**, and a non-empty string is truthy.

So the condition was permanently `True` and the join ran on every play, regardless of state.
Second guard bug in this same role — the first was `creates: tailscaled.state` (Session 9).

> **Rule:** verify a guard by running it against a converged host and confirming `skipped`.
> Reading it is not enough.

---

**`curl … | sh` reported success having installed nothing**

In a pipeline the exit code is the **last** command's. If curl fails, `sh` gets empty input, does
nothing, and exits 0 — so Ansible reports OK.

Fixed with `set -o pipefail &&` plus `executable: /bin/bash`. pipefail isn't POSIX sh, and Ubuntu's
`/bin/sh` is dash.

---

**Three `copy`/`template` tasks had no `mode:`**

Permissions fall back to the remote umask, so the same playbook gives different results on
different machines. One was `/etc/network/interfaces` — the file that takes a node offline if it's
wrong.

> **Always set `mode:`, always quote it.** Unquoted `0644` is parsed as an integer.

---

**Renaming handlers nearly broke things silently**

All 5 `name[casing]` findings were handlers, and `notify:` matches by **exact string**. Rename one
side only and the handler simply never fires — config changes, service never restarts.

Renamed both sides in one commit, then `grep -rn "notify:" ansible/` to prove nothing dangled.

---

**ansible-lint kept finding more as I fixed things**

It has escalating profiles — `min` → `basic` → `moderate` → … → `production` — and promotes you as
you clear each. Fine for learning, bad for a gate: strictness drifts upward on its own, and a tool
upgrade could redden a build with no code change.

Pinned it with `profile: production` in `.ansible-lint`.

---

**`before_script` and `script` are ONE shell**

A `cd` in the first leaks into the second. Broke the second job exactly that way.

Use paths from the repo root; `(cd dir && cmd)` in a subshell if a scoped `cd` is genuinely needed.

---

**A config file seemed to be ignored**

ansible-lint found `.ansible-lint` but yamllint never found `.yamllint`. ansible-lint walks *up*
from cwd; yamllint only checks the *current* directory. I was running `cd ansible && ansible-lint`.

Running `ansible-lint ansible/` from the repo root fixed it.

> **"Config isn't being picked up" is usually a working-directory problem, not a syntax one.**

---

**Pinned `ansible-lint` and it crashed on import**

I pinned the tool but not `ansible-core`, which floated to a version it couldn't work with.
Traceback entirely inside `site-packages` = dependency problem, not my code.

> **Rule:** pin what you've verified, not what you guessed. Let the resolver find a working set,
> read the versions off a green run, then freeze that combination.

---

**The vault decrypt warnings are a feature**

ansible-lint can't read `vault.yml` without the password, so it skips two rules on that file.

That warning is *proof the file is genuinely encrypted*. No separate vault-check job needed.

### Codified the DNS fix into the `docker` role

The morning's `daemon.json` was a hand-edit on one VM — it would vanish on a rebuild and CI would
break again with the same baffling error. Turned it into role code, and found the role was already
part of the problem: it hardcoded `DNS=192.168.0.1 1.1.1.1` into
`/etc/systemd/resolved.conf.d/dns.conf`, so **every `--tags docker` run silently reverted the
Terraform change to AdGuard.** Two sources of truth disagreeing, with Ansible winning because it
runs last.

Four pieces: a new `roles/docker/defaults/main.yml` holding `docker_dns_servers`, both DNS layers
now rendering from that one list, and a `Restart docker` handler. One list, two formats —
`| join(' ')` for the `[Resolve]` stanza, `| to_json` for `daemon.json`.

Best bit is `validate:` on the daemon.json copy:

```yaml
    validate: python3 -m json.tool %s
```

Ansible renders to a temp file, runs that command with `%s` = the temp path, and **only moves the
file into place if it exits 0**. Malformed JSON becomes a failed task on a still-working host
instead of a Docker daemon that won't start. Directly closes this morning's footgun.

**⭐ The router does NOT resolve `*.lab`.** I'd added a `host_vars/monitor-vm.yml` override pointing
that host at `192.168.0.1`, reasoning that monitor-vm shouldn't depend on the AdGuard it hosts. Then
one command across the fleet settled it:

```bash
ansible docker_hosts -m command -a "docker run --rm alpine:3.20 getent hosts git.lab"
```

Four hosts returned `192.168.0.31 git.lab`. monitor-vm — the only one on `.1` — returned `rc=2`,
name not found. **The router advertises AdGuard over DHCP but its own resolver forwards to its WAN
upstream**, so anything explicitly pointed at `.1` loses every internal name. Deleted the override.

Two lessons. First, always point resolvers at `192.168.0.31` directly — which makes the Terraform
`dns{}` change load-bearing rather than cosmetic. Second, the override traded a *theoretical*
robustness worry (a few seconds of self-reference during a restart, with `1.1.1.1` as fallback) for
a *concrete* permanent loss of `*.lab` on the host running Grafana, Loki, NPM and uptime-kuma. Bad
trade — and one `getent` across five hosts beat all the reasoning about it.

### Terraform jobs — and a lock file that was being thrown away

Added `terraform-validate` and `tflint` alongside `ansible-lint`, all three in the same `lint` stage
so they run in parallel. Both green first time.

**Finding: `.terraform.lock.hcl` was in `.gitignore`.** That file *is* the provider pin — exact
versions plus checksums, so every machine resolves identically. Ignoring it left
`version = "~> 0.60"` as the only control, which permits anything below 1.0 (I run 0.111.1), so CI
could silently resolve something different from local. This repo already has a scar from a provider
behaviour change forcing a VM replacement, so that's a live risk. Un-ignored and committed;
`.terraform/` stays ignored — that's the download cache, not the pin. **Same lesson as the
ansible-lint crash earlier the same day: pin what you've verified.**

**Gotcha — single-purpose images need their ENTRYPOINT blanked.** `hashicorp/terraform` sets
`terraform` as ENTRYPOINT, so GitLab's attempt to start a shell gets passed to terraform as
arguments (`Terraform has no command named "sh"`). Fix:

```yaml
image:
  name: hashicorp/terraform:1.9
  entrypoint: [""]
```

`image:` becomes a dictionary instead of a string. Same for the tflint image and most tool-shaped
containers.

**`-chdir=` beats `cd`.** Two Terraform directories to check, and after the morning's lesson about
`cd` leaking from `before_script` into `script`, used Terraform's own flag instead:
`terraform -chdir=terraform/proxmox validate`. Operates on that directory without moving the shell,
so the next line still resolves from the repo root. Also `-backend=false` (fetch providers, don't
touch state — CI has no business there and no credentials) and `-input=false` (never prompt; a
prompt in CI is just a hang until timeout).

### Monitoring: 4 of 10 hosts weren't being scraped

Went to add the two LXCs to Prometheus and found the fleet had outgrown the config.
`prometheus.yml` listed six targets; the fleet is **ten** (3 nodes + 5 VMs + 2 LXCs).

`gitlab-vm` and `runner-vm` were the embarrassing ones — `site.yml` applies `node_exporter` to all
of `docker_hosts`, so both were already exporting on :9100. Prometheus simply never asked. Two
hosts went from invisible to monitored by adding four lines. That matters most for gitlab-vm: it's
the heaviest service and it has already OOM-killed itself once.

The two LXCs needed real work: they were in no inventory at all. Added an `lxc_hosts` group, a
`site.yml` play applying `common` + `node_exporter`, and a one-time SSH bootstrap. Ansible can't
configure a host it can't log into, and neither container had an `authorized_keys`, so the way in
is via the Proxmox host:

```bash
pct exec <id> -- install -d -m 0700 /root/.ssh
pct push <id> /tmp/jc.pub /root/.ssh/authorized_keys --perms 600
```

Kept that manual and documented rather than codified — automating a bootstrap that only runs when
you have no access is effort spent on the least likely path. **Order matters**: install and verify
the key *before* running `common`, which sets `PasswordAuthentication no`.

Also wrote `docs/runbooks/lxc-rebuild.md` capturing both `pct config` outputs with the reasoning
behind each non-obvious flag. Writing it surfaced a dependency I'd never have stated otherwise:
**Jellyfin can read the media only because `umask=002` on k8plus's exFAT mount makes files
world-readable** — necessary because an unprivileged container can't map host UID 1000, so the
files appear as `nobody`. Tighten that umask for hygiene and Jellyfin silently loses the library.

### A stale mount on media-vm, three hosts downstream of a USB cable

Sonarr, Radarr and qBittorrent wouldn't start:

```
Error response from daemon: error while creating mount source path '/mnt/media': mkdir /mnt/media: file exists
```

The chain runs all the way back to the morning: the USB media disk re-enumerated on k8plus →
`/mnt/media` there went unmounted → the Samba share it serves went empty → media-vm's **CIFS client
mount went stale** → Docker refused the bind mount. Only those three containers failed because
they're the only ones that mount `/mnt/media`; Prowlarr and Jellyseerr were unaffected.

**Fixing the server side did not un-wedge the client.** Needed `umount -l` (lazy — a plain umount
refuses when the transport is dead) and `mount -a` on media-vm too. Also found the CIFS entry
**duplicated** in `/etc/fstab`, which would have systemd generating two competing `.mount` units for
one target.

Made it self-healing with `_netdev,x-systemd.automount,x-systemd.mount-timeout=30` — `_netdev` for
correct boot ordering, `automount` so the mount re-establishes on first access instead of needing a
human. (`systemctl daemon-reload` after editing fstab — systemd generates mount units from it.)

### The tailscale guard, take two — and why "fixed" isn't fixed

Re-ran the role against a converged host to confirm the join task now **skips**. It didn't skip —
it errored:

```
Conditional result (True) was derived from value of type 'str'
```

**The fix had never landed.** `changed_when: true` went in; the `when:` line beside it was never
touched. Attention had been on the indentation problem in the same task.

Two things worth keeping. First, **newer ansible-core rejects a non-boolean conditional outright**
rather than silently accepting a truthy string — so a bug that ran quietly for weeks is now a hard
error. The toolchain tightening is doing me favours (same story as the `INJECT_FACTS_AS_VARS`
deprecation). Second, and the real lesson: **this bug survived being diagnosed, corrected, and
committed.** Only running it caught that — twice now. Never mark a guard fixed by reading it.

### GitHub Actions had never passed. Not once.

Trimming the workflow revealed the badge was decorative — the run history was red all the way back.
Four separate problems, peeled one at a time:

**1. `cd: terraform: No such file or directory`.** Not a missing directory — a missing
`actions/checkout@v4`. **GitHub Actions does NOT clone your repo.** It hands you a bare runner with
an empty workspace and you ask for the code explicitly. GitLab CI does the opposite: it clones
before every job automatically (which is how pipeline #1 failed *before* its script ran, earlier
the same day). Two CI systems, opposite defaults — easy to carry the assumption across.

*(Also chased a wrong theory here: I suspected `git filter-repo` had stripped `terraform/` from the
GitHub history. `git ls-tree origin/main` disproved it in one command. Cheap test beats confident
inference — again.)*

**2. Terraform isn't on the runner images any more.** Removed after HashiCorp's licence change, so
`terraform fmt` was "command not found". Added `hashicorp/setup-terraform@v3`.

**3. `terraform fmt -check` exit 3** on `family-vms.tf` — genuinely unformatted after yesterday's
DNS edit. `fmt` is the one lint with a **guaranteed safe auto-fix**: purely syntactic, can't change
meaning. Worth running before every commit.

**4. yamllint findings**, now that `.yamllint` is shared and applied repo-wide instead of via an
inline snippet scoped to `ansible/`: four missing final newlines, one trailing space, one comment
missing its space. Added `.editorconfig` to stop them recurring — though note it's read by *editors*
(JetBrains built-in, VS Code needs an extension) and **nano ignores it entirely**, which matters
given how much editing happens over SSH.

**5. shellcheck found a real bug** in `scripts/macbook-backup.sh`:

```bash
tar tzf "$f" >/dev/null && log "OK" || { log "CORRUPT"; exit 1; }
```

`A && B || C` reads like if-then-else but isn't — if `A` succeeds and `B` fails, `C` still runs. So
a failing `log` would report **CORRUPT on a good archive** in the backup *verification* step. Wrong
failure direction for that script. Replaced with a real `if/then/else`. The other finding (SC2034,
unused loop counter) was a convention, not a bug — renamed to `_`.

**The division of labour is now honest:** only the Ansible syntax-check was genuinely duplicated by
GitLab's ansible-lint. `terraform fmt` (formatting, not correctness), repo-wide yamllint (GitLab's
only covers `ansible/`) and shellcheck (nothing else checks shell) are all complementary. Both
systems green.

### Docs caught up with reality
- **ADR-003 amended** — records GitLab as Tailscale-only (it was specified as Tunnel + Cloudflare
  Access and never built), with the lost capability written down: no inbound webhooks. Revisit
  trigger noted (Cloudflare Pages building the portfolio site on commit).
- **Jellyseerr went public** — the third public app, and the first that can *cause internal work*
  (queue downloads) rather than only serve content. It's user-facing by ADR-003's categories, but
  unlike Jellyfin it holds Radarr/Sonarr/Prowlarr API keys, so a compromise is a pivot. Mitigated
  with Jellyfin SSO (one credential store, local sign-up off) and approval-required requests.
- `current-state.md` gained a CI section and the 10-host monitoring line.

**Gotcha while wiring the two push URLs:** `origin` fetches over **SSH**, and adding an **HTTPS**
push URL switched GitHub auth to needing a PAT → `403 Permission denied`. Match the scheme of the
existing fetch URL; mixing them means two auth systems and only one is set up.

### Left open
- Rename `compose_stack`'s interface vars, then drop the `var-naming` skip from `.ansible-lint`.
- A `jellyfin` role; Terraform `proxmox_virtual_environment_container` + `import` for the two LXCs.
- Move Tailscale to its apt repo (retires `curl | sh`).
- Consider extending `.githooks/pre-commit` to catch trailing whitespace / missing final newline —
  works regardless of editor, unlike `.editorconfig`.
- `compose_stack` copies config files but never reloads the containers using them — see the gotcha
  table. Fix: `register:` the copy task, pass `recreate: always` when it changed.
- A `jellyfin` role for the app itself; Terraform `proxmox_virtual_environment_container` +
  `terraform import` for the two LXC definitions.
- Drop the checks now duplicated in `.github/workflows/validate.yml`, and its inline
  `config_data:` now that `.yamllint` is a real file.
- Rename `compose_stack`'s interface vars, then remove the `var-naming` skip.
- Move Tailscale to its apt repo (retires `curl | sh` properly).
- **Pull mirroring is not available on GitLab CE** — the project's Mirroring settings offer *Push*
  only. So "GitHub source, GitLab pull-mirror" (Session 11) is not implementable as written.
  Note that push-mirroring still satisfies ADR-004: GitHub keeps a continuously-updated full copy,
  so the code that rebuilds the homelab never depends on the homelab. Leading option is instead to
  add **two push URLs to `origin`** so one `git push` publishes to both. ⚠️ Adding *any* explicit
  push URL stops git using the fetch URL for pushes — so both must be added, or one silently stops
  receiving commits.

---

## Session 11 — 2026-07-30 · GitLab Runner, a repo audit, and a backup pool that suspended itself

**Goal:** an at-home housekeeping session — clear the docs/commit backlog and reconcile
Terraform drift. The `backup` pool alerted partway through and took over.

**Outcome:** ✅ GitLab Runner deployed + registered (CI is unblocked). ✅ `backup` pool
recovered from `SUSPENDED`. ✅ Repo audit + `current-state.md` rewritten after a week of drift.
⬜ The backup disk still needs a *physical* move off a USB 2.0 hub.

### What I did

1. **GitLab Runner** — deployed as a compose stack on `runner-vm` (.25, vmid 123) with the
   docker executor via `docker.sock`, registered with the `glrt-…` token. Next: a first
   `.gitlab-ci.yml` doing IaC lint.
2. **Repo audit.** Deleted two strays: `leak-test.txt` (a fake Proxmox token I'd used to test
   the pre-commit hook) and `scripts/root@192.168.0.221` — a byte-identical copy of
   `macbook-backup.sh` created by an `scp` typo. **Missing the colon after the host turns
   `scp file root@ip` into a plain local copy named after the host.** Committed as `housekeep`.
3. **Found the remotes had diverged.** `git push` only goes to `origin`, so `gitlab/main` had
   silently fallen a commit behind `origin/main`. Since GitLab is about to run CI, a stale
   mirror means pipelines execute against old code. **Decision: GitHub = source of truth,
   GitLab = pull-mirror** (Settings → Repository → Mirroring). Pull-mirroring also means no
   inbound webhook is needed, so GitLab can stay off the public internet.
4. **`current-state.md` rewritten** — it was dated 07-23 and still claimed G11/MacBook were
   unbuilt and Immich was "waiting on the SSD."
5. **Terraform drift, measured properly** — read `terraform.tfstate` against `family-vms.tf`
   instead of guessing. Only media-vm and monitor-vm have drifted, and it's **two** changes,
   not one: `dns` (empty) *and* `cpu.type` (`qemu64` → `host`). Also confirmed `runner-vm` was
   already in state. Changed `dns.servers` to `["192.168.0.31", "1.1.1.1"]` so AdGuard resolves
   `*.lab` directly instead of relying on the router to forward. **Edited, not yet applied.**

### Errors & fixes 🔥

**`backup` pool `SUSPENDED` — and "the disk just got renamed" was the wrong diagnosis** 🔥

Grafana showed `k8plus / backup = PROBLEM`. The disk had moved `sdc` → `sde`, so I assumed a
naming problem. Wrong twice over:

- **ZFS identifies vdevs by a GUID in the disk label, not by `/dev/sdX`.** A rename alone can
  never fault a pool — that's the whole reason you can move a pool between controllers.
- **A device sitting still never gets renamed.** Kernel names are assigned at enumeration, so
  `sdc` → `sde` means it was *re-enumerated*: it dropped off the bus and came back.

`dmesg -T` settled it — four devices disconnecting in the *same second*:

```
usb 7-1:     USB disconnect, device number 12   ← hub
usb 7-1.3:   USB disconnect, device number 13   ← My Passport (backup pool)
usb 7-1.4:   USB disconnect, device number 14   ← second hub
usb 7-1.4.2: USB disconnect, device number 15   ← PD3.0 device
```

A failing disk drops *itself*. It doesn't take a hub and a power-delivery device with it. The hub
reset; the disk was collateral. Root cause: the backup disk had ended up behind a bus-powered
**USB 2.0** hub.

> **The rename is the fingerprint of the drop, not the cause of the fault.**

---

**The vdev path had silently changed `ata-…` → `usb-…`**

The pool recorded `ata-WDC_WD10SDZM-…`, but the only by-id link that existed was
`usb-WD_My_Passport_2606_…`. Same disk — decode the hex and the serial matches.

An `ata-*` name only appears when the kernel can do ATA passthrough, which needs **UAS over
USB 3**. Behind a USB 2.0 hub it falls back to plain `usb-storage` and gets a generic name.

> **That path change is a link-speed regression, not a cosmetic one.** Confirm in `dmesg`:
> `super-speed` + `uas` = USB 3; `high-speed` + `usb-storage` = USB 2.0 (~40 MB/s ceiling).

---

**`SUSPENDED` is a brake, not damage**

Counters read `READ 3, WRITE 0, CKSUM 0`. Zero checksum errors means ZFS never received data that
failed verification — nothing was corrupted.

The default `failmode=wait` freezes all pool I/O rather than returning errors to applications, and
it does **not** self-recover when the device comes back. It needs an explicit `zpool clear backup`.

Still to do (physical): export → move to a **direct** port on k8plus → `import -d /dev/disk/by-id`
→ verify `dmesg` says `super-speed` → `usbcore.autosuspend=-1` on the cmdline → reboot → scrub →
re-enable PBS.

---

**Terraform's `~ update in-place` says nothing about guest downtime**

The plan for `cpu.type: qemu64 → host` renders as an in-place update, which reads as harmless.

It isn't. *In-place* only means the **resource** isn't destroyed and recreated. QEMU builds the
virtual CPU when the VM process starts, so the model can't change on a running guest — the provider
must stop and start it. `reboot_after_update = false` doesn't make it hot-applicable.

Matters here because monitor-vm runs AdGuard, so power-cycling it drops LAN DNS for the house.

> **Ask "can the hypervisor actually change this on a live VM?" before trusting the plan verb.**

---

**cloud-init DNS is first-boot only**

Changing `dns {}` in Terraform rewrites the cloud-init drive but does nothing to a VM that has
already booted. `runner-vm` needs the live fix via netplan / `resolvectl`.

Same class as the 07-25 "static IP but no DNS" incident.

---

**Jellyfin playback failed after the same disk shuffle — and again my first guess was wrong**

The 2 TB media disk moved `sda` → `sdc`, so I suspected a `/dev/sdX` entry in fstab. It wasn't —
that mount has been `UUID=621B-F154` since Session 3.

The real cause: **`nofail` means "don't block boot if this is missing", not "mount it when it turns
up."** There's no hotplug trigger. The disk came back under a new letter, nothing re-ran the mount,
and `/mnt/media` sat there as an empty directory.

Jellyfin still *listed* every film — the metadata lives in its own database. Only pressing play
failed.

> **Library fine + playback dead is the signature of a missing mount, not a broken Jellyfin.**

Two commands, no file edits:

```bash
mount -a          # UUID finds the disk at whatever letter it now has
pct restart 200   # container must re-resolve its bind mount
```

The restart isn't optional — **an LXC bind mount is resolved once, at container start.** Mounting a
filesystem under that path afterwards doesn't propagate into the container's namespace, so the host
looks fixed while the container still sees an empty folder.

---

**Two things I noticed while chasing that**

**Jellyfin is the only service here not managed as code.** CT 200 was built by hand, its accounts
live in its own SQLite DB, and none of it is in Ansible or Vault. If that container is lost, PBS is
the entire recovery plan. Worth a role, or at minimum a runbook.

**exFAT has no Unix permission model.** The `uid=1000,gid=1000,umask=002` mount options *are* the
access control — they must survive any future fstab edit.

### IaC added / changed
- `docs/current-state.md` — rewritten for 2026-07-30.
- `terraform/proxmox/family-vms.tf` — `dns.servers` → `["192.168.0.31", "1.1.1.1"]` (**not applied**).
- Removed `leak-test.txt` and `scripts/root@192.168.0.221`.
- ⚠️ **ADR-003 is now stale** — it records GitLab as "Tunnel + Cloudflare Access," but GitLab
  has been Tailscale-only since split-DNS solved remote access in Session 10. Needs updating,
  with the lost capability (inbound webhooks) written down as the trigger to revisit.

---

## Session 10 — 2026-07-29 · Alert email, a qBittorrent self-heal watchdog, remote GitLab

**Goal:** A work-day session (remote over Tailscale), so remote-safe jobs only — finish
alert email, automate the qBittorrent-dies-daily chore, and get GitLab reachable remotely.

**Outcome:** ✅ Grafana alert email live (Proton SMTP). ✅ A `qbittorrent_watchdog` role that
self-heals qbit when gluetun's tunnel goes stale. ✅ Remote `*.lab` access via Tailscale
split-DNS (GitLab included). Runner token in hand for the next session's first CI pipeline.

### What I did
1. **Alert email** — enabled Grafana SMTP (`GF_SMTP_*`) via a **Proton Business SMTP token**
   (`smtp.protonmail.ch:587`), token in vault. Test mail delivered.
2. **qBittorrent watchdog** (`qbittorrent_watchdog` role, media-vm) — a systemd **timer** (every
   3 min) runs a script that curls qbit's `/api/v2/transfer/info`; if DHT collapses to 0 /
   disconnected for **2 checks running**, it runs `docker compose restart gluetun qbittorrent`.
   Modelled on `nic_watchdog`, but time-triggered (timer) instead of boot-triggered.
3. **Remote GitLab** — `git.lab` is LAN-only DNS, so it was unreachable off-LAN. Fixed with
   **Tailscale split-DNS** (nameserver = AdGuard `192.168.0.31`, restricted to domain `lab`) +
   "Use Tailscale DNS" on the laptop. All `*.lab` now resolve remotely.

### Errors & fixes 🔥
**qbit Web API returns `Forbidden`.** qbit is inside gluetun's netns, so a `localhost` request
is NAT'd and arrives from a Docker IP (`172.18.0.1`), not `127.0.0.1` — the "bypass auth for
localhost" toggle never triggers. Fix: whitelist `172.16.0.0/12` in qbit's "Bypass auth for
whitelisted IP subnets."

**`systemctl start` as the `ubuntu` user → polkit auth failure.** The cloud-init user has no
password, so systemd's polkit prompt can't be answered. Fix: `sudo systemctl …` (the role is
fine — it runs as root). Rule: anything that *changes* systemd state needs sudo.

**Remote `git.lab` = "Non-existent domain".** The laptop's DNS was the corporate resolver
(`10.255.255.1`), not Tailscale's `100.100.100.100`, so split-DNS wasn't applied. Fix: turn on
"Use Tailscale DNS settings." Note: `nslookup` ignores the hosts file, so if you fall back to a
hosts entry, test with `ping`, not `nslookup`.

**IaC added:** `qbittorrent_watchdog` role + a media-vm play in `site.yml`; `GF_SMTP_*` in the
monitoring compose + `SMTP_*` in `host_vars/monitor-vm.yml` (+ `vault_smtp_password`).

---

## Session 9 — 2026-07-28 · Immich on a new SSD pool (+ a CPU-flags gotcha)

**Goal:** Get the family photo library online. Turn the spare 1 TB M.2 SSD in k8plus into a
ZFS pool, hand family-vm a disk from it, and deploy **Immich** (a Google-Photos replacement) —
then expose it publicly so the family can back up phones.

**Outcome:** ✅ `data` ZFS pool live (single NVMe, ~922 GB), family-vm has an 800 GB
SSD-backed disk at `/mnt/immich`, and Immich is up (server + Postgres + Redis + ML). One
genuinely interesting gotcha: the ML container crash-looped on a **NumPy CPU-instruction
error** until I passed the host CPU into the VM. Kept Immich **Tailscale-only** (no public
exposure) — family photos are more sensitive than the media catalogue, and Tailscale also
sidesteps Cloudflare's 100 MB upload cap.

### What I did
1. **Identified the disk safely.** `lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL` + `zpool status`
   + `ls /dev/disk/by-id/`. k8plus has three ~1 TB devices (two USB My Passports + the rpool
   NVMe), so the whole game was picking the *right* one — the KIOXIA NVMe that belonged to no
   pool. **Always build pools on `/dev/disk/by-id/…`, never `/dev/sdX`** (the letters reshuffle
   across reboots; a by-id name is welded to the drive).
2. **Created the pool.** `sgdisk --zap-all` + `wipefs -a` to clear the old exfat/NTFS junk,
   then:
   ```bash
   zpool create -f -o ashift=12 \
     -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
     data /dev/disk/by-id/nvme-KBG60ZNS1T02_KIOXIA_…
   zfs create data/immich
   pvesm add zfspool data --pool data --content images,rootdir --sparse 1
   ```
   (`ashift=12` = 4K sectors for the SSD; `lz4` = free speed; `xattr=sa`+`acltype=posixacl`
   are what container file stores want; `atime=off` skips a write on every read.)
3. **Gave family-vm an SSD disk as code.** A `dynamic "disk"` block in Terraform keyed off a
   new `data_disk` field, so *only* family-vm gets a second 800 GB disk (`scsi1`) on the
   `data` pool; also bumped its RAM to 12 GB for the ML load. **Targeted** apply
   (`-target='…family["family-vm"]'`) so I didn't drag in the K3s tier or the `dns{}` drift.
   Inside the VM: `mkfs.ext4 -L immich`, an `fstab` line with `nofail`, mounted at `/mnt/immich`.
4. **Deployed Immich** through the existing `family` compose stack — but fixed the env first:
   it was missing `DB_HOSTNAME` / `REDIS_HOSTNAME` (Immich can't find its own DB/Redis without
   them) and I repointed `UPLOAD_LOCATION` from the exfat media drive to `/mnt/immich`.
5. **Access = Tailscale-only.** Briefly wired a Cloudflare hostname, then decided against it:
   the photo library is more sensitive than media and has no reason to be public. Closed the
   Cloudflare hostname/Access → Immich is now reachable **only over the tailnet**. Put Tailscale
   on family-vm via the `tailscale` role (identity-only) and pointed the Immich app at the VM's
   tailnet IP `http://100.x.y.z:2283`. Every viewer/uploader must be on the tailnet — private,
   and no 100 MB body cap. Updated **ADR-003** to move Immich from public → Tailscale-only.

### Errors & fixes 🔥
**Immich ML crash-loops with `NumPy was built with baseline optimizations (X86_V2) but your
machine doesn't support (X86_V2)`.** The `immich-server` was healthy but
`immich-machine-learning` restarted every ~5 s (exit 1). Root cause: **Proxmox's default VM
CPU model is `kvm64`**, a minimal baseline that predates x86-64-v2, so the guest didn't
advertise SSE4.2/POPCNT/etc. Immich's ML image ships a NumPy compiled for the **v2** baseline,
so it aborts the instant it `import numpy`. Fix: `cpu { type = "host" }` in Terraform → the VM
inherits the real Ryzen flags → ML boots clean. CPU model isn't hot-pluggable, so it's a
cold-boot change (brief family-vm restart).

**Tailscale role ran clean but `tailscale ip -4` said `NeedsLogin`.** The join task was
guarded with `creates: /var/lib/tailscale/tailscaled.state`, but `tailscaled` writes that
file the moment the daemon *starts* — before any login — so Ansible skipped the actual
`tailscale up`. Fixed the role to guard on `tailscale status --json` backend state instead;
recovered the running VM with a manual `tailscale up --ssh --accept-routes=false
--accept-dns=false`.

### 🎓 The thing I actually learned: x86-64 microarchitecture levels & VM CPU models
CPUs have piled on instruction sets for 20 years (SSE → SSE2 → SSE4.2 → AVX → AVX2 → AVX-512…).
Rather than have software probe for each one, the industry defined **tiers** you can target:

| Level | ~Era | Adds (roughly) | What gives it to you |
|---|---|---|---|
| `x86-64-v1` | 2003 | SSE2 (the original 64-bit baseline) | `kvm64` / `qemu64` (Proxmox default) |
| `x86-64-v2` | 2009 | **SSE4.2, POPCNT, CMPXCHG16B** | most real CPUs; NumPy targeted this |
| `x86-64-v3` | 2013 | AVX, AVX2, BMI1/2, FMA | modern desktops/servers |
| `x86-64-v4` | — | AVX-512 | newer Xeon/EPYC (and some Ryzen) |

Libraries increasingly build for **v2/v3** to run faster and drop ancient-CPU support — which
is exactly why a modern NumPy refuses to load on a CPU that only claims **v1**.

A Proxmox VM does **not** automatically see the physical CPU. QEMU hands the guest a *virtual*
CPU model, and you choose the tradeoff:
- **`kvm64` / `qemu64`** — safe lowest-common-denominator (v1). Maximum compatibility (any VM
  runs on any host), but modern v2/v3 software breaks. *This was my problem.*
- **`host`** — passes the physical CPU straight through. Fastest, every flag available. The
  catch: you can only **live-migrate** to an *identical* CPU (a VM that booted with AVX2 can't
  move to a host that lacks it). I don't do HA/live-migration, so `host` is the correct choice.
- **Named models** (`x86-64-v2-AES`, `x86-64-v3`, `EPYC-…`) — the middle ground: guarantee a
  tier of flags while staying migratable across any host that supports that tier.

**Rule of thumb:** single-host homelab VM → use `host`. Cluster you migrate across mixed CPUs →
pick the highest **named** model *all* your hosts share.

**Why only ML broke:** the Immich server (Node/TypeScript) and Postgres/Redis never touch that
NumPy build path. The Python ML worker `import numpy`s at startup, so it's the canary that
sniffs out missing CPU flags first.

### 🎓 Storage & exposure notes (for future-me)
- **Single-disk pool = no redundancy.** Acceptable *because* the phone originals + PBS are the
  safety net — but real photos landing here bumps **off-site backup** up the priority list.
- **ext4-on-a-zvol** looks like double bookkeeping, but the pool's checksums/compression still
  apply underneath; it keeps family-vm's disk model identical to every other VM (clean IaC)
  instead of a one-off virtiofs share.
- **Cloudflare's proxy caps request bodies at 100 MB** (Free/Pro). Photos sail through, but a
  >100 MB phone **video** would fail to upload through the tunnel. This — plus the privacy of
  family photos — is why Immich ended up **Tailscale-only** rather than public. (Good gotcha to
  remember for *any* service that takes large uploads behind a Cloudflare Tunnel.)

**IaC touched:** `terraform/proxmox/family-vms.tf` (`data_disk` dynamic disk + `cpu type=host`
+ 12 GB on family-vm), `host_vars/family-vm.yml` (`UPLOAD_LOCATION=/mnt/immich` +
`DB_HOSTNAME`/`REDIS_HOSTNAME`), `compose/family/.env.example`.

---

## Session 8 — 2026-07-25/26 · G11 core-infra complete + managed switch in

**Goal:** Recover from the failing backup disk, harden the fixes in code, then finish
G11 as the core-infra node (DNS, reverse proxy, logs, GitLab). The MikroTik switch,
a spare SSD, 2.5G adapters, and a JetKVM all landed too.

**Outcome:** ✅ **G11 core-infra is done** — AdGuard DNS, Nginx Proxy Manager (`*.lab`
hostnames), Loki + Promtail logs with a provisioned dashboard, and **GitLab CE** on its
own VM. Backup disk recovered (pool ONLINE, scrub clean). MikroTik CRS310 in as a flat
managed switch (VLAN work is Phase 1, next). JetKVM gives out-of-band console to k8plus.

### What I did
1. **Backup disk recovery:** reconnected the WD My Passport to the front USB-C port →
   `zpool clear/import backup` → **ONLINE, scrub 0 errors** → re-enabled backups.
2. **Hardened the fixes in code:** `nic_tuning` role (disable EEE on igc NICs), `tailscale`
   role now `--accept-routes=false --accept-dns=false`, `disk_health` role (ZFS+SMART →
   Prometheus) with panels + in-Grafana alerts, and the `docker` role now sets a DNS
   resolver + waits for cloud-init before apt.
3. **G11 core-infra (all via `compose_stack` + per-stack tags):**
   - **AdGuard Home** (DNS + ad-blocking) → set the router's DHCP DNS to it.
   - **Nginx Proxy Manager** → `*.lab` internal hostnames (AdGuard rewrite `*.lab` → NPM → service).
   - **Loki + Promtail** (logs) + a provisioned Logs dashboard (host/container/search filters).
   - **GitLab CE** on a new `gitlab-vm` (.32); reached at `git.lab`, git-SSH on :2224.
4. **Managed switch (Phase 0):** MikroTik **CRS310-8G+2S+** (RouterOS) in place, flat
   `192.168.0.x` working, mgmt IP `192.168.0.2` added. **JetKVM** (ether8→k8plus) working
   as out-of-band console. Incremental VLAN plan chosen (keep infra on the flat net; add
   VLAN 40 IoT / 20 Lab as new zones).

### Errors & fixes 🔥
**VM shuts itself down under load = host OOM.** gitlab-vm kept dying → g11's BIOS had
**UMA Frame Buffer = 4G**, so only 11GB of 16 was usable → VMs overcommitted → OOM-killed
the VM. Fix: BIOS → GFX → **UMA Frame Buffer → 256M** → ~15GB usable. (PVE9 already caps
ZFS ARC at ~10% — ARC was NOT the culprit; always check `free` vs installed RAM.)

**Fresh cloud-init VM: apt lock race** (`Unable to acquire the dpkg frontend lock`) —
cloud-init runs apt on first boot. Fixed in the `docker` role with `cloud-init status --wait`.

**DNS broke on family-vm again** (cloud-init sets no DNS) → codified a systemd-resolved
resolver into the `docker` role so every VM gets one.

**Grafana Loki dashboard "parse error"** — Loki rejects a query where all matchers are
empty-compatible (`.*`). Fix: anchor with `job="docker"` + set the "All" value to `.+`.

**Intel i226 NIC link-flap** ("Link Up 2500 → Down" loop) took k8plus offline → `ethtool
--set-eee <iface> eee off` (now the `nic_tuning` role).

**Winbox "connection timed out"** on the new switch — default IP is 192.168.88.1, client
was on .0.x. Fix: connect **by MAC** via Winbox → Neighbors (works at L2 regardless of subnet).

**JetKVM: see the screen but can't type** — USB HID was fine (dmesg showed the emulated
keyboard); the web console just needed a **click to focus** before it captures keystrokes.

### Next session
- **VLAN Phase 1 (VLAN 40 IoT/Guest)** — enable bridge `vlan-filtering` CAREFULLY (mgmt VLAN
  first or lockout; Winbox-by-MAC + JetKVM are the lifelines). Write ADR-006 first.
- Then VLAN 20 (Lab) with the K3s tier, and VLAN 30 (mgmt/cluster) on the second NICs.
- 1TB SSD (now in k8plus) → `data` ZFS pool → Immich.

---

## Session 7 — 2026-07-24 · Monitoring, notes backend, and a very long firefight

**Goal:** Stand up centralized monitoring + a self-hosted notes backend as code. Ended
up root-causing a failing disk and a self-inflicted network lockout along the way.

**Outcome:** ✅ Prometheus + Grafana live on a new VM on G11 (fleet dashboard working),
uptime-kuma watching every service, CouchDB running for Obsidian LiveSync. Also found and
contained a **failing USB backup disk** and recovered from a **Tailscale routing lockout**.
A brutal but hugely instructive session.

### What I did
1. **Monitoring (core-infra on g11):** Terraformed `monitor-vm` (192.168.0.31) — a
   cross-node clone (template lives on k8plus). Bootstrapped it as a docker host, then
   deployed **Prometheus + Grafana + uptime-kuma** via `compose_stack`. Prometheus scrapes
   node_exporter on all 6 hosts; Grafana datasource + a Fleet Overview dashboard are
   provisioned from git.
2. **Notes backend:** deployed **CouchDB** on family-vm (so it rides the PBS backups) for
   the Obsidian **Self-hosted LiveSync** plugin. Configured it via a post-boot HTTP-API
   script (mounting a config file crashed it — see below).
3. **IaC hardening:** extended `compose_stack` to copy a whole stack folder (config +
   provisioning, not just the compose file); added a `disk_health` role (ZFS pool + SMART
   → node_exporter textfile); changed the `tailscale` role to `--accept-routes=false`.

### Errors & fixes 🔥
**Terraform wanted to DESTROY family-vm + media-vm** — a change to the `clone { full }`
flag forces VM replacement. Caught it in `terraform plan` (`2 to destroy`). Fixed to
`full = true` (the provider default the VMs were built with) so existing VMs show no diff.
**Lesson: always read the plan; `-target` the new resource; never blind-`apply`.**

**Grafana crash-looped** — `datasource provisioning error: Only one datasource per
organization can be marked as default`. The scaffold shipped a datasource file AND I added
one, both `isDefault: true`. Emptied the scaffold one.

**CouchDB exited code 1 with ZERO logs** — mounting a `local.d/*.ini` config file crashes
CouchDB 3.5.2 before it can even log. Proved it: boots fine without the mount. Fix: boot
clean, apply the LiveSync settings **after startup via the `_config` HTTP API**
(`setup-couchdb.sh`) — which is the method the LiveSync docs recommend anyway.

**PBS backups kept failing → traced to a dying disk** 🔥🔥🔥 The whole chain, in order:
- Backup failed with `unable to acquire backup group lock`.
- Found a **zombie `proxmox-backup` process** (`Zsl <defunct>`) stuck since a prior day.
- It was **unreapable** — a sibling thread wedged in uninterruptible kernel I/O (`D` state);
  SIGKILL can't touch it (`SubState=stop-sigkill`, `MainPID=0`). Only a **reboot** clears it.
- After reboot, backup *still* failed: `http upgrade request timed out`.
- `zpool status` → the **`backup` pool was SUSPENDED**: the 1TB WD **USB** disk (`sdb`)
  threw READ/WRITE errors and **dropped off the bus** (`DID_ERROR`, `device offline`,
  gone from `lsblk`). Root cause of *everything* since the first hang.
- Both HDDs are **bus-powered USB** on a mini PC → the drive browns out / drops under load.
  Fix (physical, pending): powered enclosure / new cable / different port, then `zpool clear`
  + `scrub`. Backup job **disabled** meanwhile so it can't re-wedge the node.

**Rebooting k8plus blinded me to g11 + macbook** — the only Tailscale **subnet router** ran
on k8plus. From remote (work), losing it withdrew the `192.168.0.0/24` route → no path to
*any* node. The cluster was perfectly quorate the whole time (corosync log proved it); I'd
just lost the tunnel. Fix: Tailscale on all nodes, each with its own IP.

**Then `--accept-routes` on the nodes locked them out** — a node accepting a route for the
`/24` it already lives on reroutes its own LAN + corosync through the tunnel. Recovered via
the **Proxmox web console over each node's Tailscale IP** (password auth, no SSH key), then
`tailscale set --accept-routes=false`. **Rule: nodes never accept routes; only clients do.**

### Next session
- **Physical:** fix the backup disk (powered enclosure), `zpool clear` + scrub, re-enable backups.
- Apply the `disk_health` + `tailscale` role changes (targeted run, skip the firewall role).
- Finish Obsidian on the phone (Tailscale + LiveSync Setup URI).
- VLAN migration when the MikroTik lands; then the K3s lab tier.

---

## Session 6 — 2026-07-24 · The 3-node cluster is real

**Goal:** Build the last two nodes (G11 and the MacBook) and stop running one lonely
server — turn it into a proper 3-node Proxmox cluster with real quorum.

**Outcome:** 🎉 Done. All three machines are installed, bootstrapped from the repo, and
joined into one cluster that survives losing any single node. The flaky MacBook now heals
its own network on boot, and its screen sleeps so I don't burn the panel. This is the
milestone the whole design was pointing at.

### Why I did the MacBook now instead of a QDevice
I wanted G11 in the cluster, but a **2-node cluster is quorum-fragile**: quorum needs a
majority, so with two nodes that's 2-of-2 — if *either* node drops, the survivor can't
start or change guests. That's dangerous for k8plus, which runs the family stuff.

The "proper" fix for two nodes is a **QDevice** (a tiny third vote on some always-on box).
But I don't have a spare always-on machine — so instead of scaffolding a QDevice I'd just
rip out later, I built the **MacBook as the real third node** tonight.

**How the votes play out with 3 nodes:** 3 votes total, quorum = 2. The cluster stays
fully functional as long as **any 2 of 3** are up. So my disposable, flaky MacBook can
come and go freely — losing it still leaves k8plus + g11 = 2 votes = quorate. Exactly the
ADR-001 design: the unreliable machine can only ever take down disposable workloads.

### What I did
1. **G11:** installed Proxmox VE 9 (ZFS), static `192.168.0.12`, hostname `g11`. Ticked
   **vmbr0 → VLAN aware** (so the future MikroTik VLAN migration is just NIC tagging, no
   bridge surgery). Then from the Z13 control node:
   ```bash
   ssh-keygen -R 192.168.0.12 && ssh-copy-id root@192.168.0.12
   cd ~/homelab-infra/ansible
   ansible-playbook bootstrap.yml --limit g11
   ```
2. **Formed the cluster** on k8plus and joined g11:
   ```bash
   # k8plus (safe — running guests untouched):
   pvecm create homelab
   # g11 (must be empty, which it was):
   pvecm add 192.168.0.11
   pvecm status        # Nodes: 2, quorate
   ```
3. **MacBook:** wiped it (no data to keep). It's a 2019 MBP with a **T2 chip**, so it
   needed a pre-flight or it wouldn't even boot the USB (see below). Installed Proxmox VE 9
   (ZFS), static `192.168.0.13`, hostname `macbook`, vmbr0 VLAN-aware.
4. **Bootstrapped + joined** the MacBook as node 3:
   ```bash
   ssh-keygen -R 192.168.0.13 && ssh-copy-id root@192.168.0.13
   ansible-playbook bootstrap.yml --limit macbook   # includes nic_watchdog + console_blank
   ssh root@192.168.0.13 'pvecm add 192.168.0.11'
   pvecm status        # Nodes: 3, Expected votes: 3, Quorate: Yes ✅
   ```
5. **Reboot test:** rebooted the MacBook and confirmed it came back on the network **by
   itself** (`ansible macbook -m ping` → pong, no manual adapter poking), and the screen
   went dark on its own. Hands-off. That's the win.

### Errors & fixes 🔥
**T2 Mac won't boot the USB installer** — the T2 security chip blocks external boot by
default. Fix, in macOS Recovery (Cmd-R) → **Startup Security Utility**: set **Secure Boot
→ No Security** and **Allow booting from external media**. Then boot holding **Option**
and pick the USB.

**`applesmc ... probe with driver applesmc failed with error -5`** at the login prompt —
**harmless**, expected on every T2 Mac. `applesmc` is the old fan/temp-sensor driver; the
SMC sits behind the T2, so it can't probe it. Doesn't affect networking, storage, or
clustering — the T2 firmware manages the fans itself. Cosmetic log noise, ignore it.

**MacBook unreachable after install — vmbr0 had no IP** 🔥🔥 This is *the* MacBook quirk,
the reason it's the disposable node. Its ethernet is a **USB Realtek adapter (`r8152`,
named `nic0`)** that **enumerates late** — so at boot Proxmox brings up `vmbr0` before the
adapter exists, the bridge comes up with no working port, and the node is dead on the
network. Diagnosed at the console:
```bash
ip -br a          # vmbr0 missing / no address
ip -br link       # nic0 = DOWN
```
Manual recovery:
```bash
ip link set nic0 up          # → "r8152 ... nic0: carrier on"
systemctl restart networking # rebuilds vmbr0 with 192.168.0.13
ping -c2 192.168.0.1         # replies → back online
```
(`ifreload -a` kept failing with "another instance already running" — a stale lock;
`systemctl restart networking` is the reliable hammer.)

**Permanent fix — the `nic_watchdog` role was a broken stub.** It had a hardcoded
`enp3s0` and reloaded `bcm5974` (the *trackpad* driver!). Rewrote `nic-fix.sh` to (a) find
the NIC by its `r8152` driver so a USB rename won't break it, and (b) heal the **bridge** —
it checks that `vmbr0` has an IP and restarts networking if not, which is what actually
failed. It's a no-op on a healthy boot. Also fixed the systemd unit:
`After=networking.service` instead of `network-online.target` (which can hang forever when
the link never comes up). And it wasn't even running — `nic_watchdog` was only in
`site.yml`, but `bootstrap.yml` is the safe baseline, so I added a lab-scoped play to
bootstrap.

### New this session
- **`console_blank` role** — sets `consoleblank=60` on the kernel cmdline so the MacBook's
  internal panel backlight sleeps after 60s (machine stays fully powered — just the screen
  rests, no burn-in). Persists via `proxmox-boot-tool`, and blanks the live console
  immediately so I saw it work without a reboot.
- **VLAN-aware bridges** on all three nodes now, ready for the MikroTik.

### Next session
- Stand up **centralized monitoring** (Prometheus + Grafana) — node_exporter is already on
  every host, so it just needs a scrape target + dashboards. First service to land on G11.
- When the **MikroTik managed switch** arrives: VLAN segmentation (ADR-005) — tag each
  guest's NIC, firewall the zones. Keep guests on the same IPs so the tunnel/Tailscale
  survive the cutover.
- Then the fun part: **K3s on the MacBook** → ArgoCD → first commit-to-deploy pipeline.

---

## Session 5 — 2026-07-23 · Nextcloud on IaC, portfolio polish, FlareSolverr

**Goal:** Retire the hand-deployed Nextcloud and bring it under Ansible; sharpen the
public-facing portfolio; and wire up FlareSolverr for Cloudflare-protected indexers.

**Outcome:** ✅ Nextcloud is now Ansible + Vault managed (redeployed as a clean install —
no data existed yet, so no migration risk). README + docs + blog posts brought in line
with what's actually built. FlareSolverr configured so I can add indexers that sit behind
Cloudflare.

### Key decisions
- **Nextcloud = fresh install.** No family data on it yet, so I skipped the careful "match
  the old DB password / reuse volumes" dance — just wiped the manual deploy and let Ansible
  build it clean. The vault `vault_nextcloud_db_password` can be any value.
- **MacBook lab node = clean wipe.** Nothing to preserve on it either, which killed the
  whole "back up the old VM first" problem (I'd forgotten its password anyway — see the
  migration write-up). Turns out the best backup is realising you don't need one.

### What I did
1. **Ansible Nextcloud redeploy:**
   - Gave the `compose_stack` role a `stack_services` filter so I can deploy just part of a
     compose file (`[nextcloud, nextcloud-db]` now; Immich waits for the SSD):
     ```yaml
     services: "{{ stack_services | default(omit) }}"
     ```
   - `host_vars/family-vm.yml`: `stack_name: family`, `stack_services: [nextcloud,
     nextcloud-db]`, `stack_dir: /home/ubuntu/stacks`.
   - Wiped the old manual stack and redeployed as code:
     ```bash
     ssh ubuntu@192.168.0.21 'cd ~/stacks/family && docker compose down -v'
     cd ~/homelab-infra/ansible
     ansible-playbook deploy-stacks.yml --limit family-vm --ask-vault-pass
     ```
   - Ran the first-run wizard, created admin. Plaintext `.env` retired — it's generated
     from vault on every deploy now.
2. **FlareSolverr:** it was already in the media compose; the work was wiring it in
   Prowlarr → Settings → Indexers → add **FlareSolverr proxy** at `http://flaresolverr:8191`
   with a `flaresolverr` tag, then tagging the Cloudflare-protected indexers so only they
   route through it. (FlareSolverr uses the VM's normal network, not the VPN — but that's
   just *search* queries; the actual download still goes qBittorrent → Gluetun → VPN.)
3. **Portfolio polish:** README rewritten with an honest 🟢/🟡/⚪ build-status legend (an
   in-progress build reads as more credible than pretending everything's done), fixed real
   inaccuracies (Proxmox VE 8→9, "SOPS+age" → the Ansible Vault I actually use), redrew the
   architecture diagram, refreshed `current-state.md`, de-drafted the blog posts.

### Next session
- Build G11 + the MacBook and form the cluster (→ Session 6).

---

## Session 4 — 2026-07-22/23 · Media automation, end to end

**Goal:** Get the whole media pipeline working — Jellyseerr → Radarr/Sonarr → qBittorrent
through the VPN → library → Jellyfin — deployed as code.

**Outcome:** ✅ Full pipeline live. Switched VPN from ProtonVPN free (blocks P2P) to
**Windscribe (paid)**, deployed the stack via **Ansible + Vault**, and got a real download
flowing through the kill-switched VPN into the library and onto Jellyfin.

### What I did
- Kept **Windscribe** (Mullvad dropped port forwarding in 2023; Windscribe does P2P + port
  forwarding + Gluetun — no reason to switch). Reconfigured gluetun for it; secrets
  (private + preshared key) in ansible-vault, region + address in host_vars.
- Redeployed: `ansible-playbook deploy-stacks.yml --limit media-vm --ask-vault-pass`.
- Configured the apps:
  - **qBittorrent** (:8080 via gluetun): password, save path `/media/downloads`.
  - **Radarr/Sonarr**: root folders `/media/Movies`, `/media/TV Show`; download client
    **host = `gluetun`, port 8080** (qbit shares gluetun's netns — NOT `qbittorrent`).
  - **Prowlarr** (:9696): indexers + apps via API keys. **Jellyseerr** (:5055): linked to
    Jellyfin + Radarr/Sonarr.
- Set **Radarr min seeders = 5** and qBit seeding limits (ratio 2.0 / 7 days → remove
  torrent + files) so dead torrents are skipped and the duplicate copy auto-cleans (exFAT
  has no hardlinks).

### Errors & fixes 🔥
**gluetun crash-loop: "the region specified is not valid ... hong kong - phooey"** — I
used Windscribe's UI label. Gluetun wants its *own* exact region string. Fix:
`vpn_region: "Hong Kong"` from Gluetun's printed list.

**Torrents stuck at "Downloading metadata", DHT: 0 nodes** 🔥🔥 — the **Windscribe Hong
Kong server blocks P2P**: VPN connects, web traffic works, but all peer/DHT traffic is
dead. Not a dead torrent (two different ones failed identically). Fix: switch region:
```bash
sed -i 's/^vpn_region:.*/vpn_region: "Netherlands"/' ansible/inventory/host_vars/media-vm.yml
ansible-playbook deploy-stacks.yml --limit media-vm --ask-vault-pass
```
DHT nodes immediately climbed → download started. **Lesson: pick a P2P-allowed server.**

**docker.sock permission denied on media-vm** — user wasn't in the docker group (role
timing). `sudo usermod -aG docker ubuntu && newgrp docker` (role has the task for rebuilds).

---

## Session 3 — 2026-07-21/22 · Media platform, Cloudflare consolidation, IaC deploys

**Goal:** Move the media disk to the K8 Plus, bring up Jellyfin with hardware transcoding,
back everything up, consolidate Cloudflare onto the new infra, and deploy the media stack
as code.

**Outcome:** Family media platform fully live on the new node (Jellyfin + HW transcode,
zero-downtime cutover). PBS nightly backups running. Cloudflare tunnel migrated off the
MacBook to its own LXC; admin is Tailscale-only; public surface trimmed to Jellyfin +
Nextcloud. Media stack deployed via **Ansible + Vault**.

### What I did
1. **Media disk move (exFAT):** moved 2×WD HDDs to K8 Plus. sda1 = 2TB exFAT "JC-Media"
   (~890 GB of Movies/TV), sdb1 = 1TB (→ ZFS backup pool).
   ```bash
   apt-get install -y exfatprogs
   echo 'UUID=621B-F154 /mnt/media exfat defaults,nofail,uid=1000,gid=1000,umask=002 0 0' >> /etc/fstab
   ```
2. **Jellyfin LXC + iGPU passthrough** (CT 200, Debian 12, bind-mount `/mnt/media`):
   ```bash
   pct set 200 -dev0 /dev/dri/renderD128,gid=104   # gid must match container's render group
   pct set 200 -dev1 /dev/dri/card0,gid=44
   ```
   `vainfo` confirmed H264/HEVC/VP9/AV1 decode + HW encode on the Radeon 780M. Cutover:
   repointed the Cloudflare tunnel to `192.168.0.23:8096` — family kept the same URL, zero
   downtime.
3. **Backups — ZFS pool + PBS** on the 1TB disk; nightly backups of all guests.
4. **Cloudflare consolidation:** new `lxc-tunnel` (cloudflared in CT 201), only `jellyfin`
   + `nextcloud` hostnames kept; deleted the old MacBook tunnel + all the admin DNS records
   (proxmox/grafana/jenkins/git/npm). Public surface = 2 services. (ADR-003.)
5. **Tailscale** subnet router (`--advertise-routes=192.168.0.0/24 --accept-routes`) — so
   dropping the public admin hostnames cost nothing.
6. **Media share (Samba/CIFS):** NFS failed (exFAT can't be NFS-exported), so Samba.
7. **IaC — Ansible + Vault:** new `compose_stack` role renders `.env` from vaulted vars and
   runs the stack; `deploy-stacks.yml` maps hosts → stacks. Secrets safe to commit.

### Errors & fixes 🔥
**exFAT can't be NFS-exported** → use **Samba/CIFS**.
**CIFS `mount error(13)`** → Samba password mismatch; test with `smbclient //host/media -U user` first.
**PBS enterprise repo 401** (blocked apt) → `rm /etc/apt/sources.list.d/pbs-enterprise.sources`. Both PVE *and* PBS ship an enterprise repo.
**Jellyfin LXC no GPU** → render group GID mismatch (device gid 993 vs container's 104). Fix: `pct set 200 -dev0 /dev/dri/renderD128,gid=104`.
**Cloudflare 525** on a hostname → stale DNS record from the old tunnel; delete + re-add on the new tunnel.
**Nextcloud "untrusted domain"** through the proxy:
```bash
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=nextcloud.your-domain.example
docker compose exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value=https
```
**gluetun unhealthy, all traffic times out** → **ProtonVPN free blocks P2P** (port
forwarding is paid-only). Not a bug — free tier can't torrent. ✅ Kill-switch validated:
VPN down = qBittorrent had NO network. No leak possible.

---

## Session 2 — 2026-07-21 · VMs as code + first service live

**Goal:** Reinstall k8plus on ZFS, then Terraform the family VMs, Ansible them into Docker
hosts, and deploy the first real service.

**Outcome:** 🎉 Full arc: bare metal → Proxmox (ZFS) → Terraform VMs → Ansible/Docker →
**Nextcloud in the browser**. Every layer reproducible from git.

### What I did
1. Reinstalled k8plus on **ZFS (RAID0)**; re-baselined in one command (all Session 1 fixes
   baked in):
   ```bash
   ssh-keygen -R 192.168.0.11 && ssh-copy-id root@192.168.0.11
   ansible-playbook bootstrap.yml --limit k8plus
   ```
2. Built cloud-init template 9000 on ZFS (`sed -i 's/STORAGE=local-lvm/STORAGE=local-zfs/'`).
3. Installed **Terraform 1.15.8** (binary, not apt — see gotcha), made a Proxmox API token:
   ```bash
   export TF_VAR_pve_api_token='root@pam!terraform=<secret>'   # single quotes! (the ! )
   ```
4. Terraformed the two family VMs (targeted, since g11/macbook didn't exist yet), then
   Ansible → Docker → Nextcloud.

### Errors & fixes 🔥
**`export TF_VAR_...` → "Invalid block definition"** — I pasted the shell `export` line
into `terraform.tfvars`. It's a terminal command; tfvars holds only variables.
**SSH key showed as literal "PASTE: cat ~/.ssh/..."** — I pasted the instruction, not the
key. Run `cat ~/.ssh/id_ed25519.pub`, paste the real `ssh-ed25519 AAAA...`.
**TF cloud-init disk → `local-lvm` not found** — pin `datastore_id = "local-zfs"` in each
`initialization {}` block.
**WSL lost all network mid-session ("No route to host")** 🔥🔥 — WSL2 network stack
collapsed. `wsl --shutdown`; when that didn't fix it, switched to **mirrored networking**
(`%USERPROFILE%\.wslconfig` → `[wsl2] networkingMode=mirrored`, `dnsTunneling=true`).
**WSL apt: IPv6 unreachable + HashiCorp has no `resolute` suite** — force IPv4 in
apt.conf.d; install Terraform from the binary zip.
**Ansible "Could not resolve hostname vars"** — `vars:` was indented under `hosts:`. It
must be level with `hosts:` (group vars).
**apt "Permission denied" on the VMs** — added `ansible_become: true` on `docker_hosts`.
**Handler "Could not find service sshd"** — Ubuntu's service is `ssh`.
**`docker.sock` permission denied** — `usermod -aG docker ubuntu`; added to the docker role.

---

## Session 1 — 2026-07-21 · First node bring-up

**Goal:** Get the K8 Plus running Proxmox as the family-prod node, with an Ansible control
node driving it, plus a cloud-init template for Terraform.

**Outcome:** Proxmox VE 9 installed, network sorted, Ansible control node working, baseline
applied as code, cloud-init template scripted. Discovered the node was on **LVM**; decided
to reinstall on **ZFS**.

### The highlights
- **BIOS:** enabled SVM/virtualisation, set **Restore on AC Power Loss → Power On**.
- ⚠️ It's **Proxmox VE 9** (Debian 13 "trixie") — newer than the plan assumed. Matters for
  the repo format (deb822 `.sources`).
- **Ansible control node** on the Z13 (WSL Ubuntu): ssh keys, clone the repo, `ansible
  k8plus -m ping` → pong.
- Cloud-init template script seals VM **9000** for Terraform to clone.
- **Decision — reinstall on ZFS:** LVM works, but ZFS gives checksums (bit-rot protection
  for family photos), compression, snapshots, and replication. Node was empty, so cheap to
  redo.

### Errors & fixes 🔥
**`ping ... General failure`** — I'd set the node to `192.168.1.11`, but the LAN is
**192.168.0.0/24**. Confirmed with `ipconfig` (gateway 192.168.0.1), fixed the address +
gateway, then shifted the whole repo `192.168.1.x → 192.168.0.x`. **Lesson: confirm the
router's real subnet before hardcoding static IPs.**
**`apt: No package matching 'vim'`** — node had no DNS. `echo "nameserver 192.168.0.1" >
/etc/resolv.conf; apt update`.
**apt 401 on enterprise.proxmox.com** 🔥 — PVE 9 uses the deb822 `.sources` format, so the
old `.list` disabling didn't work:
```bash
rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update
```
**node_exporter "Could not find service" in `--check`** — dry-run never installed the
package. Run without `--check`; guarded the role with `when: not ansible_check_mode`.
**`Unable to parse .../host.yml`** — the file is `hosts.yml` (plural); run inside `ansible/`.
**`storage 'local-zfs' does not exist`** — installed on LVM. Led to the ZFS reinstall.

---

## 🔥 Gotchas index — "it happened again" quick lookup

| Symptom | Root cause | Fix | Session |
|---|---|---|---|
| `ping ... General failure` (Windows) | Target on a different subnet | Match subnet; check `ipconfig` for real gateway | 1 |
| `apt: No package matching 'X'` | Node has no DNS | `echo "nameserver 192.168.0.1" > /etc/resolv.conf; apt update` | 1 |
| apt `401` enterprise.proxmox.com (PVE **or** PBS) | PVE 9 deb822 repos; enterprise still enabled | Remove the `*-enterprise.sources` file, add `pve-no-subscription.sources` | 1, 3 |
| Ansible "Could not find service" | Ran with `--check` | Run without `--check`; guard `when: not ansible_check_mode` | 1 |
| `Unable to parse .../host.yml` | Wrong filename | It's `hosts.yml` (plural); run inside `ansible/` | 1 |
| `storage 'local-zfs' does not exist` | Installed on LVM | `pvesm status`; reinstall on ZFS | 1 |
| Reinstalled node → SSH "host key changed" | New host key | `ssh-keygen -R <ip>` then reconnect | 1 |
| WSL "No route to host" (LAN too), Windows fine | WSL2 network stack collapsed | `wsl --shutdown`; then `.wslconfig` `networkingMode=mirrored` | 2 |
| WSL apt IPv6 / HashiCorp no `resolute` suite | WSL IPv6 unroutable + too-new codename | Force IPv4 in apt.conf.d; Terraform from binary zip | 2 |
| Terraform tfvars "Invalid block definition" | `export ...` pasted into the file | `export` is a shell cmd; tfvars holds only vars | 2 |
| VM SSH key = literal "PASTE: ..." | Pasted instruction, not key | `cat ~/.ssh/id_ed25519.pub`, paste real key | 2 |
| TF cloud-init disk → local-lvm | Provider default on ZFS host | Pin `datastore_id = "local-zfs"` in `initialization {}` | 2 |
| Ansible "Could not resolve hostname vars" | `vars:` indented under `hosts:` | Put `vars:` level with `hosts:` | 2 |
| VM apt "Permission denied" lock | ubuntu user, no become | `ansible_become: true` on docker_hosts | 2 |
| Handler "Could not find service sshd" | Ubuntu service is `ssh` | Handler `name: ssh` | 2 |
| `docker.sock` permission denied | User not in docker group | `usermod -aG docker ubuntu`; role does it for rebuilds | 2, 4 |
| `does not support NFS export` | exFAT can't be NFS-exported | Share via Samba/CIFS | 3 |
| CIFS `mount error(13)` | Samba password mismatch | Test `smbclient -U user` first; match creds file | 3 |
| Jellyfin LXC no GPU access | render group GID mismatch host vs container | `pct set -dev0 renderD128,gid=<container render gid>` | 3 |
| Cloudflare 525 on tunnel host | stale DNS record from old tunnel | delete hostname+DNS, re-add on new tunnel | 3 |
| Nextcloud "untrusted domain" | new proxy domain not allowlisted | `occ config:system:set trusted_domains` + overwriteprotocol | 3 |
| gluetun timeouts / unhealthy | ProtonVPN free blocks P2P | use a paid P2P VPN (Windscribe) | 3 |
| gluetun "region is not valid" | used VPN's UI label, not Gluetun's name | use exact name from Gluetun's printed list | 4 |
| Torrents stuck at metadata, DHT 0 | VPN server blocks P2P | switch to a P2P-allowed region (Netherlands) | 4 |
| Radarr download client won't connect | wrong host | host = `gluetun` (qbit shares its netns), port 8080 | 4 |
| T2 Mac won't boot USB | T2 blocks external boot | Recovery → Startup Security → No Security + allow external media | 6 |
| `applesmc ... failed with error -5` | T2 hides the SMC from the old driver | Harmless, ignore — T2 manages fans itself | 6 |
| MacBook unreachable, vmbr0 no IP | USB `r8152` NIC enumerates late → bridge portless | `ip link set nic0 up; systemctl restart networking`; `nic_watchdog` automates it | 6 |
| `ifreload -a` "another instance already running" | stale ifupdown lock | `systemctl restart networking` instead | 6 |
| Terraform wants to destroy/replace existing VMs | changed a create-time `clone` flag (e.g. `full`) | match the original value; always `plan` + `-target` the new resource | 7 |
| Grafana crash-loop "only one datasource default" | two provisioning files both `isDefault: true` | keep one default; empty/neutralize the other | 7 |
| CouchDB exits code 1 with NO logs | mounting a `local.d/*.ini` crashes CouchDB 3.5.2 | boot clean; apply config via `_config` HTTP API after startup | 7 |
| PBS backup lock / unreapable zombie / node won't die | disk stuck in kernel I/O (`D` state) | only a reboot clears it; then fix the disk | 7 |
| `zpool` SUSPENDED, disk gone from `lsblk` | bus-powered USB disk dropped off under load | powered enclosure/cable/port; `zpool clear` + scrub | 7 |
| Rebooting one node kills remote access to ALL nodes | only that node ran the Tailscale subnet router | run Tailscale on every node (own IP); redundant routers | 7 |
| Node self-locks-out after `tailscale up` | node accepted a route for its own `/24` | `tailscale set --accept-routes=false`; recover via web console | 7 |
| All non-VPN containers fail DNS (`Temporary failure in name resolution`) | Tailscale `--accept-dns` (MagicDNS) hijacked the resolver, no working upstream | `tailscale set --accept-dns=false` + `resolvectl dns <iface> 192.168.0.1 1.1.1.1`. On servers: Tailscale identity-only | 7 |
| VM SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" | rebuilt VM = new host key vs stale known_hosts | `ssh-keygen -R <ip>` then reconnect (verify fingerprint via console for anything internet-facing) | 7 |
| Node offline, console spams `NIC Link Up 2500 → Down` | Intel i225/i226 (`igc`) EEE link-flap bug | `ethtool --set-eee <iface> eee off` (codified in `nic_tuning`); else force 1G / swap cable | 7 |
| LXC won't restart after a node reboot | manually-created LXCs default to onboot=0 | `pct set <id> -onboot 1` | 7 |
| Jellyfin LXC won't start: `Device /dev/dri/card0 does not exist` | GPU DRM nodes renumbered on reboot (card0→card1) | transcoding needs only `renderD128` → `pct set 200 --delete dev1`; durable: pass by `/dev/dri/by-path` | 7 |
| VM keeps OOM-shutting-down; `free` ≪ installed RAM | BIOS **UMA Frame Buffer** default (e.g. 4G) eats host RAM | BIOS → GFX → UMA Frame Buffer → 256M (headless). PVE9 already caps ARC — not the culprit | 8 |
| Fresh VM: `Unable to acquire the dpkg frontend lock` | cloud-init runs apt on first boot | `cloud-init status --wait` before apt (in the `docker` role now) | 8 |
| Grafana Loki panel "parse error ... empty-compatible" | all-`.*` label matchers | anchor with a real matcher e.g. `job="docker"`; set variable "All" value to `.+` | 8 |
| Winbox "connection timed out" to a new MikroTik | default IP 192.168.88.1 ≠ your subnet | connect **by MAC** (Winbox → Neighbors); works at L2 regardless of IP | 8 |
| KVM-over-IP: see the screen but can't type | web console not focused (USB HID is fine) | click the video area first; check `dmesg`/`lsusb` for the emulated keyboard | 8 |
| qBittorrent stuck 0 / DHT 0 / "firewalled" | gluetun tunnel went stale | `cd ~/stacks/media && docker compose restart gluetun qbittorrent` (region switch only if that fails) | 8 |
| Immich `immich-machine-learning` crash-loops: `NumPy … baseline optimizations (X86_V2) … machine doesn't support (X86_V2)` | Proxmox default VM CPU `kvm64` lacks x86-64-v2 (SSE4.2/POPCNT); ML's NumPy is built for v2 | Terraform `cpu { type = "host" }` (or a named `x86-64-v2`+ model); cold-boot the VM | 9 |
| Immich upload fails for large videos over the Cloudflare Tunnel | CF proxy caps request body at 100 MB (Free/Pro) | upload over Tailscale/LAN (no cap); keep the tunnel for viewing | 9 |
| New ZFS pool disappears / wrong disk after reboot | created pool on `/dev/sdX` (letters reshuffle) | always `zpool create` on `/dev/disk/by-id/…`; `zpool export/import -d /dev/disk/by-id` to fix | 9 |
| Tailscale role runs "OK" but `tailscale ip` → `NeedsLogin` | `creates: tailscaled.state` guard skips the join — daemon writes that file *before* login | guard on `tailscale status --json` backend state instead; recover now with a manual `tailscale up --ssh --accept-routes=false --accept-dns=false` | 9 |
| qBittorrent Web API returns `Forbidden` from the host | qbit is in gluetun's netns → request arrives from a Docker IP, not `127.0.0.1`, so localhost-bypass never fires | whitelist the Docker subnet (`172.16.0.0/12`) in qbit → Web UI → "Bypass auth for whitelisted IP subnets" | 10 |
| `systemctl start` as `ubuntu` → polkit "Authentication failure" | cloud-init user has no password to answer the polkit prompt | use `sudo systemctl …`; anything that *changes* systemd state needs root | 10 |
| Remote `*.lab` = "Non-existent domain" (e.g. `git.lab`) | client DNS is the corp/ISP resolver, not Tailscale's `100.100.100.100` → split-DNS not applied | enable "Use Tailscale DNS" + a `lab`-restricted split-DNS nameserver = AdGuard; hosts-file fallback (test with `ping`, not `nslookup`) | 10 |
| Pool `SUSPENDED`, disk renamed `sdc`→`sde` | ZFS matches vdevs by label GUID, not `/dev/sdX` — the rename is the *fingerprint* of a bus drop, not the cause | `dmesg -T`: several devices dropping in the same second = hub reset, not a dying disk. `zpool clear <pool>` | 11 |
| vdev path in `zpool status` no longer exists (`ata-…` vs `usb-…`) | lost UAS/USB 3 — behind a USB 2.0 hub the kernel falls back to `usb-storage` and a generic name | `dmesg`: `super-speed`+`uas` = USB 3, `high-speed`+`usb-storage` = USB 2. Direct port, then `export` + `import -d /dev/disk/by-id` | 11 |
| Pool won't recover after the disk returns | default `failmode=wait` freezes pool I/O and does not self-clear | `zpool clear <pool>`. Check counters first — **non-zero CKSUM on a single vdev = unrepairable, stop** | 11 |
| Terraform `~ update in-place` reboots a VM | *in-place* = the resource isn't recreated; says nothing about downtime. QEMU builds the vCPU at start, so `cpu.type` forces a stop/start | expect a power cycle; `reboot_after_update=false` won't help. Stage with `-target` | 11 |
| Terraform DNS change has no effect on an existing VM | cloud-init network config is first-boot only | fix live via netplan/`resolvectl`; Terraform only helps future VMs | 11 |
| A local file named `root@<ip>` appears | `scp file root@ip` — missing colon, so it's a local copy | `scp file root@ip:/path`. Check `git status` before committing | 11 |
| Pushed, but the other remote is behind | `git push` only pushes to `origin` | `git push <remote> main`, or set up mirroring | 11 |
| Jellyfin lists titles but playback fails | USB disk re-enumerated. `nofail` means "don't block boot" — **not** auto-mount on hotplug. Mount point stayed empty; the DB still had metadata | `mount -a` → `findmnt -t exfat` → **`pct restart 200`** | 11 |
| Host mount fixed, container still sees an empty folder | an LXC bind mount is resolved once, at container start | restart the container | 11 |
| exFAT files unreadable to a service | exFAT has no Unix permissions — `uid=`/`gid=`/`umask=` synthesize them, so those options *are* the access control | keep `uid=1000,gid=1000,umask=002` on any fstab edit | 11 |
| CI job can't clone `git.lab`, but the runner VM resolves it fine | VM and containers have different resolvers — Docker strips the loopback stub and falls back to `8.8.8.8` | `/etc/docker/daemon.json` → `{"dns":["192.168.0.31","1.1.1.1"]}`, validate, restart docker | 12 |
| A CI job fails before any `script:` line appears | every job clones the repo first | read the log above your script; `exit 128` = git failed | 12 |
| Docker won't start after editing `daemon.json` | JSON is stricter than YAML — no trailing commas, no comments | **always** `python3 -m json.tool` before restarting | 12 |
| `nano /etc/…` lets you type, then "Permission denied" | `/etc` is root-owned; nano only fails at write time | `sudo nano`. Long edits: Ctrl+O to `/tmp/`, then `sudo cp` | 12 |
| Job sits "pending", no runner takes it | job `tags:` must be a subset of the runner's; a mismatch never errors | check Settings → CI/CD → Runners | 12 |
| An Ansible `when:` guard never skips | `when:` is already a Jinja context — quoting a sub-expression makes it a truthy string literal | drop the outer quotes. **Verify by running against a converged host** | 12 |
| Task reports success but installed nothing (`curl … \| sh`) | in a pipeline the exit code is the **last** command's | `set -o pipefail &&` plus `executable: /bin/bash` | 12 |
| Config changed but the service never restarted | handler renamed without updating `notify:` — exact string match, fails silently | rename both sides in one commit, then `grep -rn "notify:"` | 12 |
| `copy`/`template` gives different permissions per host | no `mode:` → falls back to the remote umask | always set `mode:`, always quote it | 12 |
| Tool crashes on import, traceback all inside `site-packages` | dependency problem — pinned one package while its deps floated | pin what you've verified: read versions off a green run, freeze together | 12 |
| A lint config file seems to be ignored | ansible-lint walks *up* from cwd; yamllint checks only the current dir | run from the repo root: `ansible-lint ansible/` | 12 |
| Lint findings don't fall monotonically | ansible-lint profiles promote you as you clear each tier | pin it: `profile: production` in `.ansible-lint` | 12 |
| Reaches the internet but not `*.lab` | resolver is the router — it advertises AdGuard over DHCP but forwards its own queries to the WAN | point every resolver at `192.168.0.31` directly. Prove: `dig @192.168.0.1 git.lab` vs `@192.168.0.31` | 12 |
| `Terraform has no command named "sh"` in a CI job | the image sets the tool as its ENTRYPOINT | `entrypoint: [""]` on the image | 12 |
| CI resolves different provider versions than your laptop | `.terraform.lock.hcl` was gitignored — that file **is** the pin | commit it; ignore only `.terraform/` | 12 |
| Ansible copies a config, but the container keeps the old one | `state: present` only recreates when the *definition* changes; a bind-mounted file isn't part of it | `docker kill -s HUP <c>`, or `register:` the copy and pass `recreate: always`. **A green run that half-worked** | 12 |
| Docker: `mkdir /mnt/media: file exists` | bind-mount source is a **stale** network mount — path exists, transport dead | `compose down` → `umount -l` → `mount -a` → verify → up | 12 |
| A mount breaks on one host, containers fail on another | USB drop → local mount gone → Samba share empty → CIFS client stale. **Fixing the server doesn't un-wedge the client** | remount the client too; add `_netdev,x-systemd.automount` to its fstab | 12 |
| Two identical `/etc/fstab` lines for one mountpoint | systemd generates a `.mount` unit per entry — they conflict | `grep -c '<mnt>' /etc/fstab` should be 1. Field 4 takes **no spaces** | 12 |
| ArgoCD Application stuck at `SYNC STATUS: Unknown` | it never read the repo. A neighbouring `Healthy` means nothing — it's reporting on zero resources | `kubectl -n argocd logs deploy/argocd-repo-server` | 13 |
| Your fix is in the file but ArgoCD ignores it | **ArgoCD only reads git — the working copy is invisible** | debug the commit: `git show <sha>:path`. Then annotate `argocd.argoproj.io/refresh: hard` to skip the 3-min poll | 13 |
| `git.lab` resolves from a pod only sometimes | `ndots:5` — a 1-dot name tries 3 cluster-domain variants first, all NXDOMAIN | use an absolute name (`http://git.lab./…`) or `hostAliases`. Not a DNS server fault | 13 |
| A container can't resolve what the host can | Alpine/musl issues A and AAAA in parallel and fails when one comes back empty; our `*.lab` rewrites are IPv4-only | check the base image before blaming DNS | 13 |
| busybox `nslookup` prints an address AND `NXDOMAIN` | both true — A resolved, AAAA didn't | normal for an IPv4-only rewrite | 13 |
| K3s LoadBalancer stuck at `EXTERNAL-IP: <pending>` | klipper-lb binds a hostPort on every node; Traefik already owns :80 | use the NodePort, another port, or an Ingress via that Traefik | 13 |
| Ansible shows `ok=1, changed=0` on every host | only `Gathering Facts` ran — tasks filtered out by a tag or host-pattern mismatch | nothing failed, nothing ran. Check the task count | 13 |
| `terraform plan` says "N to add, M to **change**" | other resources carry drift and a plain apply sweeps them in — here, 5 production VMs | read the change count, not just the add count; `-target` to stage | 13 |
| `kubectl run … -- <tool> <args>` → "not a valid command" | args after `--` are appended to the image ENTRYPOINT | add `--command` so they replace it instead | 13 |
| GitHub Actions: `cd: <dir>: No such file or directory` | **Actions does NOT clone your repo** — the workspace starts empty. GitLab does; opposite defaults | `- uses: actions/checkout@v4` as the FIRST step | 12 |
| `terraform: command not found` on a GitHub runner | removed from the hosted images after HashiCorp's licence change | add `hashicorp/setup-terraform@v3` | 12 |
| `git push` → 403 after adding a second push URL | `origin` fetches over SSH; an HTTPS push URL needs a PAT instead | match the scheme of the fetch URL; check `git remote -v` | 12 |
| `Conditional result (True) was derived from value of type 'str'` | quoted `when:` sub-expression. Newer ansible-core errors instead of accepting it | drop the outer quotes. **Then run it — this exact fix failed to land once already** | 12 |
| `terraform fmt -check` exits 3 | files aren't canonical — often `//` comments, which fmt rewrites to `#` | `terraform fmt -recursive`. The one lint with a guaranteed safe auto-fix | 12 |
| `A && B \|\| C` in a shell script (SC2015) | not if-then-else: if A succeeds and **B** fails, C still runs | use a real `if/then/else` | 12 |
| `.editorconfig` "does nothing" | editors read it, and only for files saved after it exists | **nano ignores it** — no help for SSH edits. Fix existing files by hand | 12 |
| A config hand-written on one host, never codified | vanishes on rebuild and the bug returns | put it in the role; use `validate: <cmd> %s` so a bad file fails the task | 12 |
| DNS container won't start — port 53 in use | systemd-resolved holds `127.0.0.53:53`; publishing on `0.0.0.0:53` collides with it | publish on the **LAN IP**: `192.168.0.31:53`. Verify `ss -lnup 'sport = :53'` | 12 |
| `--check --diff` shows files being *created* on a converged host | that host is behind the repo | it's a drift detector, not just a preview — run it fleet-wide as an audit | 12 |
| `get_url` reports `changed` on every check-mode run | it can't verify a remote file without downloading | expected; add `checksum:` for certainty. Check mode over-reports for anything that reaches out | 12 |
| `{{ ansible_distribution_release }}` silently becomes undefined | `INJECT_FACTS_AS_VARS` goes away in ansible-core 2.24 | use `ansible_facts['distribution_release']`. **ansible-lint passed this at the production profile** | 12 |

---

## Template for the next entry (copy this)

```markdown
## Session N — YYYY-MM-DD · <title>

**Goal:**
**Outcome:**

### What I did
- ...
​```bash
# commands
​```

### Errors & fixes 🔥
**Error:** <message>
**Cause:**
**Fix:**

### Next session
- ...
```
