# My Family Never Noticed: Moving Our Media Platform to a 3-Node Cluster With Zero Downtime

*Built over a handful of July evenings in 2026. Every config in this post is public — link at the bottom.*

---

There's a specific kind of pressure that comes from running infrastructure your family actually uses. Nobody writes you an SLA, but the SLA is real, and it gets enforced at dinner.

For about a year, everything in my homelab lived on one 2019 MacBook Pro running Proxmox: Jellyfin for movie nights, a couple of DevOps tools I was learning on, monitoring, all published through a Cloudflare Tunnel on my own domain. It worked — until the machine rebooted. The MacBook has a habit of coming back with its network adapter dead until someone physically wakes it up. And when that machine is also the family's entire media library, "someone" is always me, always mid-movie.

So I decided to stop patching the symptom and redesign the whole thing around one idea I kept seeing real platform teams live by: **match how critical a workload is to how reliable its hardware is.**

## The design: production, infrastructure, and a lab that's allowed to die

I picked up two mini PCs — a GMKtec K8 Plus (32 GB) and a G11 (16 GB) — plus a 2.5GbE switch, and split everything into three tiers.

The K8 Plus is **family-prod**: Jellyfin with hardware transcoding on its Radeon iGPU, Nextcloud for files, photos coming soon, and the media-automation stack. It also inherited the two 1 TB drives with our library on them. Its only job is to never make the family notice it exists.

The G11 is **core-infra**: reverse proxy, DNS, GitLab, monitoring. Small, always-on, deliberately boring.

And the MacBook becomes the **lab** — a disposable playground for Kubernetes and CI/CD. Its unreliable adapter went from being my biggest operational headache to being irrelevant, because nothing family-facing runs there. I even automated the adapter fix with a small systemd watchdog, so now the quirk protects my time instead of ruining movie night.

As I write this, all three are built and joined into one Proxmox cluster that survives losing any single node — so the flaky MacBook can drop off whenever it likes and the family tier doesn't even blink.

## The trick that made zero downtime possible

Here's the thing I didn't fully appreciate until I planned this: a Cloudflare Tunnel completely decouples your public hostnames from the machines behind them. `jellyfin.mydomain.com` doesn't point at a server — it points at a tunnel, and the tunnel decides where the traffic goes.

So every service could move the same way, which I later learned is just a blue-green deployment in casual clothes:

1. Deploy the new instance on the new node — from config already committed to git, never by hand.
2. Publish it at a temporary hostname through the tunnel.
3. Test it properly: logins, playback, a real transcode.
4. Flip the real hostname's ingress rule to the new internal IP.
5. Leave the old instance stopped-but-intact for a week, then delete it.

The flip takes seconds. Same URL, same bookmarks, same everything. The evening I cut Jellyfin over, I tested it from my phone on cellular data — new node, same address, a movie playing smoothly with the iGPU doing the transcoding. The only evidence anything had changed was a line in my git log.

## The details that actually took time

Zero downtime doesn't mean zero effort. A few honest notes:

**The most useful backup lesson was that I didn't need one.** My plan opened with "back up the old GitLab first." Then I hit a wall: I'd forgotten the root password to that old VM and couldn't even log in to run the backup. Small panic — until I asked what was actually on it. Nothing. No live repos, no history I cared about, just a service I'd stood up to learn on. The real lesson wasn't about backup internals; it was **figure out what genuinely needs preserving before you build a migration around protecting it.** I'd nearly spent a weekend rescuing data that didn't exist. I wiped it and started clean.

**ZFS choices matter more than they look.** I deliberately did *not* mirror my two drives. Movies are re-downloadable; family photos are not. So one disk holds media and the other became a dedicated pool for nightly Proxmox Backup Server snapshots. Losing redundancy on replaceable data bought me a whole backup disk for the irreplaceable stuff. The encrypted off-site copy is the next step — I'm holding it until the photo library actually lands, so 3-2-1 kicks in exactly when there's something worth 3-2-1-ing.

**The torrent stack needed a kill-switch, not a lecture.** The media VM routes qBittorrent through a Gluetun VPN container using Docker's `network_mode: "service:gluetun"`. The torrent client has no network of its own — if the VPN drops, traffic stops. I tested it by killing the VPN container mid-download and watching qBittorrent fail with `bad address` on every request. Zero leak. Two lessons the hard way: the free VPN tier I started with silently blocks P2P (the tunnel connects, then every peer times out), and even on a paid plan the *server region* matters — one region blocked DHT while another worked instantly. Test your kill-switch, and test that your VPN actually allows what you're using it for, before you need either.

**Migration order matters.** Family services first — get the thing people depend on safe and stable. Core infra second, on its own node. Only when nothing points at the old MacBook does it get wiped and rejoin as the disposable lab node. I keep a decommission checklist in the repo and won't format a disk until every box is ticked.

## What I'd tell you if you're planning the same thing

The migration took a handful of evenings — reinstalling Proxmox on ZFS, Terraforming the VMs, Ansible-ing them into Docker hosts, moving the drives, standing up Jellyfin with GPU passthrough, and finally cutting over. The technical work was maybe half of it. The other half was discipline: writing down the current state before changing it, committing every config before applying it, and resisting the urge to "just quickly fix" something by hand on the new machines.

That discipline paid off in a way I didn't expect. Because every compose file, playbook, and tunnel config went into git from day one, I accidentally ended up with something more valuable than a working homelab: a repo that documents exactly how to build it again. That repo is now the backbone of everything else I'm doing — but that's the next post.

The best compliment my infrastructure ever got came about a week after the cutover, when I asked my family if they'd noticed anything different about Jellyfin.

"No. Why, did something change?"

Everything changed. That's the point.

---

*The full configuration for everything here — Terraform, Ansible, compose files, runbooks — is public at [github.com/MisterOni/homelab-infra](https://github.com/MisterOni/homelab-infra).*
