# Git hooks

## pre-commit — secret scanner
Blocks commits whose staged changes look like they contain secrets or private
info (API tokens, private keys, AWS keys, password assignments, UUID tokens,
and your real domains). Placeholders like `<secret>`, `changeme`, `.env.example`
are ignored.

### Enable it (once per clone)
```bash
git config core.hooksPath .githooks
```

### Bypass a false positive (rare)
```bash
git commit --no-verify
```

Because it lives in the repo (not `.git/`), anyone who clones and runs the
one-line `core.hooksPath` command gets the same protection. Good "secrets
hygiene as code" talking point for interviews.
