<div align="center">
  <h1>Verantyx IDE — Native macOS AI Code Editor</h1>
  <p><b>A neuro-symbolic long-term memory architecture and secure Gatekeeper IDE, built on Apple MLX, JCross spatial nodes, and Swift.</b></p>
</div>

## 🎥 Demos

### Local Nano LLM Memory & Kanji Topology
Demonstrating infinite context retention and language enforcement on local 2B models using `[和:1.0]` Kanji Topology memory nodes.

<video src="https://github.com/Ag3497120/verantyx/releases/download/v1.1.0/nano_memory_demo.mov" controls="controls" muted="muted" style="max-width: 100%;"></video>

### Gatekeeper Mode in Action
Protecting intellectual property by converting Swift code into abstracted JCross IR before sending to cloud LLMs.

<video src="https://github.com/Ag3497120/verantyx/releases/download/v1.1.0/gatekeeper_demo.mov" controls="controls" muted="muted" style="max-width: 100%;"></video>

---

## 🚀 Latest Features

### 1. The Native macOS IDE (`VerantyxIDE`)
Verantyx has evolved from a Node.js CLI into a fully native macOS application built with Swift and SwiftUI. It features a hyper-fast code editor, deeply integrated with Apple's **MLX** framework for ultra-low latency local AI inference directly on Apple Silicon.

### 2. JCross Tri-Layer Memory & Kanji Topology
A radical departure from standard RAG. Memory is encoded in a proprietary format that small local models (~2B) can actually understand without context-blindness:
- **L1 (Kanji Topology)**: Semantic anchors (e.g., `[和:1.0][疑:1.0]`) used to instantly force language modes and fight LLM sycophancy.
- **L1.5 (Bridge Index)**: One-line summaries for massive O(1) scanning without context pollution.
- **L2 & L3 (Facts & Raw Text)**: The actual conversation and structural code storage.
This enables infinite context retention and perfect recall even on extreme edge models like Gemma-2B.

### 3. Gatekeeper Mode (Zero-Knowledge Inference)
Cloud LLMs (like Claude/GPT) are incredible, but sending proprietary source code is a major security risk. **Gatekeeper Mode** acts as a blind proxy:
1. It transpiles your source code into a synthetic, anonymized language called **JCross IR**.
2. It sends this IR to the cloud LLM.
3. The LLM returns a patch in IR, and the IDE automatically reverse-transpiles it back into working Swift/TS code.
*Your raw source code never leaves your machine.*

### 4. BitNet (1-bit LLM) Subprocess Inference
Native integration for ultra-fast, ultra-low memory 1.58-bit models. Verantyx uses BitNet models silently in the background (e.g., as an L1 Tagger) to dynamically organize memory and tag code without burning through your main GPU cycles or token budgets.

---

## 🛣 Windows Roadmap

Thanks for the interest! A Windows version is definitely on the radar, but it's going to be a massive undertaking.

To make it cross-platform, I essentially have to rewrite the core cognitive engine (Swift -> Rust) and swap out Apple's MLX backend for something like llama.cpp to get CUDA/DirectML support.

Since I'm building this solo, my strategy right now is to stay hyper-focused and get the macOS/Swift version to 100% completion first before splitting my attention.

Also, full disclosure: I actually don't own a Windows rig with an NVIDIA GPU at the moment! 😅 So when the time finally comes to build the Windows port, I won't be able to run local tests or benchmark the CUDA performance myself. I'll definitely be leaning heavily on this community for beta testing and feedback when that happens.

I hope you'll stick around to help me out when the time comes!

---

## 🛠 Building from Source (macOS Only)

### Prerequisites
- macOS 14.0+ (Apple Silicon highly recommended)
- Xcode 15+

### Build & Run
1. Clone the repository.
2. Open `VerantyxIDE/Verantyx.xcodeproj` in Xcode.
3. Select the `Verantyx` scheme and hit Run (Cmd+R).
