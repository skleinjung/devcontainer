# Security model & threat landscape

This document is the "at a glance" map of what this devcontainer defends against, **how** it does
so, and — just as importantly — **what it does not defend against and why**. For the mechanics of
the credential system see [README.md](./README.md); this doc is the threat model around it.

Legend for implementation status:

- **✅ Current** — implemented and shipping.
- **⏳ Future (#N)** — planned, tracked in the linked issue, **not yet in effect**.
- **➖ Out of scope** — deliberately not addressed here (see [Out of scope](#out-of-scope)).
- **♾️ Structural** — not fully fixable within this architecture; mitigated, not eliminated.

## Core assumption

> **Processes running as our uid in the workspace container are NOT trusted.**

That includes LLM coding agents (the original motivation), but equally: malicious or compromised
**npm/pip/cargo packages**, **VS Code extensions**, build scripts, and any other code that can
execute or write files as the workspace user. The design does **not** rely on "the agent is
well-behaved." It assumes hostile code already runs as our uid and limits what that buys an
attacker.

A direct corollary, which drives most decisions below: **within a single uid there is essentially
no isolation.** Same-uid processes can read each other's `/proc/<pid>/environ`, connect to each
other's unix sockets, and read/modify each other's files. We therefore do **not** try to isolate
trusted from untrusted code *inside* the workspace uid — we keep anything powerful *out* of that
uid entirely.

## Trust tiers (concentric)

| Tier | Runs | Trust | Holds |
|------|------|-------|-------|
| 1. **Windows desktop** | VS Code desktop client + SSH agent (one FIDO hardware key) | Identity anchor | No source, no cloud creds, no secrets — just the hardware key + the client |
| 2. **External Linux host** | VS Code remote server, Docker daemon | Trusted host | The Docker daemon here is a real boundary (root-equivalent) |
| 3. **`admin-sidecar` container** | Human's privileged env | Trusted | SSO session, GitHub App signing (KMS), `lpass`/`ansible`/`terraform` |
| 4. **`workspace` container** | Agents + untrusted code | **Untrusted** | Only short-lived, scoped, *vended* credentials |

The two boundaries that carry the security weight: **(3) admin ↔ (4) workspace**, and **(4)
workspace ↔ everything above it** (host + desktop).

## Required invariants (customization checklist)

If you customize this container, **do not change any of the following without understanding the
consequence noted** — each is load-bearing for the model below. Grouped by where it lives. (✅ =
current; ⏳ #N = target state once that issue lands — don't regress *toward* the insecure side.)

**`devcontainer.json` → `customizations.vscode.settings`**

| Setting | Required value | Why |
|---|---|---|
| `git.useIntegratedAskPass` | `false` | Stops the git extension injecting `GIT_ASKPASS` (the OAuth-token askpass path) |
| `remote.containers.gitCredentialHelperConfigLocation` | `"none"` | No host-credential-proxy helper bridging the host's stored git creds in |
| `remote.containers.copyGitConfig` | `false` | Don't copy host `~/.gitconfig` + `.git-credentials` (plaintext token, `credential.helper`, `signingkey`) into the container |
| `dev.containers.dockerCredentialHelper` | `false` | No VS Code-injected docker credential helper |

**`devcontainer.json` → `remoteEnv`**

- **MUST blank (`""`):** `GIT_ASKPASS`, `VSCODE_GIT_IPC_HANDLE`, `VSCODE_GIT_ASKPASS_MAIN`,
  `VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_EXTRA_ARGS`, `VSCODE_IPC_HOOK_CLI`, `BROWSER`,
  `GPG_AGENT_INFO` — neutralize VS Code's host-reaching channels for spawned (agent) processes.
  *(Interactive terminals also need the shell scrub — VS Code re-injects there; see the two-layer
  note.)*
- **MUST NOT blank:** `SSH_AUTH_SOCK` — kept for SSH-remote git; safe only via FIDO hardware touch
  (see operational invariants).

**`devcontainer.json` → `containerEnv`**

| Var | Required | Why |
|---|---|---|
| `AWS_SHARED_CREDENTIALS_FILE` | `/creds/aws/credentials` | Agents read the vended shelf credentials |
| `GH_DEFAULT_ORG` | a **vended** org | Default GitHub token when no repo context pins an org |
| `AWS_PROFILE` | **must NOT be set to an SSO profile** | Would override the shelf `[default]` and bypass the vended role |

**`docker-compose.yml` → workspace service**

| Item | Required | Why |
|---|---|---|
| `creds-shelf` mount | **`:ro`** in workspace | Read-only shelf — agents can't tamper with or forge vended creds |
| admin-sidecar home volume | **never** mounted into workspace | The powerful creds (SSO session, KMS signing) stay out of the untrusted uid |
| Docker socket | **never** mounted (`/var/run/docker.sock`) | A writable socket is root-equivalent on the host — voids every boundary |
| `privileged` | **never** `true` | Privileged ⇒ trivial host escape |
| `cap_add: SYS_PTRACE` / `ptrace_scope` | **never add** SYS_PTRACE; keep `ptrace_scope ≥ 1` | Protects in-memory Settings-Sync/Copilot tokens from heap scraping (✅) |
| `network_mode` / `ipc: host` | **never** set (use bridge) | Host net/ipc would give the agent the host's network/IPC namespace (✅) |
| `cap_drop: [ALL]` + `no-new-privileges:true` + no sudo grant | keep all three | In-container root power, credential-tooling tampering, setuid escalation — `no-new-privileges` also disables sudo (✅) |
| `entrypoint: workspace-entrypoint` | keep | Reaps `vscode-{ipc,git}-*.sock`; needs `overrideCommand:false` (devcontainer.json) or VS Code replaces it (✅) |

**git / credential config**

| Item | Required | Why |
|---|---|---|
| github.com `credential.helper` | `git-credential-shelf` only | Routes to the scoped shelf token; persists nothing |
| `credential.helper store` | **never configure** | Would write a plaintext `~/.git-credentials` token sink readable by any same-uid process |

**Operational (not config, but must hold)**

- **Do not authorize the GitHub *git* OAuth session** in VS Code (don't "Publish to GitHub" / git
  sign-in). Settings Sync + Copilot are fine — they don't create that session. *(The askpass
  socket residual: with no session there's nothing to vend.)*
- **Never add a non-touch SSH key** to the forwarded agent — its entire safety is the hardware
  touch.
- **Review `.devcontainer/` *and* `.vscode/settings.json` diffs before window *reload* and
  rebuild** — they're bind-mounted, agent-writable, and some apply on reload.
- **Keep the vend config (`admin-sidecar/github-installations.json`) baked into the image**, not
  bind-mounted from `/workspace` — so changing vend scope requires a human rebuild.

## Required discipline (the human's responsibilities)

The invariants above are static config. These are the ongoing human actions the model depends on —
because the architecture confines **credentials**, it does **not** stop you from running code an
agent wrote, or from approving a prompt an agent induced. Those gaps are closed by you.

**Applying agent-authored changes**

- **Review diffs before executing anything with elevated privilege in the admin sidecar.** The
  sidecar mounts `/workspace` (agent-writable) and holds your real SSO session — `terraform apply`,
  `ansible`, `pnpm deploy`, `lpass`, etc. run there as *you*, on whatever an agent wrote. The
  boundary protects your credentials, not you from applying unreviewed code. Pattern: **agents
  prepare, humans review-and-apply.**
- **Verify before any hard-to-reverse / outward-facing action an agent set up** — merging a PR it
  opened, pushing, deploying, destroying. The vended token *can* do these within its scope; that
  it *should* is yours to confirm.

**Before window reload / rebuild**

- **Review `.devcontainer/`, `.vscode/settings.json`, and `devcontainer.json` diffs first.** They
  are bind-mounted and agent-writable; settings apply on **reload**, container config on rebuild. A
  poisoned `remote.extensionKind` here is the extension-host RCE path (see [#5]).

**Prompt vigilance (an agent can induce these)**

- **Never approve a YubiKey touch you didn't initiate.** An agent can trigger an SSH / commit-sign
  operation that pops a touch prompt; a reflexive touch authorizes it.
- **Don't authorize the VS Code GitHub *git* sign-in** ("Allow extension 'GitHub' to
  authenticate" / "Publish to GitHub") — activity in the container can summon that consent, and
  approving it arms the askpass-socket token leak. Settings Sync + Copilot are fine.

**Credential scoping (when you change what's vended)**

- **Scope deliberately, least-privilege.** Adding an installation to `github-installations.json`, a
  role to `VEND_AWS_PROFILES`, or widening `VEND_GH_REPOS` / `VEND_GH_PERMS` chooses the agent's
  blast radius. The system keeps tokens scoped and ≤1h; *which* scope is your call — prefer
  per-repo / per-permission narrowing, and don't grant `admin` / `delete_repo` / org-wide unless a
  task genuinely needs it. *(Deciding least privilege is otherwise [out of scope](#out-of-scope).)*
- **Keep the SSO session no broader or longer-lived than needed** — it's the human gate; re-auth on
  demand rather than holding a broad standing session.

**Workspace hygiene**

- **Treat everything in the workspace as potentially hostile** — packages, extensions, agent
  output. Don't install untrusted VS Code extensions into it, and remember the desktop-bridged
  container has an unfixed host-RCE path (see [#5]): opening a fully untrusted repo in it puts that
  code on your workstation's trust boundary.
- **No production secrets in the workspace** (`.env`, etc.) — dev-only; anything an agent can read
  it can exfiltrate within its (accepted) blast radius.

[#5]: https://github.com/skleinjung/.devcontainer/issues/5

## Boundary 1 — admin ↔ workspace (the credential architecture)

**Motivation:** the powerful credentials (the human's full SSO session, which can mint *any* AWS
role; the GitHub App signing key) must never be reachable by untrusted workspace code. Since
same-uid offers no isolation, the only durable answer is to put them in a **different container**.

**Enforcement (✅ Current):**

- The `admin-sidecar` holds the SSO session and the KMS-signing capability. Its home volume is
  **never mounted** into the workspace.
- It **vends** only narrow, short-lived credentials onto a `/creds` shelf: AWS role credentials
  (≤1h, the `developer-ai-agent` role) and per-org GitHub App installation tokens (≤1h, scoped to
  named repos). The workspace mounts `/creds` **read-only**.
- The workspace has **no `kms:Sign`** and **no SSO session** — it cannot mint or widen anything;
  it can only read what's on the shelf.
- The workspace has **no Docker socket** — a writable `docker.sock` is root-equivalent on the host
  and would void every boundary here.
- Escalation is human-shaped: a person vends something broader from the sidecar, time-boxed.

**What this deliberately does *not* protect:** an agent fully controls the scoped credentials it's
given (it can use them, and exfiltrate them over the network). That's accepted — they're scoped
and short-lived by design. The guarantee is *blast radius*, not *secrecy of the vended token*.

## Boundary 2 — workspace ↔ host/desktop (VS Code's secret↔process channels)

VS Code's remote model bridges a surprising number of host credentials and capabilities into the
container. Each is a channel an untrusted workspace process could ride. Enumerated:

| Channel | What it exposes | Control | Status |
|---|---|---|---|
| **git askpass / OAuth** (`GIT_ASKPASS`, `VSCODE_GIT_IPC_HANDLE` socket) | The human's VS Code GitHub **OAuth token** (`repo`+`workflow` — owner-scoped) once the *git* session is authorized | `git.useIntegratedAskPass:false` + `remoteEnv` blanks the vars; the socket (`vscode-git-*.sock`) is **reaped** by the entrypoint | ✅ + ♾️ |
| **host-credential-proxy** (injected git `credential.helper`) | The host's *stored* git credentials | `remote.containers.gitCredentialHelperConfigLocation:none` | ✅ |
| **host gitconfig copy** | Host `~/.gitconfig` + `.git-credentials` (plaintext token, `credential.helper`, `signingkey`) | `remote.containers.copyGitConfig:false` | ✅ |
| **`code` CLI / IPC** (`VSCODE_IPC_HOOK_CLI`, `vscode-ipc-*.sock`) | `code` against the host — incl. `--install-extension` (a bootstrap into the extension host / RCE) and `--openExternal` | `remoteEnv` blanks the var; the socket (`vscode-ipc-*.sock`) is **reaped** by the entrypoint | ✅ + ♾️ |
| **`BROWSER`** | openExternal launches host browser/handler (phishing, OAuth redirect abuse) | `remoteEnv` blanks it | ✅ |
| **`GPG_AGENT_INFO`** | Host GPG agent (sign, passphrase-phish via pinentry) | `remoteEnv` blanks it (we don't use GPG) | ✅ |
| **SSH agent** (`SSH_AUTH_SOCK` socket) | Host SSH keys — enumerate (`ssh-add -L`), authenticate to other hosts, SOCKS-pivot | **Left enabled**; safe only because keys are **FIDO/touch-gated** | ♾️ (see below) |
| **Settings Sync / Copilot tokens** | The human's GitHub token for those features | **Not reachable** — stored client-side; the container copy is in-memory in the ext-host process, protected by `ptrace_scope=1` | ✅ (verified empirically) |

**The IPC-socket residual (♾️) and the reaper:** the git and CLI extensions stay enabled (for the
Source Control UI and editor integration), so VS Code keeps recreating `vscode-git-*.sock`
(askpass/OAuth + git-editor) and `vscode-ipc-*.sock` (the `code` CLI). These sockets have **no
caller authentication** — any same-uid process can connect, *regardless of the blanked env var*.
Two layers handle them: `remoteEnv`/the shell scrub hide the *pointers*, and the container
**entrypoint reaps the sockets themselves** every 2s (`scripts/container/workspace-entrypoint`,
wired via the compose `entrypoint`; it deliberately spares `vscode-remote-containers-*.sock` and
`vscode-ssh-auth-*.sock`). The reaper is **defense-in-depth, not a wall** — VS Code recreates the
sockets and there's a brief window before the next sweep; it's a race, as the source research
notes. So the real guarantees remain upstream: **do not authorize the GitHub *git* session in VS
Code** (with no session the git socket has nothing to vend), and the extension-host RCE class
(#5) is unfixed regardless (an agent can poison an on-disk extension, not just `--install-extension`).
Settings Sync and Copilot do **not** create the git session; only an explicit git sign-in / "Publish to
GitHub" does. Empirically demonstrated: with the git session authorized, an agent silently pulled
a live `repo`+`workflow` token from the socket; with it not authorized, the socket returns nothing.

**Two-layer env neutralization (both required):** `remoteEnv` blanks these vars for the processes
VS Code spawns — which covers the **agent path** (non-interactive `bash -c`), *verified*: an agent
shell's exec-time `/proc/self/environ` has none of them. But VS Code **re-injects**
`VSCODE_GIT_IPC_HANDLE` / `VSCODE_IPC_HOOK_CLI` / `BROWSER` into **integrated terminals** via its
terminal `EnvironmentVariableCollection`, *overriding* `remoteEnv` there (`GIT_ASKPASS` is the
exception — `useIntegratedAskPass:false` stops its re-injection). So `remoteEnv` is **not**
sufficient alone for interactive terminals; the build-time shell scrub
(`/etc/profile.d/50-scrub-vscode-git-auth.sh` + a `/etc/bash.bashrc` include, baked into the
image) is what cleans them, and it matters because anything launched *from* a human's integrated
terminal (including an agent started by typing `claude`) inherits that terminal's env. Both layers
are load-bearing — `remoteEnv` for spawned/agent processes, the scrub for interactive terminals.
*(Verify after any rebuild: in a fresh terminal, `tr '\0' '\n' < /proc/$$/environ | grep -E
'^(VSCODE_GIT_IPC_HANDLE|VSCODE_IPC_HOOK_CLI|BROWSER)='` reads the exec-time env underneath the
scrub — non-empty there means VS Code is still re-injecting and the scrub is doing real work.)*

**Why `ptrace_scope` matters:** the Settings Sync / Copilot tokens live in the extension-host
process heap. They are not on disk and not in env/args (verified). They're protected from a
sibling agent only by yama `ptrace_scope ≥ 1` (blocks `/proc/<pid>/mem` of non-descendants).
**Invariant: the workspace container must never run with `ptrace_scope=0`, `--privileged`, or
`CAP_SYS_PTRACE`** — any of those re-opens heap scraping.

## Boundary 2 — host RCE via the extension host (♾️ Structural, ⏳ #5)

The deepest risk, and the one this architecture **cannot fully close**: a **workspace extension**
runs in the container's extension host and can call host-only VS Code commands over the
client↔server RPC bridge — `workbench.action.terminal.newLocal` + `sendSequence` ⇒ **arbitrary
shell on the desktop**; `openExternal`; clipboard read/write. Our agent doesn't run as an
extension, but it can **write files** — poison an installed extension's JS
(`~/.vscode-server/extensions/.../*.js`, same-uid-writable) or coerce `remote.extensionKind` via
the bind-mounted `.vscode/settings.json` / `.devcontainer/devcontainer.json` — and on the next
**window reload** the poisoned code runs in the ext host with host reach. This **bypasses all
credential isolation** because it executes on the human's workstation.

It's bridge-model-inherent. The only real mitigations are architectural and **not yet decided**
(⏳ [#5](https://github.com/skleinjung/.devcontainer/issues/5)): use the **web client**
(`code serve-web`) or **VSCodium** (neither ships the desktop TerminalService the RCE depends on),
or run the agent **headless** (no trusted desktop client attached). Today this is **documented,
not mitigated**.

Related discipline (✅ Current): `.vscode/settings.json` and `.devcontainer/` are agent-writable
and some settings apply on **window reload**, not just rebuild — review changes to them before
*reloading*, not only before rebuilding.

## Container isolation (✅ #4)

The workspace container is isolated at the OS level (done in
[#4](https://github.com/skleinjung/.devcontainer/issues/4)):

- **Bridge networking** (no `network_mode`/`ipc: host`) — the agent does not share the host's
  network or IPC namespace; this also closes the SSH-agent SOCKS/LAN-pivot half of the
  forwarded-agent attack. `host.docker.internal` still reaches host services; VS Code forwards
  container ports over the existing tunnel.
- **`cap_drop: [ALL]` + `security_opt: no-new-privileges:true` + no sudo grant** — no Linux
  capabilities, no setuid privilege escalation (which also makes sudo non-functional, so it's
  simply not granted). An agent is an ordinary unprivileged user that cannot tamper with the
  root-owned credential tooling (`/usr/local/bin/git-credential-shelf` etc.).

Because the container can no longer `sudo` at runtime, all privileged setup (system gitconfig,
the interactive-terminal scrub, pandoc) is baked into the **Dockerfile** at build time.

## Things we could do but deliberately aren't

- **Disable extensions that require GitHub auth (Copilot, etc.)** — kept. Their tokens are not
  agent-reachable (client-side + `ptrace_scope`), so the cost isn't justified.
- **Clear / disable `SSH_AUTH_SOCK`** — kept. It's the forwarded FIDO agent, hardware-touch-gated
  (silent key use fails), and the human uses it for SSH-remote git. Invariant: **never add a
  non-touch SSH key**; be wary of unexpected touch prompts (an agent can trigger them).
- **`git.enabled:false`** (never create the git socket) — kept enabled for the Source Control UI;
  instead the entrypoint *reaps* the socket (and the `code`-CLI socket) and we rely on "don't
  authorize the git OAuth session." Reaping is a race; `git.enabled:false` would be airtight for
  the git socket but costs the SCM UI.
- **Make `~/.vscode-server/extensions` read-only / integrity-checked** — under consideration for
  #5, not done.
- **Network egress allowlisting** — see Out of scope.

## Out of scope

This doc covers the **plumbing** that confines untrusted workspace code. It does **not** cover:

- **Least-privilege *policy*** — i.e. *how to decide* what an agent role or GitHub App token
  should actually be scoped to. This doc ensures tokens are scoped and short-lived; choosing the
  right scopes/repos/permissions is a separate discipline.
- **Network security** — egress filtering, firewalls, DNS controls. Dev needs broad internet
  access; we accept it. (A scoped agent token exfiltrated over the network is in-scope-accepted,
  per Boundary 1.)
- **Hardening of the external Linux host or the Windows desktop** themselves (OS patching,
  account hardening) — assumed, not enforced here.
- **Supply-chain scanning** — malicious packages are in the *threat model* (as untrusted code),
  but we do not scan/pin/sandbox dependencies here.
- **Physical security** and key-management lifecycle (YubiKey provisioning, KMS key rotation).

## Summary: what an attacker who fully controls the workspace uid gets

- ✅ **Cannot** reach the human's SSO session, mint arbitrary AWS roles, or sign GitHub App JWTs
  (those live in the sidecar).
- ✅ **Cannot** read the host's git/Settings-Sync/Copilot credentials (channels blanked; tokens
  client-side / ptrace-protected).
- ✅ **Can** use — and exfiltrate — the scoped, ≤1h shelf credentials it was vended (accepted;
  blast-radius-limited).
- ♾️ **Can**, if the human has authorized the VS Code git OAuth session, pull that owner-scoped
  token from the askpass socket → so **don't authorize it**.
- ♾️ **Can**, by writing files + a window reload, achieve **RCE on the desktop** via the extension
  host → mitigated only by future workflow changes (⏳ #5).
- ✅ **Cannot** escalate within the container (no caps, no-new-privileges, no sudo) or reach the
  host's network/IPC namespace (bridge networking) — #4.

## Sources & references

**Research / write-ups that informed this model**

- Daniel Demmel, *Coding agents in secured VS Code dev containers* —
  <https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers> (env-var
  clearing, aggressive socket deletion, `cap_drop`/`no-new-privileges`/no-sudo, socket-proxy).
- The Red Guild, *Leveraging VSCode internals to escape containers* —
  <https://blog.theredguild.org/leveraging-vscode-internals-to-escape-containers/> (the
  extension-host → host RCE chain via `TerminalService`, gitconfig/`.git-credentials` copy,
  SSH/GPG agent forwarding attacks, `remoteEnv`/`copyGitConfig` mitigations).
- Cycode, *VS Code's Token Security* —
  <https://cycode.com/blog/exposing-vscode-secrets/> (`state.vscdb` + Electron `safeStorage`,
  `secret://` keys — i.e. where SecretStorage persists *on the client*).

**VS Code official documentation**

- Supporting Remote Development & Codespaces (extensionKind ui/workspace; "SecretStorage always
  stores on the client side") — <https://code.visualstudio.com/api/advanced-topics/remote-extensions>
- Sharing Git credentials with your container —
  <https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials>

**VS Code source & issue tracker**

- `extensions/git/src/askpass.ts` (the askpass IPC server — no caller auth) and
  `askpass-main.ts` — <https://github.com/microsoft/vscode/blob/main/extensions/git/src/askpass.ts>
- DeepWiki: VS Code Git extension (IPCServer for askpass + git-editor) —
  <https://deepwiki.com/microsoft/vscode/5.2-git-extension>
- `microsoft/vscode-remote-release#4426` — `gitCredentialHelperConfigLocation:none` still copies
  the credential (why `copyGitConfig:false` is also needed) —
  <https://github.com/microsoft/vscode-remote-release/issues/4426>
- `microsoft/vscode-remote-release#5500` — disabling the git helper in remote —
  <https://github.com/microsoft/vscode-remote-release/issues/5500>
- `microsoft/vscode-discussions#748` — where extension secrets are stored —
  <https://github.com/microsoft/vscode-discussions/discussions/748>

**Empirical findings (from this container, not external sources)**

These were established by direct inspection and are the basis for several claims above:

- `github-authentication` / `microsoft-authentication` extension `package.json`:
  `extensionKind: ["ui","workspace"]` (runs client-side when a desktop client is attached).
  *(`~/.vscode-server/bin/<commit>/extensions/github-authentication/package.json`)*
- The built-in `github` extension requests session scopes
  `["repo","workflow","user:email","read:user"]` — the `repo`+`workflow` owner exposure.
  *(`.../extensions/github/dist`)*
- `askpass-main.js` connects to `VSCODE_GIT_IPC_HANDLE` and POSTs `JSON.stringify(...)` with **no
  nonce / no `SO_PEERCRED`** — the socket trusts the uid, not the caller.
- No token material found on disk (`~/.vscode-server`, `~/.config`); no keyring/Secret Service in
  the container (`DBUS_SESSION_BUS_ADDRESS` unset) ⇒ server-side secrets are in-memory only.
- `ptrace_scope = 1`; `/proc/<ext-host-pid>/mem` read **denied** ⇒ heap not scrapeable by a
  sibling agent.

**Related internal context**

- [README.md](./README.md) — credential-system mechanics, lifecycles, troubleshooting.
- Hardening PRs/issues: #3 (VS Code credential channels — this doc ships with it),
  [#4](https://github.com/skleinjung/.devcontainer/issues/4) (container isolation),
  [#5](https://github.com/skleinjung/.devcontainer/issues/5) (extension-host RCE posture).
- Original design context: [twin-digital/opus#164](https://github.com/twin-digital/opus/issues/164).
