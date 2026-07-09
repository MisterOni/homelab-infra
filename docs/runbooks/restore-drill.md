# Runbook: quarterly restore drill

An unverified backup is a hope, not a backup. Once a quarter:

1. Pick one PBS backup at random; restore it as a NEW VM (never over the original).
2. Boot it, verify the service starts and data is intact.
3. Pull one photo album from the off-site (B2) copy; verify checksums.
4. Restore the GitLab backup into a scratch VM; verify a repo clone works.
5. Log results below. If anything failed, fixing it is this week's top task.

| Date | What was restored | Time taken | Result |
|---|---|---|---|
