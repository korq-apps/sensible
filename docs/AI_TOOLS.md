# AI tools and CLI follow-ups

Status: **planned, not implemented**. Recorded 2026-09-06. No AI client,
provider account, model weights or new repository is added by this plan.
Upstream availability below was checked on that date; installation recipes
must be rechecked and tested when their implementation lands.

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
| [Gemini CLI](https://geminicli.com/docs/get-started/installation/) | Another provider-oriented terminal agent | [Open-source client](https://github.com/google-gemini/gemini-cli); optional, with a compatible maintained Node.js runtime |
| [Aider](https://aider.chat/docs/install.html) | An alternative terminal pair-programming workflow | Open-source client; optional isolated Python installation |
| [Claude Code](https://code.claude.com/docs/en/installation) | Anthropic's Linux-supported coding CLI | Proprietary: its [license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md) reserves rights and refers to commercial terms; optional official installation, no redistribution assumed |

For image candidates, prefer a suitable Debian Testing package; otherwise
evaluate a pinned upstream artifact. For optional tools, document the official
maintained installation route rather than promising that every CLI is an APT
package. Claude Code currently offers an official APT repository and the
`claude-code` package; its executable is `claude`. Python tools need an isolated
environment, not `sudo pip` or changes to Debian's system Python.

## Desktop installation guidance

Create a dedicated **AI tools** manual chapter, with separate desktop and CLI
sections. The following is the researched starting point, not completed
Sensible compatibility testing:

- **ChatGPT desktop:** OpenAI documents an official Linux preview with a `.deb`.
  Debian 13 is listed as supported; Sensible's Debian Testing base is not.
  Document downloading from the [official Linux page](https://learn.chatgpt.com/docs/linux/linux-app),
  installing the downloaded package with APT, and signing in afterward.
  Explain that installation also configures OpenAI's signed update repository.
  Test GNOME/KDE launch, authentication, updates and removal before marking this
  a tested Sensible recipe. The preview does not provide Linux Computer Use;
  native Wayland is experimental. Offer the browser as a fallback.
- **Claude Desktop:** the [official desktop guide](https://code.claude.com/docs/en/desktop-quickstart)
  currently says it is unavailable on Linux. Recommend Claude in the browser,
  or Claude Code for terminal work. Explain optional browser shortcuts without
  presenting them as native Desktop/Cowork/MCP equivalents. Do not silently
  substitute an unofficial Linux repackaging; that would require a separate
  provenance, licensing, credential-handling and update review.
- **Optional does not mean preconfigured:** these clients, their accounts and
  their vendor repositories are not part of the base image. Repository setup
  and downloads require an explicit post-install user action.

Each curated entry must explain why it was selected, when another tool is a
better fit, official installation steps, the launch command, one small usage
example, update/removal steps and troubleshooting. Mark entries as included,
optional/tested, or candidate/unvalidated. Keep links and a verification date;
do not hardcode subscription prices, quotas or model names that quickly age.

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

These are issue-ready scopes, **not yet published GitHub issues**. They do not
replace the existing installer/release gate or pending desktop acceptance work.
The [reconciled priority queue](PLAN.md#reconciled-priorities) sets the
cross-project order: validated install input and acceptance infrastructure come
next. Manual curation need not wait for the optional-app tool, but automated
optional AI installation must use its shared catalog rather than invent a second
installer. Its initial source adapters may not fit every AI CLI; add a reviewed
adapter or keep an official manual recipe instead of allowing arbitrary scripts.
The separate editor follow-up includes both Vim and Neovim without overriding
Debian's editor selection, with LazyVim configuration opt-in. It is not a
prerequisite for this AI scope and does not imply selecting an AI tool's editor
on the user's behalf.

1. **Curated AI manual and optional client recipes.** Add the AI chapter and
   navigation; cover the shortlist, privacy/account distinctions and verified
   Linux desktop options. Update manual staging, payload checks and tests so
   the new chapter is available offline. Optional installation itself is online.
2. **Approved open-source CLI core.** Resolve the preinstall/opt-in decision,
   then package OpenCode and evaluate LLM against the requirements above.
   Include rationale, safe usage examples, update support and both-edition
   acceptance. Defer a candidate rather than waive an unmet packaging gate.
3. **CLI usability and developer-tool catalog.** Evaluate tmux/tealdeer and the
   chosen Python tool mechanism; reconcile with the existing `gh`/`lazygit`
   plan. Provide examples and offline behavior tests for each accepted addition.
4. **Optional local inference.** Separately evaluate
   [llama.cpp](https://github.com/ggml-org/llama.cpp) and
   [Ollama](https://docs.ollama.com/linux). Select a runtime and model only after
   CPU/GPU, RAM/disk, licensing, download size, updates and removal checks.
   Any service must remain opt-in and local-only by default. Do not describe
   open weights as necessarily open-source software or promise laptop performance.
