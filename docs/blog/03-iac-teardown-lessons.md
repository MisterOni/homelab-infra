# I'm Going to Destroy My Kubernetes Lab Every Month. Here's the Discipline Behind It.

*This is the practice I'm designing into the lab tier of my homelab. The 3-node Proxmox cluster is already live and rock-stable (earlier posts); the disposable Kubernetes node runs on top of it. The teardown scoreboard below fills in with real numbers as the drills start — the philosophy is already how I run the tier that exists.*

---

The plan: on the first Saturday of every month, run `terraform destroy` against my entire Kubernetes lab — three VMs, the cluster, ArgoCD, Jenkins, every experiment — and then time how long it takes to bring it all back from git.

That probably reads like a flex. It's meant to be closer to a confession-generator. The whole reason to schedule a monthly teardown is that the *first* rebuild is always a mess, and every drill after it is an audit of my own bad habits. I'd rather find those habits on a Saturday I chose than a Tuesday I didn't.

## Why deliberately break a working lab?

My lab runs on a 2019 MacBook Pro whose USB network adapter reliably dies on reboot. When I designed the three-node cluster, I put the disposable workloads on the unreliable machine *on purpose* — the family's media server lives elsewhere, on hardware that behaves. (More on that in the [migration post](01-zero-downtime-migration.md).) The three nodes are joined into one Proxmox cluster now, so losing the flaky one still leaves quorum; the lab node is genuinely free to come and go.

But "disposable" is a claim, not a property. Plenty of infrastructure gets *called* cattle and *treated* like a pet — unique, hand-fed, irreplaceable in ways nobody wrote down. The only way to know which one you've got is to shoot it and see if a new one appears. Infrastructure-as-code that's never been re-run from scratch is really infrastructure-as-hope.

So the drill is the test. If my repo really is the single source of truth, the rebuild is boring. Every place it *isn't* boring is a place I lied to myself in a commit message.

## What I expect the drills to catch

The scoreboard will live in my repo's README — one row per drill: date, rebuild time, and the one thing that broke. I already know the shape of the early entries, because everyone's are the same: a kubeconfig that only existed on a laptop, a Helm value someone tweaked in a UI that lived in nobody's memory, a `:latest` tag that moved so "the same" cluster came back subtly different. The first rebuild will be more improvisation than execution. That's not the failure mode — that's the syllabus.

The rule I'm carrying over from the family-tier build is simple: *any manual step becomes code the second time I do it.* The MacBook's flaky NIC is the flagship example. It started as "walk over and bounce the adapter." Then I wrote a script. Then the script became an Ansible role with a systemd unit that heals the adapter on boot — I rebuilt the node, rebooted it, and watched it come back online by itself without me touching a thing. A hardware quirk that used to threaten movie night is now just another file in git.

The trend line matters more than any single number. Rebuilds should get faster and duller every month, until the drill is so uneventful the only interesting part is the blog post. *(Real destroy-to-synced-dashboard times land here once the lab node is running — trend included, embarrassing first run and all.)*

## Where the truth is allowed to live

A rebuild traverses the whole stack, which makes it a nice map of what "everything as code" means in practice. Terraform recreates the VMs from a cloud-init template — names, IPs, sizes, all declared. Ansible turns blank VMs into configured nodes — packages, hardening, exporters, the NIC watchdog. K3s goes on, then ArgoCD, then ArgoCD reads one app-of-apps manifest and pulls every workload back out of git. My part of the ceremony is three commands and some tea.

The subtle lesson is deciding *where state is allowed to live.* Code lives in git. Secrets live encrypted — safe to store, never plaintext. Data — the stuff that can't be regenerated — lives outside the blast radius entirely, on the production node, with real backups. The lab can only be casually destroyable because nothing irreplaceable is ever allowed onto it. Deciding what's cattle isn't a naming exercise; it's a data-placement exercise.

## The career angle, honestly

I'm building the drills to keep myself honest. But I already suspect the real payoff is a single sentence: "my lab rebuilds from git in *N* minutes."

That one line compresses a lot of claims into one verifiable thing: that I write Terraform and Ansible someone else could run, that my GitOps actually reconciles from nothing, that I treat disaster recovery as a practice rather than a document. The best interview questions tend to be follow-ups to a sentence like that. And because the repo is public, none of it needs trust — the receipts are in the commit history, including the embarrassing early ones. *Especially* the embarrassing early ones; a repo where nothing ever went wrong is a repo where nothing was learned.

The same code is meant to have a party trick, too: a variant of the lab that deploys to AWS on demand — VPC, instance, k3s, app — runs a demo for a few cents, then `terraform destroy`s itself back to zero. Ephemerality turns out to be a transferable skill.

## If you want to start

Don't start with the drill. Start with one honest question: *if this machine vanished right now, what would I actually lose?* Write the answer down. Everything on that list either becomes code, becomes an encrypted secret, or moves somewhere with backups. Then — only then — schedule the teardown, put it in your calendar, and treat whatever breaks as the curriculum.

The first rebuild will be a mess. Do it anyway. The mess *is* the syllabus.

---

*The Terraform, Ansible, and drill scoreboard live in [github.com/MisterOni/homelab-infra](https://github.com/MisterOni/homelab-infra).*
