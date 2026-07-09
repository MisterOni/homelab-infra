# ☁️ Ephemeral AWS demo — spin up, show off, tear down

Deploys a mini version of the lab to AWS **live during a demo or interview**,
then destroys it immediately. Total cost per run: a few cents.

## What it builds
- VPC + public subnet + security group
- 1× t3.medium (spot) running k3s via user-data
- The demo app deployed through the same manifests as the homelab

## The party trick
```bash
./scripts/demo.sh up      # ~4 minutes: infra + k3s + app, prints public URL
./scripts/demo.sh down    # terraform destroy -auto-approve — nothing left behind
```

Why not EKS? EKS control planes take ~15 min and cost $0.10/hr before nodes.
For a live demo, k3s-on-EC2 shows the same IaC + GitOps skills at 1/20th the
cost and 1/4th the wait. An `eks/` variant is a good later addition — talk
about that trade-off in the interview; the reasoning IS the skill.

## Guard-rails
- Spot instance + 2h auto-shutdown in user-data (belt and braces)
- `aws budgets` alarm at US$5/month recommended
- Everything tagged `project=homelab-demo` so strays are findable
