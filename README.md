<div align="center">
  <h1>🛡️ Verantyx IDE & Cortex Engine</h1>
  <p><b>The Zero-Leakage, Neuro-Symbolic AI Coding Gateway & Native macOS IDE</b></p>
  <p><i>We trade token cost for absolute security, deterministic patching, and forced structural reasoning.</i></p>
  
  <p>
    <a href="#-the-vision-why-verantyx-exists">Vision</a> •
    <a href="#-the-contributor-strategy-join-the-core-engineering-team"><b>Contribute! (Help Wanted)</b></a> •
    <a href="#-demos">Demos</a>
  </p>
</div>

---

## 🌌 The Vision: Why Verantyx Exists

The AI coding revolution is broken for enterprise. **Semantic Leakage** prevents banks, healthcare systems, and defense contractors from uploading their proprietary code to APIs like OpenAI or Anthropic. Furthermore, even when code is uploaded, LLMs frequently hallucinate syntax errors, hallucinate non-existent variables, and break build pipelines.

Verantyx takes a radically different approach. We are building the **Enterprise Security Gateway for AI Coding**.

### 1. Zero-Leakage Gatekeeper Mode
We convert your source code into a synthetic, mathematically anonymized graph called **JCross IR**. External LLMs *never* see your business logic—they only see abstract structural shapes. We gladly sacrifice token efficiency (API costs) to guarantee 100% intellectual property protection and flawless, deterministic AST patching.

### 2. Forced Structural Reasoning
By stripping away English semantics and replacing them with Kanji dimensional weights (e.g., `[核:1.0][像:0.8]`), we force LLMs to stop guessing based on variable names and start reasoning about the pure logic graph. This unlocks massive-scale refactoring capabilities without syntax hallucination.

### 💡 The Verantyx Paradox: Burning Tokens vs. Infinite Local Memory

This architecture embraces what might seem like a direct contradiction. 

**On one hand (The Cloud Gatekeeper):** We do *not* care about saving API tokens. When routing tasks to external LLMs (Claude/GPT), we intentionally inflate token consumption by 30-40% by obfuscating code into JCross IR. We proudly trade API efficiency for **mathematically guaranteed security (zero-leakage)** and deterministic patching for enterprise logic.

**On the other hand (The Local Cortex):** We are building the ultimate zero-cost, infinite-context local engine. By leveraging the same JCross IR format, we have implemented a **Tri-Layer Cognitive Memory System** that mimics human biological memory:
- **L1 (Kanji Topology)**: Semantic anchors used to instantly grasp structure.
- **L1.5 (Bridge Index)**: One-line summaries for massive O(1) scanning without context-window pollution.
- **L2 & L3 (Facts & Raw Text)**: The actual deep storage of code graphs and decisions.

Because our models only need to process *mathematical structure* rather than massive raw text payloads, we enable **ultra-small, 2B-class local models** (running entirely offline on Apple Silicon via MLX) to navigate and manage massive, enterprise-scale codebases *without ever suffering from context loss*. 

We burn tokens in the cloud to buy perfect security. We compress structure locally to achieve infinite memory on edge devices. If you share this vision of the future, you belong here.

---

## 🤝 The Contributor Strategy: Join the Core Engineering Team

AST parsing, memory management, and neuro-symbolic transformations are notoriously complex system programming challenges. We know developers can't just "drop in and fix 5 lines of code." 

To make contributing highly accessible and incredibly impactful, we have deliberately designed a decoupled architecture:

### 🧠 The Core vs. The Periphery
- **The Core Engine (Maintained by Verantyx):** The complex JCross Topology Matrix, memory classifiers, and Reverse-Transpilation engines.
- **The Periphery (Built by the Community):** The language-specific AST Extraction Parsers. 

**We have already built the Python and Swift parsers. We desperately need the open-source community to build the bridges for the rest of the programming world.**

### 🎯 We Need Your Help
If you want to build a serious OSS portfolio in system programming and AI architecture, here is where you can make a massive impact today. Search our issues for these tags:

*   🏷️ **`help wanted` Go AST Parser:** Build the structural extractor that maps Golang `struct` and `interface` to JCross IR.
*   🏷️ **`help wanted` Java/Kotlin AST Parser:** Help bring Verantyx to the massive enterprise Java ecosystem.
*   🏷️ **`good first issue` Rust AST Parser (Partial):** We have the foundation, but need help mapping Rust's lifetime syntax to JCross edges.
*   🏷️ **`good first issue` UI Integrations:** Help us build toggle switches for the JCross/Raw view in the macOS Native Editor.

*We actively review, merge, and mentor contributors on these issues. Your code will directly power the future of secure AI development.*

---

## 🎥 Demos

### Gatekeeper Mode in Action
Protecting intellectual property by converting Swift code into abstracted JCross IR before sending to cloud LLMs.

<video src="https://github.com/Ag3497120/verantyx/releases/download/v1.1.0/gatekeeper_demo.mov" controls="controls" muted="muted" style="max-width: 100%;"></video>

### Local Nano LLM Memory & Kanji Topology
Demonstrating infinite context retention and language enforcement on local 2B models using `[和:1.0]` Kanji Topology memory nodes.

<video src="https://github.com/Ag3497120/verantyx/releases/download/v1.1.0/nano_memory_demo.mov" controls="controls" muted="muted" style="max-width: 100%;"></video>

---

## 🛠 Building from Source (macOS Only)

### Prerequisites
- macOS 14.0+ (Apple Silicon highly recommended)
- Xcode 15+

### Build & Run
1. Clone the repository.
2. Open `VerantyxIDE/Verantyx.xcodeproj` in Xcode.
3. Select the `Verantyx` scheme and hit Run (Cmd+R).

*Note: A Windows port (Rust core + llama.cpp) is on our long-term roadmap, but we are laser-focused on perfecting the macOS MLX architecture first. We will lean heavily on the community for beta testing when the time comes!*
