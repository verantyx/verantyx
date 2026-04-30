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

### 3. Ultra-Small Local Models at Massive Scale
Because the model only processes structure and not complex domain semantics, we can achieve massive-scale development workflows using **ultra-small, hyper-fast local models (1.5B - 3B)** running entirely offline on Apple Silicon via MLX.

### 💡 Our Philosophy: The Trade-off We Proudly Make
*We do not care about saving API tokens. We do not care if the LLM gets to read "human-readable" variable names.*

Most AI coding tools are just thin API wrappers optimized to send your raw code to the cloud as cheaply and quickly as possible. We take the exact opposite approach. By converting your code into JCross IR, we **intentionally increase token consumption by 30-40%** and strip away semantic context. 

Why? Because in enterprise, finance, and defense, API tokens cost pennies, but leaking proprietary business logic or blindly applying a hallucinated, syntax-breaking AI patch costs millions. We proudly trade token efficiency for **mathematically guaranteed security (zero-leakage) and deterministic AST patching**. If you share this philosophy, you belong here.

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
