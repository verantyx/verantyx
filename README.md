# Verantyx: Enterprise Gatekeeper IDE

## Overview

**Verantyx** is an enterprise-grade AI IDE designed to solve the critical security dilemma of modern software development: **How can organizations leverage powerful cloud LLMs (like Claude 3.7 or GPT-4o) without exposing their proprietary, confidential source code?**

Verantyx introduces a paradigm shift through its exclusive **Gatekeeper Mode architecture**. Instead of operating as a traditional AI coding assistant that transmits your raw IP to third-party servers, Verantyx utilizes a secure, neuro-symbolic pipeline orchestrated entirely on your local machine.

## 🛡️ The Gatekeeper Architecture

Enterprise codebases contain trade secrets, proprietary algorithms, and sensitive infrastructure logic. Sending this data to cloud APIs is often a severe compliance and security violation.

Verantyx solves this via a dual-model approach:
1. **The Local Orchestrator (SLM):** A local edge model (e.g., Qwen 2.5/3, Llama 3) runs securely on your local GPU/Apple Silicon. It parses your raw source code and abstracts it into an anonymized, topological Intermediate Representation (IR) known as the **JCross L2.5 Map**.
2. **The Cloud Worker (LLM):** The external cloud LLM receives *only* the obfuscated JCross IR (Kanji topology, structural outlines, and type definitions). It generates logic updates based purely on structural intent, completely blind to your actual business logic and variable values.
3. **The Integration Phase:** The local orchestrator receives the generated structural patches and safely weaves them back into the raw source code locally.

Your actual code never leaves your machine. Only the skeleton does.

## 🌟 Demo: Visual Task Anchors & SLM Control

> **Persistent Modality Hacking:**  
> *Verantyx enforces continuous goal alignment on local SLMs using our custom `CognitiveAnchorEngine`. By injecting dynamic, real-time visual anchors (e.g., [ DOUBT / VERIFY ] or [ PERSISTENT TASK ]) into the image stream at every turn, Verantyx prevents the local model from hallucinating or losing track of the overarching pipeline task across 10,000+ turns.*

<p align="center">
  <video src="https://github.com/Ag3497120/Verantyx/releases/download/v0.1/demo_compressed.mp4" controls="controls" muted="muted" style="max-height:640px; width:100%; max-width: 800px;">
    Your browser does not support the video tag.
  </video>
</p>

## ✨ Key Enterprise Features

- **Zero-Trust AI Coding:** Total IP protection. Source code is decoupled into Abstract Syntax Trees and JCross representations before any network request is made.
- **Transpilation Pipeline:** Seamlessly migrate massive legacy codebases (e.g., Swift to Rust) autonomously. The built-in pipeline divides the project into thousands of JCross L2.5 TODOs, feeding them sequentially to the local agent loop without context overflow.
- **JCross Tri-Layer Spatial Memory:** Prevent infinite-loop hallucinations and context degradation. Verantyx compresses decisions and structural knowledge into local `.jcross` files (L1 Kanji, L2 Logic, L3 Context), retrieving them only when the local SLM needs them.
- **Native macOS SwiftUI IDE:** A high-performance, native UI that gives human operators complete visibility into the AI's internal `<think>` processes, memory retrievals, and Gatekeeper translations.

## 📂 Project Structure

```text
.
├── cli/                 # The macOS Swift IDE and Desktop application
│   ├── VerantyxIDE/     # Main SwiftUI IDE (Enterprise Gatekeeper UI)
│   └── verantyx-browser/# Rust-based stealth browser automation for secure research
├── cortex/              # The Agentic Brain & Memory Engine
│   ├── src/verantyx/    # Core TypeScript Gatekeeper routing and memory engines
│   └── jcross-memory/   # High-speed Rust parsers for JCross IR
└── README.md            # This file
```

## 🚀 Deployment & Build

Verantyx is designed for internal enterprise deployments.

### Building from Source (macOS)
Requires Xcode 15+ and macOS 14.0+. Apple Silicon (M1/M2/M3/M4) is highly recommended for running the local SLM Gatekeeper.

```bash
cd cli/VerantyxIDE
bash package_dmg.sh 2.0.0
```

### Local Model Requirements
The Gatekeeper Mode requires a local Ollama or MLX instance running a multimodal-capable edge model (e.g., Qwen3-VL, Llama-3-Vision) to process Visual Task Anchors.

---
*Verantyx: Secure your IP. Empower your architecture. Control the AI.*
