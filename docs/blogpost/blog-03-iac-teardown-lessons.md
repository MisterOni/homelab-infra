# I'm Going to Destroy My Kubernetes Lab Every Month. Here's the Discipline Behind It.

*This is the practice I'm designing into the lab tier of my homelab — the family platform is already live and rock-stable (earlier posts), and the disposable Kubernetes node is the next phase. The teardown scoreboard below fills in with real numbers as the drills start; the philosophy is already how I run the tier that exists.*

---

The plan: on the first Saturday of every month, run `terraform destroy` against my entire Kubernetes lab — three VMs, the cluster, ArgoCD, Jenkins, every experiment on it — and then time how long it takes to bring it all back from git.

That probably sounds like a flex. It's meant to be closer to a confession-generator. The whole reason to schedule a monthly teardown is that the *first* rebuild is always a disaster, and every drill after it is an audit of your own bad habits. I'd rather find those habits on a Saturday I chose than a Tuesday I didn't.

## Why deliberately break a working lab?

My lab runs on a 2019 MacBook Pro whose network adapter routinely dies after a reboot. When I designed my three-node homelab, I put the disposable workloads on the unreliable machine on purpose — the family's media server lives elsewhere, on hardware that behaves. (I wrote about that design in the [migration post](https://github.com/MisterOni/homelab-infra/blob/main/docs/blogpost/blog-01-zero-downtime-migration.md).)

But "disposable" is a claim, not a property. Plenty of infrastructure is *called* cattle and *treated* like a pet: unique, hand-fed, irreplaceable in ways nobody documented. The only way to know which one you have is to shoot it and see if a new one appears. Infrastructure-as-code that has never been re-run from scratch is best understood as infrastructure-as-hope.

So the drill is the test. If my repo really is the single source of truth, the rebuild is boring. Every place it isn't boring is a place I lied to myself in a commit message.

## What I expect the drills to catch

The scoreboard will live in my repo's README, one row per drill: date, rebuild time, and the one thing that broke. I already know the shape of the early entries, because everyone's are the same — a kubeconfig that only existed on a laptop, a Helm value someone tweaked in a UI that lived in nobody's memory, a `:latest` tag that moved so "the same" cluster came back subtly different. The first rebuild will involve more improvisation than execution. That's not the failure mode; that's the syllabus.

The rule I'm carrying in from the family-tier build is simple: *any manual step becomes code the second time I perform it.* The MacBook's flaky NIC is the flagship example — what started as "walk over and bounce the interface" becomes a systemd watchdog deployed by an Ansible role, and the hardware quirk that once threatened movie nights turns into just another file in git.

The trend line matters more than any single number. Rebuilds should get faster and duller every month, until the drill is so uneventful the only interesting part is the blog post. *(Real destroy-to-synced-dashboard times land here once the lab node exists — trend included, embarrassing first run and all.)*

## The layers, and where the truth lives

A rebuild traverses the whole stack, which makes it a nice map of what "everything as code" actually means in practice. Terraform recreates the VMs from a cloud-init template — names, IPs, sizes, all declared. Ansible turns blank VMs into configured nodes — packages, hardening, exporters, the NIC watchdog. K3s goes on, then ArgoCD, then ArgoCD reads one app-of-apps manifest and pulls every workload back out of git. My part of the ceremony is three commands and some tea.

The subtle lesson here was learning *where state is allowed to live*. Code lives in git. Secrets live encrypted (safe to store, never plaintext). Data — the things that can't be regenerated — lives outside the blast radius entirely, on the production node, with real backups. The lab can only be casually destroyable because nothing irreplaceable is ever allowed onto it. Deciding what's cattle isn't a naming exercise; it's a data-placement exercise.

## The unexpected career dividend

I'm building the drills to keep myself honest. But I already suspect the real payoff is a single sentence: "my lab rebuilds from git in *N* minutes."

It compresses a lot of claims into one verifiable artifact: that I write Terraform and Ansible someone else could run, that my GitOps setup actually reconciles from nothing, that I treat disaster recovery as a practice rather than a document. The best interview questions tend to be follow-ups to a sentence like that. And because the repo is public, none of it requires trust — the receipts are in the commit history, including the embarrassing early ones. *Especially* the embarrassing early ones; a repo where nothing ever went wrong is a repo where nothing was learned.

The same code is built to have a party trick, too: a variant of the lab that deploys to AWS on demand — VPC, instance, k3s, app — runs a demo for a few cents, and then `terraform destroy`s itself back to zero. Ephemerality turns out to be a transferable skill.

## If you want to start

Don't start with the drill. Start with one honest question: *if this machine vanished right now, what would I actually lose?* Write the answer down. Everything on that list either becomes code, becomes an encrypted secret, or gets moved somewhere with backups. Then — only then — schedule the teardown, put the date in your calendar, and treat whatever breaks as the curriculum.

The first rebuild will be a mess. Do it anyway. The mess *is* the syllabus.

---

*The Terraform, Ansible, and drill scoreboard from this post live in [github.com/MisterOni/homelab-infra](https://github.com/MisterOni/homelab-infra).*
