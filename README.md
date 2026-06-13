# Workspace devcontainer

A hardened dev container built on the **[`devcontainers` toolkit](../devcontainers)**: the
`workspace` runs on the toolkit's `default` image plus a thin specialized layer
([Dockerfile](./Dockerfile) — pandoc, Claude Code, `tf`/`aws-get-account-id`, dotfiles),
and two **credential sidecars** vend short-lived, scoped AWS + GitHub credentials onto a
read-only `/creds` shelf the workspace consumes.

- **Patterns** (trust model, VS Code channel hardening, container isolation, the credential
  contract) live in the toolkit: [devcontainers/docs/SECURITY.md](../devcontainers/docs/SECURITY.md)
  and [SECRETS.md](../devcontainers/docs/SECRETS.md).
- **What's specific to this devcontainer** (trust tiers, what it vends, mounts, invariants)
  is in [SECURITY.md](./SECURITY.md).
- This file is the **operational guide** — first run, daily use, troubleshooting.

## Components

| | Image | Role |
|---|---|---|
| `workspace` | `default` + [Dockerfile](./Dockerfile) | the dev container; reads `/creds` via base's `devcred`/git/gh/aws shims |
| `credentials-aws` | `credential-shelf-aws` | vends the AWS agent role → `/creds/aws/credentials` |
| `credentials-github` | `credential-shelf-github` + [github-creds/](./github-creds) | vends per-org GitHub App tokens → `/creds/github/<org>` |

The sidecars share an `admin-home` volume (the SSO session) so one login serves both; that
home is mounted into **no** consumer. The workspace has no SSO session and no `kms:Sign` —
it can only read what's vended.

## First run (one-time)

1. **Publish/pull the toolkit images** (`default`, `credential-shelf-*`) — CI on
   `skleinjung/devcontainers`.
2. **GitHub App key → KMS** (once, if not already done): in the github sidecar,
   `import-app-private-key <app-key.pem>` imports it as a non-extractable KMS key; set the
   alias as `VEND_GH_KMS_KEY_ID`, grant `kms:Sign` to `VEND_GH_AWS_PROFILE`, shred the `.pem`.
3. **SSO login** — set up `~/.aws/config` (your SSO start URL + the agent/kms profiles) in the
   shared `admin-home`, then log in (device-code flow; `AWS_SSO_USE_DEVICE_CODE=1` is set):
   ```sh
   docker exec -it <project>-credentials-aws-1 aws sso login --profile 084828575849-developer-ai-agent
   ```
   Within ~60s both sidecars vend.

## Daily use

- **Re-login** when the Identity Center session lapses (~8h): repeat the `aws sso login` above.
  One login revives both vend loops within 60s.
- **Health**: `cat /creds/status/*` (`ok expires=…` / `stalled …`; mtime is a heartbeat) or
  `docker logs -f <project>-credentials-aws-1`.
- `git push/pull` over HTTPS and `aws`/`gh` "just work" via base's shims; nothing in the
  workspace can mint or widen a credential.

| Credential | Lifetime | Renewal |
|---|---|---|
| GitHub token (`/creds/github/<org>`) | 1h (GitHub-fixed) | auto, <10 min left |
| AWS role creds (`/creds/aws/credentials`) | 1h (permission-set) | auto, <15 min left |
| **Identity Center session** | ~8h (org setting) | **device-code login (the one recurring step)** |
| KMS App key | permanent, non-extractable | — |

## Troubleshooting

| Symptom | Meaning | Fix |
|---|---|---|
| `aws`/`gh`/`git` unauthenticated, `devcred` breadcrumb | shelf creds aged out (vend stalled) | `aws sso login` in `credentials-aws` |
| `/creds/status/*` says `stalled since=…` | a vend loop can't reach SSO/KMS | `docker logs <…-credentials-*-1>`; usually re-login |
| `gh`/`git` wrong-org / "no valid token" | no repo context + `GH_DEFAULT_ORG` unset/not-vended | pass `-R <org>/<repo>` or set `GH_DEFAULT_ORG` to a vended org |
| status mtime >5 min old | a sidecar isn't running | `docker compose up -d` (host, from the workspace project) |
| `/creds` missing | container built without the shelf mount | rebuild the workspace |

## Changing what's vended

- **AWS scope**: edit `VEND_AWS_PROFILES` on `credentials-aws` in
  [docker-compose.yml](./docker-compose.yml), then recreate the sidecar.
- **GitHub orgs/repos**: edit [github-creds/installations.json](./github-creds/installations.json)
  (one entry per org: `{ "org", "installation_id", "repos"?, "perms"? }`) and **rebuild** the
  github sidecar — it's baked into the image (a reviewed rebuild, not a `/workspace` mount). For
  a new org, install the App on it first and note its installation id. Consumers route per-org
  automatically (`git` by request path, `gh` by `-R`/cwd), so it's a config change, not code.

## Rebuilding (keep all services in one compose project)

The `creds-shelf` volume is shared **only within one compose project** (Docker names it
`<project>_creds-shelf`). **Rebuild from VS Code** ("Dev Containers: Rebuild Container"), which
recreates the workspace + both sidecars in one project. A bare `docker compose up -d` from the
host outside that project would create an orphaned sidecar on a different volume the workspace
can't read. After a rebuild the `admin-home` volume may be fresh, so re-run `aws sso login` once.

## Change discipline

These `.devcontainer` files are on the agent-writable `/workspace` mount; changes take effect
only when a **human rebuilds/recreates** the containers — so review the diff of this directory
before any rebuild. Note `.vscode/settings.json` and `devcontainer.json` can apply on a window
**reload** (a lower bar than rebuild) — review them before *reloading*, not only rebuilding.
