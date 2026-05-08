# Verantyx: The Ultimate AI Control IDE

## Overview

Welcome to the unified **Verantyx** repository. This project is the culmination and consolidation of everything we have learned and built across multiple antecedent projects:
- `verantyx`
- `verantyx-logic`
- `verantyx-cortex`
- `tool-search-oss`
- `verantyx-pure-through`

By merging these disparate engines, we have created a single, powerful platform whose sole, laser-focused theme is **"Controlling AI."** 

This repository provides a unified macOS IDE (with a built-in CLI layer from `verantyx-cli`) designed to manage, steer, and safely execute autonomous AI agents. Instead of simply building an AI application, Verantyx is a meta-tool—an IDE *for* AI—allowing humans to direct agent loops, monitor deep contextual memory (JCross Tri-Layer Architecture), and securely authorize local and cloud LLM actions.

## 🌟 Demo Video Area

> **SLM Anchor Injection Demo:**  
> *This video demonstrates Verantyx preventing the local SLM from relying on stale internal knowledge. By utilizing image anchor injection, the system forces the SLM to discard its pre-trained answers and autonomously execute the latest web searches to obtain factual, real-time data.*

<p align="center">
  <video src="https://github.com/Ag3497120/verantyx-1/releases/download/v1.4.6/demo_compressed.mp4" controls="controls" muted="muted" style="max-height:640px; width:100%; max-width: 800px;">
    Your browser does not support the video tag.
  </video>
</p>

## ✨ What Can Verantyx Do?

Verantyx is engineered to bring unparalleled transparency, security, and autonomy to your engineering workflows. Its capabilities include:

- **Unified macOS IDE & CLI:** A native SwiftUI IDE that integrates the raw terminal power of `verantyx-cli`. Use the UI to visualize operations, or the CLI to integrate with Unix pipelines.
- **Agent Loop Execution:** Run complex, multi-step ReAct loops locally (via Ollama/BitNet) or in the cloud (Anthropic Claude). The IDE streams real-time thinking (`<think>`) and tool execution statuses so you always know what the GPU is doing.
- **JCross Tri-Layer Memory:** An autonomous spatial memory engine. Verantyx automatically compresses, indexes (Kanji topology), and stores past decisions into a unified `.jcross` knowledge graph, preventing context overflow and hallucination over thousands of turns.
- **Gatekeeper Security:** Never blindly trust external APIs. The Gatekeeper intervenes and securely manages file access, obfuscating sensitive business logic into semantic intermediate representations (IR) before external LLMs ever see them.
- **MCP (Model Context Protocol) Integration:** Natively exposes a suite of memory, search, and system management tools via MCP servers, allowing platforms like Claude Desktop and Antigravity to interface directly with your local workspace.
- **Stealth Browser Automation (`verantyx-browser`):** A custom browser engine designed to emulate human biological data (mouse bezier curves, typo-driven typing algorithms) to bypass automated bot protections while researching and scraping data.

## 📂 Project Structure

This monorepo is structured to separate the core IDE, the autonomous logic cortex, and the external tool bindings:

```text
.
├── cli/                 # The macOS Swift IDE and CLI app wrappers
│   ├── VerantyxIDE/     # Main SwiftUI Application project (Verantyx.app)
│   ├── verantyx-browser/# Rust-based stealth browser automation engine
│   └── Verantyx-Logic/  # Legacy logic modules being migrated
├── cortex/              # The brain: Agentic loop, JCross Memory, and MCP servers
│   ├── src/verantyx/    # Core TypeScript orchestrators and memory engines
│   ├── jcross-memory/   # Rust implementations for fast JCross memory parsing
│   └── apps/ios/        # Experimental mobile companions
├── tools/               # External tool definitions and OSS catalog
└── README.md            # This file
```

## 🚀 Getting Started

### 1. Download the Latest Release
Head over to the [Releases](https://github.com/Ag3497120/verantyx-1/releases) page and download the latest `VerantyxIDE-x.x.x.dmg`.

### 2. Connect Your Agents
Verantyx can act as an MCP Server for Antigravity or Claude Desktop. Configure your MCP settings to point to the built-in `cortex/src/verantyx/mcp/server.ts` to expose the JCross memory and workspace tools.

### 3. Build from Source
If you wish to compile the IDE yourself:
```bash
cd cli/VerantyxIDE
bash package_dmg.sh 1.4.6
```
*(Requires Xcode 15+ and macOS 14.0+)*

---
*Your machine is no longer just a computer. With Verantyx, it is a tireless, controllable, and secure engineering swarm.*
