# Security model — this devcontainer

The security **patterns** — the trust model, the VS Code host-channel hardening,
container isolation, credential vending, the general discipline, and the research
sources — are the toolkit's, documented once in:

- **[devcontainers/docs/SECURITY.md](../devcontainers/docs/SECURITY.md)** — trust
  model, the workspace↔host channel hardening, container isolation, extension-host
  RCE, discipline, the attacker summary, invariants, and sources.
- **[devcontainers/docs/SECRETS.md](../devcontainers/docs/SECRETS.md)** —
  the credential contract (`devcred`, transports, naming).

This file records only what is **specific to this devcontainer** — its concrete trust
tiers, what it vends, its mounts, its setup-specific discipline, the concrete values of
the toolkit invariants, and where it currently deviates from the toolkit target. For
*why* any of it matters, follow the links above. Operational mechanics (first-run login,
troubleshooting) are in [README.md](./README.md).

---

## Concrete trust tiers

The toolkit's [tier *concept*](../devcontainers/docs/SECURITY.md#2-trust-tiers--the-concept),
instantiated here:

| Tier | Runs | Holds |
|------|------|-------|
| 1. **Windows desktop** | VS Code desktop client + SSH agent (one FIDO hardware key) | the hardware key + client — no source, creds, or secrets |
| 2. **External Linux host** | VS Code remote server, Docker daemon | the daemon is the root-equivalent boundary |
| 3. **credential sidecars** (`credentials-aws`, `credentials-github`) | trusted, **vend-only** | the SSO session + GitHub App signing (KMS) — and nothing else (no shells, no `lpass`/`ansible`/`terraform`) |
| 4. **`workspace` container** | agents + untrusted code | only short-lived, scoped, vended creds |

---

## What this devcontainer vends

- **AWS** (`credentials-aws`, image `credential-shelf-aws`): the `developer-ai-agent`
  role (≤1h) → `/creds/aws/credentials`; `base` points `AWS_SHARED_CREDENTIALS_FILE` at
  it. The full SSO session stays in the sidecar.
- **GitHub** (`credentials-github`, derived from `credential-shelf-github`): per-org
  GitHub App **installation tokens** (≤1h, scoped to named repos) → `/creds/github/<org>`.
  Which orgs/repos/perms are vended is **baked into the sidecar image** from
  `github-creds/installations.json`; the App signing key never leaves KMS.
- **Transport:** the read-only `/creds` **file shelf** — the same vended secrets for every
  consumer. (Per-consumer policy / on-demand broker is a toolkit target — see *Deviations*.)

The consumer side (`devcred` + the git/gh/aws shims that read the shelf) comes from `base`.

---

## Specific mounts & forwarded channels

- **Commit-signing key:** `~/.ssh/id_ed25519` (+`.pub`) mounted **read-only** — the
  commit-signing key *only*, not the whole `~/.ssh`.
- **`SSH_AUTH_SOCK`:** the forwarded FIDO/YubiKey agent (hardware-touch-gated). This setup
  **opts out of `base`'s default `SSH_AUTH_SOCK` scrub** (`SCRUB_SSH_AUTH_SOCK_ENABLED=false`)
  because it relies on the forwarded agent for SSH-remote git — safe *only* because the key
  is hardware-touch-gated. **Invariant: never add a non-touch key to it.**

---

## Discipline specific to this setup

The general discipline is in
[SECURITY.md §11](../devcontainers/docs/SECURITY.md#11-human-discipline-the-patterns-depend-on-these).
Specific to *this* setup:

- **Never approve a hardware-key touch you didn't initiate.** Agents here run as the
  workspace uid and can reach the forwarded FIDO agent — an agent can trigger an SSH or
  commit-sign operation that pops a touch prompt, and a reflexive touch authorizes it.
- **Privileged ops (`terraform`/`deploy`/`lpass`) don't run in a local sidecar.** The
  credential sidecars are **vend-only** — they hold the SSO session + KMS sign, nothing
  else, and don't mount `/workspace`. Run privileged applies in a controlled CI/CD
  environment, and review agent-authored diffs before they do ([the toolkit's
  "applying agent output re-crosses the boundary"](../devcontainers/docs/SECURITY.md#3-what-this-does-not-protect)).

---

## Concrete config invariants

The toolkit invariants
([§13](../devcontainers/docs/SECURITY.md#13-invariants-dont-regress-these)), with the
values this container must hold:

| Item | Required value |
|---|---|
| `AWS_SHARED_CREDENTIALS_FILE` | `/creds/aws/credentials` (set by `base`) |
| `AWS_PROFILE` | **must NOT** be set to an SSO profile (would bypass the vended `[default]`) |
| `GH_DEFAULT_ORG` | a **vended** org |
| `SCRUB_SSH_AUTH_SOCK_ENABLED` | `false` — keep the forwarded FIDO agent (see *Mounts*) |
| `creds-shelf` mount | **`:ro`** in the workspace |
| the sidecars' `admin-home` volume | **never** mounted into the workspace |
| `github.com` `credential.helper` | `devcred` (set by `base`) |
| compose `entrypoint` | `reap-vscode-sockets` (base's reaper) + `overrideCommand: false` |
| `github-creds/installations.json` | **baked into the `credentials-github` image**, not bind-mounted from `/workspace` |

---

## Deviations from the toolkit target

- **Two containers, not three.** This setup runs `workspace` + the two credential
  sidecars; the agent is **not yet** split into its own container, so agents run as the
  workspace uid alongside the dev. The toolkit target is the three-container agent
  isolation in
  [SECURITY.md §4](../devcontainers/docs/SECURITY.md#4-agent-isolation--separate-container-same-uid-mount-topology).
- **File shelf, not a broker.** Credentials are vended as read-only files (no per-request
  audit; same secrets for both consumers); the toolkit target is the on-demand broker in
  [SECRETS.md](../devcontainers/docs/SECRETS.md).

---

## Empirical findings (verified in *this* container)

Basis for several claims in the toolkit doc:

- `github-authentication`/`microsoft-authentication` `package.json`:
  `extensionKind: ["ui","workspace"]` (runs client-side with a desktop client attached).
- The built-in `github` extension requests scopes
  `["repo","workflow","user:email","read:user"]` — the `repo`+`workflow` exposure.
- `askpass-main.js` connects to `VSCODE_GIT_IPC_HANDLE` and POSTs with **no nonce / no
  `SO_PEERCRED`** — the socket trusts the uid, not the caller.
- No token material on disk (`~/.vscode-server`, `~/.config`); no keyring in the container
  (`DBUS_SESSION_BUS_ADDRESS` unset) ⇒ server-side secrets are in-memory only.
- `ptrace_scope = 1`; `/proc/<ext-host-pid>/mem` read **denied** ⇒ ext-host heap not
  scrapeable by a sibling agent.

---

## Issues / context

- [#3](https://github.com/skleinjung/.devcontainer/issues/3) — VS Code credential
  channels · [#4](https://github.com/skleinjung/.devcontainer/issues/4) — container
  isolation · [#5](https://github.com/skleinjung/.devcontainer/issues/5) —
  extension-host RCE posture.
- Original design context:
  [twin-digital/opus#164](https://github.com/twin-digital/opus/issues/164).
