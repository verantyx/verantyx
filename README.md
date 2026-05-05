<div align="center">
  <h1>🛡️ Verantyx IDE & Cortex Engine</h1>
  <p><b>The Zero-Leakage, Neuro-Symbolic AI Coding Gateway & Native macOS IDE</b></p>
  <p><i>Trading token efficiency for mathematically guaranteed security, deterministic patching, and infinite local memory.</i></p>

  <p>
    <a href="https://github.com/Ag3497120/verantyx/releases/latest"><img src="https://img.shields.io/badge/version-1.2.5-blue?style=flat-square" alt="Version 1.2.5"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square">
    <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-orange?style=flat-square">
    <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square">
  </p>

  <p>
    <a href="#-the-hacker-news-pitch-why-verantyx">Why Verantyx?</a> •
    <a href="#-gatekeeper-architecture-zero-leakage-ai">Gatekeeper Architecture</a> •
    <a href="#-technical-capabilities">Technical Capabilities</a> •
    <a href="#-whats-new-in-v125">What's New</a> •
    <a href="#-contribute">Contribute</a>
  </p>
</div>

---

## 📦 Download

**[→ Download Latest Release (v1.2.5)](https://github.com/Ag3497120/verantyx/releases/latest)**

1. Download **`VerantyxIDE-1.2.5.dmg`**
2. Drag **Verantyx.app** to your **Applications** folder.
3. **Bypass Gatekeeper (macOS Security):** Right-click `Verantyx.app` in Finder → **"Open"**. Or run in Terminal: `xattr -d com.apple.quarantine /Applications/Verantyx.app`

---

## 🌌 The Hacker News Pitch: Why Verantyx?

The current AI coding revolution is fundamentally broken for the enterprise and security-conscious developers. Uploading proprietary codebase context to external APIs (OpenAI, Anthropic) results in **Semantic Leakage**. Conversely, relying purely on local edge models (like 8B parameter models) often results in context-window exhaustion and poor complex refactoring logic.

Verantyx was built to resolve this paradox through a **Neuro-Symbolic architecture**:

1. **We abstract your code into a math puzzle (JCross IR)**: Before your code touches an external LLM, the local Verantyx engine strips away all variable names, string literals, and proprietary logic. It transforms the AST into a meaning-zero structural graph.
2. **We force the LLM to solve the structural puzzle**: We send this abstract graph to Claude/GPT-4. The LLM acts as a "blind solver," manipulating the AST structure without knowing what your app actually does.
3. **We deterministically rebuild the code locally**: Once the abstract patch is returned, the local Verantyx Vault recombines the solved graph with your real identifiers.

**The result?** Perfect intellectual property protection, zero prompt injection via comments, and zero hallucinated variables, all while leveraging the reasoning power of massive cloud LLMs.

---

## 🔐 Gatekeeper Architecture: Zero-Leakage AI

Gatekeeper Mode separates concerns between a **Local Commander** and a **Cloud Worker**.

```text
User: "Refactor this database handler for async concurrency"
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│  🧠 LOCAL COMMANDER  (Local MLX / Ollama / BitNet LLM)  │
│  Role: Intent Classification & Memory Orchestration     │
│  • Parses user intent → Selects target files            │
│  • Compiles source code into JCross IR (abstract graph) │
│  • Strips business logic, secrets, and strings          │
└─────────────────────────────────────────────────────────┘
        │  Abstract JCross IR (e.g., [Node_001] -> [Node_002])
        ▼
┌─────────────────────────────────────────────────────────┐
│  ☁️ CLOUD LLM WORKER  (Claude 3.5 / DeepSeek-R1 / GPT-4)│
│  Role: Structural puzzle solving (blind solver)         │
│  • Solves the concurrency AST puzzle                    │
│  • Returns an abstract GraphPatch                       │
└─────────────────────────────────────────────────────────┘
        │  GraphPatch (Semantic-zero diff)
        ▼
┌─────────────────────────────────────────────────────────┐
│  🛡️ VAULT PATCHER  (100% Local & Deterministic)         │
│  Role: Rehydration                                      │
│  • Maps Node_001 back to `fetchUserData()`              │
│  • Applies deterministic AST patch to local file        │
└─────────────────────────────────────────────────────────┘
```

> **Why this matters:** We proudly inflate token usage by sending verbose structural IR because we value **absolute security** over API efficiency. Your code never leaves your machine.

---

## 🚀 Technical Capabilities

### 1. Tri-Layer Cognitive Memory (Cortex)
Standard RAG fails for coding because injecting raw text destroys the LLM's attention span. Verantyx uses **JCross Spatial Memory**:
- **L1 (Kanji Topology)**: Semantic anchors (e.g., `[核:1.0]` for Core, `[像:0.8]` for UI) compress the repository map.
- **L1.5 (Bridge Index)**: O(1) scanning summaries.
- **L2/L3**: Deep storage logic.
This compression allows ultra-small, 2B-class local models (running natively on Apple Silicon via MLX) to infinitely navigate massive enterprise codebases without context loss.

### 2. Multi-Modal Visual Anchors ⚓️
When an LLM ignores strict system prompts, Verantyx allows you to inject **Visual Anchors**. Using `CognitiveAnchorEngine`, the IDE renders critical user constraints (e.g., "NEVER modify this file") as base64-encoded visual constraint images (using SF Symbols like `exclamationmark.lock.fill`). This targets the multimodal visual cortex of the LLM, bypassing text-based "attention decay" and forcing strict adherence to safety directives.

### 3. Biometric Stealth Browser 🕵️‍♂️
Verantyx agents can research documentation on the live web without triggering BotGuard, Cloudflare, or reCAPTCHA. 
- **Hybrid JS/HID Injection:** Uses macOS-level `CGEvent` simulation paired with DOM synchronization.
- **Entropy Simulation:** Captures your typing cadence and mouse trajectories during chat, then perfectly replays that human biometric entropy during headless agent navigation.
- **Zero-Steal Focus:** Operates completely in the background without stealing your OS keyboard focus.

### 4. Self-Evolution & Native MCP Integration
Verantyx is designed to build itself. The `SelfEvolutionView` allows the IDE to write its own patches, run virtual CI, and submit GitHub PRs from within the editor. Furthermore, **Model Context Protocol (MCP)** is deeply integrated with a fuzzy-searchable `MCPQuickPanel` (summoned via `⌘⇧M`), allowing instant access to PostgreSQL, GitHub, or local file system MCP servers.

---

## ✨ What's New in v1.2.5

- **Visual Anchor UI Restored**: Fixed an SF Symbol rendering bug and layout constraint that hid the Visual Anchor injection button. 
- **AgentChatView Polish**: Implemented `.frame(width: 114)` to support the full suite of attachment tools (Image, File, Visual Anchor, Self-Fix).
- **BitNet 1.58b Support**: Deep integration with 1-bit LLMs for ultra-low memory footprint local edge inference.
- **MainActor Deadlocks Eliminated**: Eradicated all `Task.detached` threading crashes during heavy MLX inference, resulting in 60fps buttery smooth UI scrolling even during maximum CPU/GPU load.

---

## 🛠 Features Summary

| Feature | Status |
|---|---|
| 🤖 Local Inference (Ollama, MLX Apple Silicon) | ✅ v1.0 |
| 🛡️ Gatekeeper Mode (Zero-Leakage JCross IR) | ✅ v1.0 |
| 🧠 Tri-Layer JCross Memory (Cortex) | ✅ v1.0 |
| 🧩 MCP (Model Context Protocol) Quick Panel | ✅ v1.1 |
| ⚡ BitNet 1.58b 1-bit LLM support | ✅ v1.1 |
| 👁️ Visual Anchor Prompt Injection | ✅ v1.2 |
| 🕵️‍♂️ Biometric Stealth Browser (Bot Evasion) | ✅ v1.2 |
| 🧬 Self-Evolution IDE UI | ✅ v1.2 |

---

## 🤝 Contribute

We are building the future of secure AI development. Building AST extractors and neuro-symbolic memory bridges is a complex systems engineering challenge. 

**We have built the Core Engine. We need the community to build the Periphery.**
If you want to contribute to a serious systems programming project, look for these issues in the repo:
- 🏷️ `help wanted`: **Go AST Parser** (Mapping Go `struct` to JCross IR)
- 🏷️ `help wanted`: **Rust AST Parser** (Mapping lifetimes to JCross edges)
- 🏷️ `good first issue`: UI/UX enhancements in the native SwiftUI client.

---

## 💻 Building from Source (macOS Only)

**Prerequisites:**
- macOS 14.0+ (Apple Silicon highly recommended)
- Xcode 15.0+

```bash
git clone https://github.com/Ag3497120/verantyx.git
cd verantyx/VerantyxIDE
open Verantyx.xcodeproj
# Select the Verantyx scheme and hit Cmd+R
```

*Note: A Windows/Linux port (Rust core + llama.cpp) is on our long-term roadmap, but we are laser-focused on perfecting the native macOS/MLX architecture first.*
