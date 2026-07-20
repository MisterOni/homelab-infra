# Plan: jocelynchoo.com as the portfolio front door

The repo is the proof; the website is the pitch. One scrolling page:

1. **Hero** — name, "DevOps Engineer", one-line pitch, buttons: GitHub · LinkedIn · CV (PDF)
2. **The 5-minute demo video** — commit → CI → scan → ArgoCD → live rollout (embed)
3. **Architecture** — the same diagram as the repo README, rendered as an image
4. **Live proof (optional, powerful)** — public Grafana snapshot or Uptime Kuma status page: real infra, really running
5. **The AWS party trick** — short clip of `demo.sh up` → live URL → `demo.sh down`, with the cost receipt
6. **Write-ups** — the 2–3 blog posts
7. **Contact** — jocelyn@your-mail.example (Proton on own domain looks professional)

Hosting options in order of portfolio value:
- **Cloudflare Pages, deployed by GitLab CI** (free, and the deployment itself is a portfolio piece)
- GitHub Pages (fine, less interesting to talk about)
Keep the site static (Astro/Hugo or hand-rolled) — fast, free, nothing to patch.
