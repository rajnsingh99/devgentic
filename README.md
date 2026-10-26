<p align="center">
  <img src="https://rajnsingh99.github.io/devgentic/assets/app-icon.png" alt="Devgentic app icon" width="128" height="128">
</p>

<h1 align="center">Devgentic</h1>

<p align="center"><strong>Local-first AI agents for your Mac</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Licence-AGPL_v3-blue.svg" alt="Licence: AGPL v3"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/Platform-macOS%2026.1%2B-lightgrey.svg" alt="Platform: macOS 26.1+"></a>
</p>

<p align="center">
  <a href="https://github.com/rajnsingh99/devgentic/releases/latest">Download</a> ·
  <a href="https://rajnsingh99.github.io/devgentic/">Website</a> ·
  <a href="https://github.com/rajnsingh99/devgentic/issues/new/choose">Report a bug</a> ·
  <a href="https://github.com/sponsors/rajnsingh99">Sponsor</a>
</p>

A native macOS app for building and running AI agents — locally where you want it, in the cloud where you need it.

You create **backend profiles**. Each one binds a model to a set of capabilities, and the app gives it somewhere to run: a chat window, a node-graph workflow canvas, a project-scoped coding interface, a global-hotkey panel, or a floating voice orb.

A developer's map of how the app is put together — components, key flows, persistence, security model — is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

> **Version 1.0.1.** Free software under the GNU AGPL v3 — see [Licence](#licence) — and please [read this first](#before-you-use-this).

## What it does

**Five profile types**, each a different shape of work:

| Profile | What it is |
|---|---|
| **Bot** | Plain LLM chat — a model, instructions, and optional knowledge sources. No tools. |
| **Agent** | A ReAct loop with tools, resilience settings, a history strategy, and optional Planning and Self-Reflection layers. |
| **Workflow** | A node graph — profile nodes, routers, code transforms, human-in-the-loop gates, triggers and actions — with per-node timeouts and context budgets. |
| **Image Generator** | Text-to-image, with a negative prompt and aspect ratio. |
| **Code** | A project-scoped agent with a fixed 16-tool preset for reading and editing a codebase. |

**Seven model backends.** `MLX` and `Ollama` run locally; `OpenAI`, `Anthropic`, `Google`, `OpenRouter` and any OpenAI-compatible endpoint run remotely. MLX models are browsed and downloaded in-app from the Hugging Face Hub.

**Tools.** Agent profiles can call 70 native macOS tools — filesystem, shell, git, code search and editing, Calendar/Reminders/Contacts, Safari, UI automation, network — plus anything exposed by a connected MCP server. Every tool call can be gated by a human-in-the-loop approval keyed to its risk tier.

**Surfaces beyond the main window.** A global-hotkey QuickAccess panel; **Orb**, a floating voice orb with wake-word or push-to-talk activation that speaks its answers back; a cron scheduler for unattended runs; and remote bridges for Slack, Discord and Telegram.

## Requirements

- **macOS 26.1** or later (the deployment target)
- **Xcode 26.2** — what the project is developed and built against
- **Apple Silicon** (arm64 only; there is no Intel build)

No package manager to install: dependencies are Swift Package Manager only, resolved by Xcode from a tracked `Package.resolved` (39 pins). Their licences are collected in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Build

```bash
xcodebuild -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS' build
```

Or open `Devgentic.xcodeproj` in Xcode and run the `devgentic` scheme.

> **Note the casing.** The targets and schemes are lowercase-first — `devgentic`, `devgenticTests` — while the source directories are capitalised (`Devgentic/`, `DevgenticTests/`). This matters for `-only-testing:`.

### ObjectBox code generation

There is **no build phase** for it. ObjectBox's generator is an SPM *command* plugin run by hand, and its outputs are committed — so a clean checkout compiles without running it.

You only need to re-run it after changing a property on an ObjectBox entity. Skipping it produces a confusing error at the new property's static query accessor ("instance member cannot be used on type"), not a missing-file error.

## Tests

```bash
# build once, then run what you care about
xcodebuild build-for-testing -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS'
xcodebuild test-without-building -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS' \
  -only-testing:devgenticTests/ToolRegistryDriftTests
```

> **Don't run the whole suite casually.** Parts of it load Whisper models and drive real embedding models, so a full run takes many minutes. Find the classes you need and target them — the two-phase `build-for-testing` / `test-without-building` split above lets you iterate on tests without rebuilding the app.

Two shared schemes exist, `devgentic` and `devgenticTests`; both run the `devgenticTests` bundle. `devgenticUITests` is Xcode template scaffolding and is not wired into either scheme.

## Repository layout

```
Devgentic/              the app target
  Core/                 backends, the agent loop, persistence, RAG, shared utilities
    Backends/           per-provider services; TextGen/ReAct is the agent loop itself
    Persistence/        SwiftData schema + the RAG/embedding stack
  Interfaces/           every SwiftUI surface — and the native tool + MCP implementations
    Main/               main window, sidebar, profile editor, workflow canvas, tool library
    Shared/             reusable chat surfaces: history, composer, code viewer
    Code/  QuickAccess/  Onboarding/
  Orb/               the voice orb (self-contained)
  ChatOps/              Slack, Discord and Telegram bridges
  Intelligence/         routing and model-capability analysis
  Observaliblity/       tracing and diagnostics — yes, the directory name is misspelled
DevgenticTests/         unit tests
scripts/                release signing and verification scripts
generated/              committed ObjectBox codegen output
```

## Before you use this

Devgentic drives shell commands, edits files and automates the UI on your machine, with your user's privileges. The human-in-the-loop approval system exists for that reason: read what a tool is asking to do before approving it, and be deliberate about turning on autonomous mode. [`SECURITY.md`](SECURITY.md) spells out what is and isn't considered a vulnerability in a tool built on that trust model — and where to report one.

## Privacy

[`PRIVACY.md`](PRIVACY.md) is the full statement. In short: the app is local-first, has no backend of its own, and sends no analytics or telemetry anywhere. Your conversations, files and configuration stay on your Mac.

The exception is the one you choose. A cloud profile sends its requests to whichever provider you configured — that is what a cloud profile *is*. A local `MLX` or `Ollama` profile keeps inference on the machine.

## Support

Devgentic is free and always will be. If it's useful, a ⭐ star on this repo helps others find it. And if it saves you time and you'd like to say thanks, you can [sponsor development on GitHub](https://github.com/sponsors/rajnsingh99). It's entirely optional, and nothing in the app is held back for supporters.

## Contributing

Issues and discussion are welcome. Pull requests are welcome **after** a discussion — open an issue first so the shape of a change is agreed before the work is done. Every contribution requires signing the [Contributor Licence Agreement](CLA.md); [`CONTRIBUTING.md`](CONTRIBUTING.md) has the details, the file-header rule and the conventions that will otherwise fail the build.

## Licence

Devgentic is free software, released under the **GNU Affero General Public License, version 3** (`AGPL-3.0-only`) — the full text is in [`LICENSE`](LICENSE), and every source file carries an SPDX header saying the same.

Everything third-party is listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) with its licence text: the Swift packages, the tree-sitter grammars and highlight.js build they embed, and the one model the app ships — `all-MiniLM-L6-v2` (Apache-2.0), which powers the local RAG index. A copy of that file and of `LICENSE` is inside every built app at `Contents/Resources`, and the About panel links to both.

In practice:

- You can use it, read it, change it and run it — privately or at work, for any purpose.
- If you **distribute a modified version**, or **run a modified version as a service** that other people use over a network, you must make your source available under this same licence. The network clause is the "Affero" part, and it is deliberate: the Slack, Discord and Telegram bridges make "run it as a service" a real way to deploy this app.
- The licence does not forbid commerce; it forbids closing the source. You may charge for it, host it, or sell support, so long as what you ship stays open under AGPL.

If those terms don't work for your organisation, alternative terms can be negotiated — see [`COMMERCIAL-LICENSE.md`](COMMERCIAL-LICENSE.md), which also explains the common cases where you **don't** need one (internal use, however heavily modified, is not distribution). That option exists because the copyright is held by one author and every contribution is covered by the [CLA](CLA.md).

### Trademark and naming

**Devgentic** is the name of this project and a trademark of Raj Singh. The AGPL grants copyright permissions, not trademark rights, and none are granted here.

You may fork, modify and redistribute the code — that is the point of the licence. What you may not do is distribute your modified version under the name *Devgentic*, or in a way that suggests it is the official build or endorsed by the author. Pick your own name. This is the same position Mozilla takes on Firefox, and it protects users rather than restricting developers: someone installing a build called "Devgentic" should be able to rely on where it came from.

Official builds are distributed only from [this repository's Releases](https://github.com/rajnsingh99/devgentic/releases) and are signed with the author's Apple Developer ID.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for details.

