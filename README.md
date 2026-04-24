# ⚡ Verantyx IDE

> **Apple Silicon-native AI coding assistant. Fully offline. Zero API cost.**

<!-- TODO: Add 30-second demo GIF here -->
<!-- ![demo.gif](demo.gif) -->

Verantyx is a macOS AI code editor that runs inference locally using MLX models (Apple Silicon) or Ollama — no cloud, no subscription.  
Select a file, give a natural-language instruction, and Verantyx proposes a diff you can review and apply in one click.

---

## 📦 Download

**[→ Download Latest Release](https://github.com/Ag3497120/verantyx/releases/latest)**

1. Download **`VerantyxIDE-x.x.x.dmg`**
2. Open the DMG and drag **Verantyx.app** to your **Applications** folder
3. **First launch — bypass Gatekeeper (macOS security prompt):**
   - Right-click `Verantyx.app` in Finder → **"Open"**
   - Click **"Open"** in the unidentified developer dialog
   - _Or run in Terminal:_ `xattr -d com.apple.quarantine /Applications/Verantyx.app`

---

## ✨ Features

| Feature | Status |
|---|---|
| 🤖 Ollama integration (gemma4:26b, etc.) | ✅ v1.0 |
| ⚡ MLX Apple Silicon inference (offline) | ✅ v1.0 |
| 🔑 Anthropic Claude integration | ✅ v1.0 |
| 💬 Natural language → file edits | ✅ v1.0 |
| 🔍 Diff review → one-click Apply | ✅ v1.0 |
| 📂 Open any folder as workspace | ✅ v1.0 |
| 🔒 Fully offline (no Wi-Fi required) | ✅ v1.0 |
| 🧠 JCross long-term memory (Cortex) | ✅ v1.0 |
| 🔒 Privacy Gateway: 3-phase PII masking | ✅ v1.0 |
| 🧬 Self-Evolution: live IDE self-patching | ✅ v1.0 |
| 📜 Session history with restore | ✅ v1.0 |
| 🛠️ MCP (Model Context Protocol) client | ✅ v1.0 |

---

## 🧠 Verantyx Cortex (Recommended)

Cortex gives the AI persistent long-term memory across sessions using the JCross spatial memory system.

```bash
npx -y @verantyx/cortex setup
```

More info: [github.com/Ag3497120/verantyx-cortex](https://github.com/Ag3497120/verantyx-cortex)

---

## 🚀 System Requirements

- macOS 14 Sonoma or later
- Apple Silicon (M1 / M2 / M3 / M4)
- [Ollama](https://ollama.com) _(recommended: `ollama pull gemma4:26b`)_
- **OR** an MLX model downloaded from HuggingFace

---

## 🛠 Build from Source

```bash
git clone https://github.com/Ag3497120/verantyx.git
cd verantyx/VerantyxIDE
open Verantyx.xcodeproj
```

Build (`⌘B`) and run (`⌘R`) in Xcode 16+.

To create a distributable DMG locally:

```bash
cd VerantyxIDE
bash package_dmg.sh 1.0.0
# → dist/VerantyxIDE-1.0.0.dmg
```

---

## 🔧 Usage

1. **Start Ollama** (if using Ollama): `ollama serve`
2. **Launch Verantyx**
3. Click **"Connect"** in the toolbar to link your model
4. Click **"Open Workspace"** to select your project folder
5. Click any file in the file tree to load it as context
6. Type your instruction in the chat and press Enter
7. Review the diff in the right panel → click **Apply** to write changes

---

## 📐 Architecture

```
VerantyxIDE/
├── Sources/Verantyx/
│   ├── AppState.swift              # Central state + inference routing
│   ├── Engine/
│   │   ├── AgentLoop.swift         # Agentic loop with tool execution
│   │   ├── MLXRunner.swift         # Apple Silicon MLX inference
│   │   ├── OllamaClient.swift      # Ollama + Anthropic API client
│   │   ├── CortexEngine.swift      # JCross memory compression
│   │   ├── SessionStore.swift      # Session persistence + restore
│   │   ├── PrivacyGateway.swift    # 3-phase PII masking
│   │   ├── MCPEngine.swift         # MCP tool injection
│   │   └── SelfEvolutionEngine.swift # Live IDE self-patching
│   └── Views/
│       ├── AgentChatView.swift     # Main chat UI
│       ├── FileTreeView.swift      # Workspace file tree
│       ├── ArtifactPanelView.swift # HTML/SVG/Mermaid render
│       ├── ModelPickerView.swift   # Model selection
│       └── SessionHistoryView.swift# Session history browser
└── .github/workflows/release.yml  # Auto-build DMG on tag push
```

---

## 🔄 Release Automation

Push a version tag to trigger an automatic DMG build via GitHub Actions:

```bash
git tag v1.1.0
git push origin v1.1.0
# → GitHub Actions builds & publishes VerantyxIDE-1.1.0.dmg automatically
```

---

## 📄 License

MIT License — fork & hack freely.
