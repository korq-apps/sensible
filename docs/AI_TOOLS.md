# AI tools and CLI follow-ups

Status: **manual chapter shipped; no AI client is installed**. Originally
recorded 2026-09-06; ticket links added 2026-09-10; upstream re-verified
2026-10-02 and the [curated manual chapter](#delivered-the-ai-tools-manual-chapter)
added then. No AI client, provider account, model weights or new repository is
added to any image by this plan. The upstream availability recorded before
2026-10-02 was a dated starting point; the table and verification log below
supersede it.

## Intent and proposed delivery

Provide a small, explained selection for both GNOME and KDE, with the same
terminal capabilities in each edition. Teach users how to choose a tool,
not just how to install a list of overlapping coding agents.

Proposed: evaluate OpenCode as the first preinstalled open-source client,
and LLM as a complementary general-purpose CLI. Other agents and proprietary
desktop clients remain optional, online, post-install choices. **Whether to
preinstall this small core or keep all AI tools opt-in is still a user decision.**
The current image remains unchanged until selection and packaging are approved.

An open-source **client** does not make its model or hosted service open source,
free of charge, private or offline. A terminal application can still send files
and prompts to a cloud provider. Local inference needs a separately selected
runtime and model, with their own resource needs and licenses.

## Curated shortlist

These are candidates, not a promise to bundle every tool. Exact redistribution
licenses and dependency notices must be recorded for the selected versions.

| Tool | Why consider it | Client category and proposed delivery |
| :--- | :--- | :--- |
| [OpenCode](https://opencode.ai/docs/) | Terminal coding agent; first candidate requested for Sensible | [Open-source client](https://github.com/anomalyco/opencode); evaluate pinned Linux artifact for the small core |
| [LLM](https://llm.datasette.io/en/stable/setup.html) | General prompting and command-line workflows beyond editing a repository | [Open-source client](https://github.com/simonw/llm); evaluate as the core's complement, including Python environment and provider-plugin costs |
| [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) | Repository inspection, edits and command execution from the terminal | [Open-source CLI](https://learn.chatgpt.com/docs/open-source); curated optional alternative, distinct from the desktop app and hosted services |
| [Antigravity CLI](https://antigravity.google/docs/cli/install) | Google's current agent-first terminal client, and Gemini CLI's successor | Open-source client; optional, installs to `~/.local/bin/agy` |
| [Aider](https://aider.chat/docs/install.html) | An alternative terminal pair-programming workflow | Open-source client; optional isolated Python installation |
| [Claude Code](https://code.claude.com/docs/en/installation) | Anthropic's Linux-supported coding CLI | Proprietary: its [license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md) reserves rights and refers to commercial terms; optional official installation, no redistribution assumed |

**Gemini CLI is no longer a consumer candidate.** Google
[replaced Gemini CLI with Antigravity CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli)
for Google AI Pro, Ultra and free Gemini Code Assist accounts on 2026-06-18;
requests from those accounts are no longer served. Gemini CLI remains
documented only for enterprise and paid Gemini API-key use, installed from
`npm install -g @google/gemini-cli` and removed with
`npm uninstall -g @google/gemini-cli`. The manual chapter therefore documents
Antigravity CLI and mentions Gemini CLI as a migration note, not as an entry.

For image candidates, prefer a suitable Debian Testing package; otherwise
evaluate a pinned upstream artifact. For optional tools, document the official
maintained installation route rather than promising that every CLI is an APT
package. Claude Code offers an official APT repository and the
`claude-code` package; its executable is `claude`. Python tools need an isolated
environment, not `sudo pip` or changes to Debian's system Python.

## Upstream verification log, 2026-10-02

Checked against the vendors' own documentation and, where the tool is a
downloadable client, installed and removed in a disposable Debian Testing
(forky) container on x86_64. No account, API key or paid service was used, so
no sign-in, session, price or quota claim was made.

| Entry | Debian Testing package | Verified upstream route | What was exercised |
| :--- | :--- | :--- | :--- |
| OpenCode | none | `curl -fsSL https://opencode.ai/install \| bash` → `~/.opencode/bin/`, PATH line added to `~/.bashrc` | install, `opencode --version` 1.18.34, ~180 MiB |
| LLM | `llm` 0.36-1 (46 packages) | `sudo apt install llm`, or `pipx install llm` for the newer upstream release | both routes, `llm --version`, system Python 3.14.7 unchanged |
| Codex CLI | none | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` → `~/.local/bin/codex` into `~/.codex/`, PATH line in `~/.profile` | install, `codex --version` 0.160.0, ~430 MiB |
| Antigravity CLI | none | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` → `~/.local/bin/agy`, no profile edit | install, `agy --version` 1.2.15, ~200 MiB |
| Gemini CLI | none | `npm install -g @google/gemini-cli` (consumer access withdrawn 2026-06-18) | documentation only |
| Aider | none | `sudo apt install pipx` → `pipx install aider-install` → `aider-install` | install, `aider --version` 0.86.2, system Python unchanged |
| Claude Code | none | signed APT repo `https://downloads.claude.ai/claude-code/apt/stable`; key fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE` | key fingerprint, `apt install claude-code`, `claude --version` 2.1.285, ~230 MiB, removal left repo file and key behind |
| ChatGPT desktop | `chatgpt` 26.930.21537 from the `.deb` | `sudo apt install ./chatgpt_amd64.deb`; vendor lists Ubuntu 24.04/26.04, Debian 13, Fedora 43/44, Arch — **not** Debian Testing | download, install (~1.5 GiB), `chatgpt.sources` and keyring registration, `chatgpt --version`, removal left keyring, AppArmor profile, source entry and `/etc/default/chatgpt` behind |
| Claude Desktop | `claude-desktop` 2.9939.4 from Anthropic's APT repo | official Linux beta; Debian 12+/Ubuntu 22.04+ (Testing meets it, untested upstream) | key fingerprint, dependency resolution on Testing (~560 MiB, recommends QEMU set and a keyring), removal semantics of its `postrm` inspected |

On 2026-10-03, the installed ChatGPT and Claude desktop entries were also
launched through GNOME's application launcher on a Wayland session. Both
processes initialized and were then closed; no prompt or sign-in workflow was
performed. KDE launch remains untested, as does Claude Desktop package removal.

Findings that changed earlier notes:

- **Claude Desktop now has an official Linux beta.** The earlier "unavailable on
  Linux" statement is obsolete; the current status, requirements, keyring
  conflict on KDE and Cowork's KVM requirement are recorded in the chapter.
  Do not present an unofficial wrapper as the official client.
- **The ChatGPT desktop `.deb` registers a repository** at
  `/etc/apt/sources.list.d/chatgpt.sources` with a keyring, an AppArmor profile
  and `/etc/default/chatgpt`; `apt remove` leaves all of them behind. The two
  Anthropic recipes also need `sudo apt install gnupg` first, because they show
  a `gpg --show-keys` fingerprint check and the images do not ship `gnupg`.
- **`pipx install aider-chat` fails on Debian Testing** because Aider's pinned
  `numpy==1.24.3` has no build for the system Python 3.14. `aider-install`
  inside a `pipx` environment works and is the documented route.
- **Codex CLI gained an official standalone Linux installer**; the npm and
  Homebrew routes remain.
- The chapter says what was tried. Sign-in, model calls, prices, quotas and
  KDE launch stay untested.

## Delivered: the AI tools manual chapter

`manual/ai-tools.html` ships the chapter that this plan used to specify. It
covers a selection guide, permissions and untrusted code, accounts/keys/billing,
the two desktop clients and the six terminal clients, an update-owner and
leftover-state table, and a dated statement of what Sensible did and did not
verify. Navigation, offline staging and the installer payload gate include it:
`scripts/stage-manual.sh`, `installer/lib/manual.sh`,
`tests/lib/check_manual.py` (chapter set plus cross-chapter navigation) and
`tests/unit/manual_test.sh`. The chapter is offline: no AI client, account,
model or vendor repository is part of an image. Each recipe says what was
tried, such as an install, a version check or a GNOME menu launch, and what
was not, including sign-in, model calls and KDE.

The chapter deliberately does not add any package to a live list, so
`tests/lib/check_manual.py`'s default-package coverage is unchanged, and its
`data-packages="gnupg"` markers document a package the recipes may install on
demand rather than one the image ships.

## Desktop installation guidance

The researched starting point for the desktop section, retained for provenance.
The current upstream position and what was exercised are in the verification
log above and in the chapter itself:

- **ChatGPT desktop:** OpenAI documents an official Linux preview with a `.deb`.
  Debian 13 is listed as supported; Sensible's Debian Testing base is not.
  Document downloading from the [official Linux page](https://developers.openai.com/codex/linux/linux-app),
  installing the downloaded package with APT, and signing in afterward.
  Explain that installation also configures OpenAI's signed update repository.
  Test GNOME/KDE launch, authentication, updates and removal before marking this
  a tested Sensible recipe. The preview does not provide Linux Computer Use;
  native Wayland is experimental. Offer the browser as a fallback.
- **Claude Desktop:** an official [Linux beta](https://code.claude.com/docs/en/desktop-linux)
  now exists and is installed from Anthropic's signed APT repository, so the
  earlier "unavailable on Linux" note is obsolete. It requires Debian 12+ or
  Ubuntu 22.04+ on x86_64 or ARM64, Testing meets that but is not officially
  tested, Cowork needs hardware virtualization with QEMU/KVM, and its sign-in
  conflicts with a second keyring on the KDE image. Recommend Claude in the
  browser as the simpler route. Do not silently substitute an unofficial Linux
  repackaging; that would require a separate provenance, licensing,
  credential-handling and update review.
- **Optional does not mean preconfigured:** these clients, their accounts and
  their vendor repositories are not part of the base image. Repository setup
  and downloads require an explicit post-install user action.

Each curated entry must explain why it was selected, when another tool is a
better fit, official installation steps, the launch command, one small usage
example, update/removal steps and troubleshooting. Say what was tried and
what was not, rather than assigning a status label. Keep links and a
verification date; do not hardcode subscription prices, quotas or model names
that quickly age.

Manual examples should use `~/` for home paths and explain any variables before
using them. Never put a real API key in a command, screenshot or example log.
Clarify account sign-in versus API-key billing: a chat subscription must not be
presented as automatically paying for arbitrary third-party API use.

## Packaging, privacy and acceptance requirements

- Keep installation and first login offline. Fetch approved image artifacts
  only at build time; pin version, source URL and checksum, validate package
  identity/architecture and retain licenses. Never run a floating upstream
  installer from the ISO or during first login.
- Resolve the complete runtime closure. Check that launch, help/version and a
  useful offline diagnostic work without downloading dependencies or models.
  Cloud-backed functionality is not an offline acceptance promise.
- Define one update owner per installation. A root-owned pinned binary must
  not silently self-update or instruct the user to run its agent as root.
  Provide a supported security-update path before bundling, including for
  already installed systems; a future ISO alone is insufficient.
- Do not bake in credentials, session history, provider selections or personal
  configuration. Sign-in happens only when the user chooses to use the tool.
  Document provider traffic, local history, telemetry controls and key removal.
- Use project-scoped permissions and meaningful approval prompts; no default
  unrestricted/auto-approve mode. OpenCode's [upstream permission defaults](https://opencode.ai/docs/permissions/)
  allow most operations, so safe Sensible defaults require explicit evaluation,
  not an assumption that installing an agent also sandboxes it.
- Teach Git checkpoints, diff review and testing. Explain risks from commands,
  untrusted repository instructions and third-party plugins/MCP servers. No
  automatic plugin installation, privileged agent execution or broad home access.
- No model weights, background model downloads, inference daemons, login
  autostart or new firewall exceptions by default. Do not require an AI account
  to install or use Sensible normally.
- Test missing/corrupt artifacts, wrong versions/architecture, dependency
  failures and clear diagnostics. CI uses fixtures without paid accounts or
  secrets; separately record user-authorized live-service/session checks.
- Measure image size, build time and installed footprint. Test both editions,
  fresh-user settings, offline boot, update/removal and preservation of user
  overrides. Update current-state documentation only when evidence exists.

## Other command-line follow-ups

Keep the existing tools and their manual explanations. In particular, `jq`,
`ripgrep`, `fd-find`, `fzf`, `bat`, `eza` and `zoxide` are already included.

- Evaluate [tmux](https://github.com/tmux/tmux/wiki) for persistent terminal
  sessions and split panes, with beginner recipes for attach/detach. Explain
  that sessions do not survive a reboot.
- Evaluate [tealdeer](https://tealdeer-rs.github.io/tealdeer/intro.html) (`tldr`)
  for short command examples. If included, verify whether a licensed, pinned
  page cache can be staged so first use works offline; explain cache refreshes.
- Evaluate [uv's isolated tool environments](https://docs.astral.sh/uv/guides/tools/)
  if the selected Python AI clients justify it. Choose one supported approach
  rather than adding multiple installers by default.
- Reuse the existing `gh` and `lazygit` developer-tools follow-up in
  [PLAN.md](PLAN.md); do not duplicate it or silently move Docker into the base.

## Proposed follow-up slices

The first three slices now have GitHub issues, linked below and grouped in
the [prioritization index (#28)](https://github.com/korq-apps/sensible/issues/28).
Local inference remains a later unticketed evaluation, not an approved default.
These scopes do not replace the existing release evidence requirements.
The [reconciled priority queue](PLAN.md#reconciled-priorities) sets the
cross-project order: further unattended automation is parked and user-facing
features take priority. Manual curation need not wait for a VM harness or the
optional-app tool, but automated optional AI installation must use the
[shared catalog (#24)](https://github.com/korq-apps/sensible/issues/24) rather than invent a second
installer. Its initial source adapters may not fit every AI CLI; add a reviewed
adapter or keep an official manual recipe instead of allowing arbitrary scripts.
The separate [editor follow-up (#26)](https://github.com/korq-apps/sensible/issues/26)
includes both Vim and Neovim without overriding
Debian's editor selection, with LazyVim configuration opt-in. It is not a
prerequisite for this AI scope and does not imply selecting an AI tool's editor
on the user's behalf.

1. **[Curated AI manual and optional client recipes (#23)](https://github.com/korq-apps/sensible/issues/23). Delivered 2026-10-02.** The AI chapter and
   navigation ship as `manual/ai-tools.html`, covering the shortlist,
   privacy/account distinctions and the current Linux desktop options. Manual
   staging, the payload check and the offline tests include the new chapter.
   Optional installation itself is online.
2. **[AI delivery decision and candidate packaging (#22)](https://github.com/korq-apps/sensible/issues/22).** Resolve the preinstall/opt-in decision,
   then package OpenCode and evaluate LLM against the requirements above.
   Include rationale, safe usage examples, update support and both-edition
   acceptance. Defer a candidate rather than waive an unmet packaging gate.
3. **[CLI usability (#25)](https://github.com/korq-apps/sensible/issues/25) and [developer-tool catalog (#24)](https://github.com/korq-apps/sensible/issues/24).** Evaluate tmux/tealdeer and the
   chosen Python tool mechanism; reconcile with the existing `gh`/`lazygit`
   plan. Provide examples and offline behavior tests for each accepted addition.
4. **Optional local inference.** Separately evaluate
   [llama.cpp](https://github.com/ggml-org/llama.cpp) and
   [Ollama](https://docs.ollama.com/linux). Select a runtime and model only after
   CPU/GPU, RAM/disk, licensing, download size, updates and removal checks.
   Any service must remain opt-in and local-only by default. Do not describe
   open weights as necessarily open-source software or promise laptop performance.
