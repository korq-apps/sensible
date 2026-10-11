# AI tools

Sensible ships an [offline AI tools manual](../manual/ai-tools.html) for
optional, user-installed clients. No AI client, provider account, model weights
or vendor repository is included in either image.

This document defines the delivery scope, packaging requirements and remaining
work. Installation, usage, privacy and removal instructions belong in the manual.

## Scope and delivery

Offer a small, explained selection for GNOME and KDE, with the same terminal
capabilities in both editions. OpenCode and LLM are candidates for possible
inclusion; **whether to preinstall them or keep all AI tools opt-in remains
undecided**. Other clients remain optional online installations.

An open-source client does not make its model or hosted service open source,
free, private or offline. Local inference requires a separately selected runtime
and model, with their own resource needs and licences.

## Client selection

All of these clients are currently optional. The linked manual entries contain
the installation instructions and vendor references.

| Client | Purpose |
| :--- | :--- |
| [OpenCode](../manual/ai-tools.html#opencode) | Coding agent with a choice of model providers; candidate for possible inclusion |
| [LLM](../manual/ai-tools.html#llm-cli) | General prompting and command-line workflows; candidate to complement a coding agent |
| [Codex CLI](../manual/ai-tools.html#codex) | OpenAI's terminal agent for repository inspection, edits and command execution |
| [Antigravity CLI](../manual/ai-tools.html#antigravity) | Google's terminal coding agent; the entry also explains the Gemini CLI migration |
| [Aider](../manual/ai-tools.html#aider) | Terminal pair programming with Git-based changes |
| [Claude Code](../manual/ai-tools.html#claude-code) | Anthropic's terminal coding agent |
| [ChatGPT desktop](../manual/ai-tools.html#chatgpt-desktop) | OpenAI's desktop client for local projects and files |
| [Claude desktop](../manual/ai-tools.html#claude-desktop) | Anthropic's desktop client for Chat, Cowork and Claude Code |

## Manual requirements

Each entry should explain its purpose, when another tool is a better fit,
official installation, launch and a small first task, updates, removal and
troubleshooting. Include vendor links and a verification date, and distinguish
documented behaviour from checks performed on Sensible.

Explain permissions, provider traffic, local history, telemetry controls and
credential storage and removal. Distinguish account sign-in, subscriptions and
API billing. Avoid fixed prices, quotas or model names that quickly become stale.

Examples should explain shell variables before using them, use home-relative
paths where appropriate, and keep credentials out of commands and logs.
Installation and cleanup instructions must account for shared settings,
repositories and files used by other applications.

## Validation status

The manual's [validation summary](../manual/ai-tools.html#limits) records each
client's install, version, launch and removal checks. These checks used Debian
Testing; they do not establish support for every client feature.

Both desktop clients were launched in GNOME. KDE launch and Claude Desktop
package removal remain untested. Sign-in, model calls, telemetry controls and
credential cleanup after a signed-in session have not been exercised. Package
removal alone does not establish that credentials or local data were cleared.

## Requirements for including a client in the image

- Prefer a suitable Debian Testing package. Otherwise pin the version, source
  and checksum, validate package identity and architecture, and retain licences
  and dependency notices.
- Fetch approved artifacts at build time and include their runtime dependencies.
  Installation and first login must work offline, without floating installers
  or background downloads. Cloud-backed functionality is not an offline promise.
- Define one update owner and a supported security-update path for installed
  systems. A root-owned binary must not silently self-update or require running
  the agent as root.
- Include no credentials, session history or personal provider configuration.
  Sign-in is a user choice; normal use of Sensible must not require an AI account.
- Evaluate project-scoped permissions and approval prompts. Explain risks from
  commands, untrusted repository instructions, plugins and MCP servers; do not
  enable unrestricted access or install plugins automatically.
- Add no model weights, inference daemons, login autostart or firewall exceptions
  by default. Local inference is a separate opt-in decision.
- Test artifact and dependency failures, both desktop editions, fresh-user
  settings, offline boot, updates, removal and preservation of user changes.
  Measure image size and installed footprint. Keep CI fixtures free of paid
  accounts and secrets, and distinguish them from live-session checks.

## Remaining work

- [Complete manual acceptance (#23)](https://github.com/korq-apps/sensible/issues/23):
  validate both desktop clients on KDE and the Claude Desktop removal path,
  then update the manual with the results.
- [Decide delivery and candidate packaging (#22)](https://github.com/korq-apps/sensible/issues/22):
  choose preinstallation or all-opt-in delivery, then evaluate OpenCode and LLM
  against the requirements above.
- Use the [shared optional-app catalog (#24)](https://github.com/korq-apps/sensible/issues/24)
  for any automated optional installation. Add a reviewed adapter when needed;
  clients without a suitable adapter can retain a manual recipe.
- Evaluate local inference separately: runtime and model licences, CPU/GPU
  support, memory and disk needs, download size, updates and removal. Any service
  must remain opt-in and local-only by default.

The [project plan](PLAN.md) tracks priorities and other command-line tools.
