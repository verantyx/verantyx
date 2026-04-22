import SwiftUI

// MARK: - SelfEvolutionView
// The IDE's "self-evolution" control panel.
// Shows: source index state, pending patches, build progress, PR submission.

struct SelfEvolutionView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var evo = SelfEvolutionEngine.shared
    @StateObject private var pr  = GitHubPREngine.shared

    @State private var activeSection: Section = .index
    @State private var featureName: String = ""
    @State private var commitMessage: String = ""
    @State private var prTitle: String = ""
    @State private var prBody: String = ""
    @State private var showPRForm = false
    @State private var showGitHubSetup = false
    @State private var submittedPR: GitHubPREngine.PRRecord? = nil

    enum Section: String, CaseIterable {
        case index    = "Index"
        case patches  = "Patches"
        case build    = "Build"
        case history  = "History"
        case prSubmit = "Submit PR"
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().opacity(0.3)
            sectionTabs
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch activeSection {
                    case .index:    indexSection
                    case .patches:  patchesSection
                    case .build:    buildSection
                    case .history:  historySection
                    case .prSubmit: prSection
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        .onAppear {
            evo.loadAppliedFeatures()
            pr.loadConfig()
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
            Text("Self-Evolution")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.92))
            Spacer()

            // Safe mode indicator
            if case .safeMode = evo.buildState {
                Text("⚠️ SAFE MODE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }

            // GitHub config button
            Button { showGitHubSetup = true } label: {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(pr.config.githubToken.isEmpty
                                     ? Color.orange
                                     : Color(red: 0.3, green: 0.85, blue: 0.5))
            }
            .buttonStyle(.plain)
            .help("GitHub 設定")
            .popover(isPresented: $showGitHubSetup, arrowEdge: .trailing) {
                GitHubConfigView(config: $pr.config, onSave: { pr.saveConfig() })
                    .frame(width: 360, height: 320)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(red: 0.13, green: 0.13, blue: 0.17))
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Section.allCases, id: \.rawValue) { sec in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { activeSection = sec }
                    } label: {
                        HStack(spacing: 4) {
                            if sec == .patches && !evo.pendingPatches.isEmpty {
                                Circle().fill(Color(red: 1.0, green: 0.65, blue: 0.2))
                                    .frame(width: 6, height: 6)
                            }
                            if sec == .build, case .building(_) = evo.buildState {
                                ProgressView().scaleEffect(0.4).frame(width: 8, height: 8)
                            }
                            Text(sec.rawValue)
                                .font(.system(size: 10, weight: activeSection == sec ? .semibold : .regular))
                        }
                        .foregroundStyle(activeSection == sec ? .white : Color(red: 0.5, green: 0.5, blue: 0.62))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(activeSection == sec ? Color.white.opacity(0.07) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }

    // MARK: - Index Section

    private var indexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Repo root
            Group {
                if let root = evo.repoRoot {
                    Label(root.path, systemImage: "folder.fill")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Label("リポジトリが見つかりません", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)

            // Index button
            Button {
                Task { await evo.indexSourceTree() }
            } label: {
                HStack(spacing: 6) {
                    if evo.isIndexing {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "brain").font(.system(size: 11))
                    }
                    Text(evo.isIndexing ? "インデックス中…" : "ソースをインデックス")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(red: 0.25, green: 0.50, blue: 0.90))
                )
            }
            .buttonStyle(.plain)
            .disabled(evo.isIndexing)
            .padding(.horizontal, 12)

            if !evo.sourceNodes.isEmpty {
                Text("\(evo.sourceNodes.count) ファイルをインデックス済み")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                // File list
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(evo.sourceNodes) { node in
                        HStack(spacing: 6) {
                            Image(systemName: FileIcons.icon(ext: "swift"))
                                .font(.system(size: 9))
                                .foregroundStyle(FileIcons.color(ext: "swift"))
                                .frame(width: 12)
                            Text(node.relativePath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color(red: 0.70, green: 0.70, blue: 0.80))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(node.content.components(separatedBy: "\n").count)L")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .background(Color.white.opacity(0.015))
                    }
                }

                // How-to hint
                infoBanner(
                    "AIに \"AgentChatView.swiftを修正してチャット背景を深紫にして\" と指示してください。" +
                    " AIが差分を生成し、Patchesタブに表示されます。"
                )
            }

            if !evo.buildLog.isEmpty {
                Text(evo.buildLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.07, green: 0.09, blue: 0.07))
                    .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Patches Section

    private var patchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if evo.pendingPatches.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 20)
                    Image(systemName: "doc.text.below.ecg")
                        .font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("差分なし")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("AIに「〇〇機能を追加して」と指示するか、\n直接ソースを編集してください。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                ForEach(evo.pendingPatches) { patch in
                    patchCard(patch)
                }

                // Feature name + Apply button
                VStack(alignment: .leading, spacing: 8) {
                    Text("機能名")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("例: チャット背景を深紫に変更", text: $featureName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(8)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                    Text("コミットメッセージ (省略可)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("feat: ...", text: $commitMessage)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(8)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 12)

                applyAndRebuildButton
            }
        }
    }

    private func patchCard(_ patch: SelfEvolutionEngine.FilePatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: FileIcons.icon(ext: "swift"))
                    .font(.system(size: 9))
                    .foregroundStyle(FileIcons.color(ext: "swift"))
                Text(patch.relativePath)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.80, green: 0.80, blue: 0.90))
                Spacer()
                switch patch.status {
                case .pending:
                    Text("PENDING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.2))
                case .applied:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5)).font(.system(size: 11))
                case .failed(let e):
                    Text("ERR: \(e.prefix(20))")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.red)
                }
            }

            // Diff preview (first 15 changed lines)
            let diffLines = patch.diff.components(separatedBy: "\n").filter { !$0.hasPrefix("---") && !$0.hasPrefix("+++") }.prefix(15)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? Color(red: 0.4, green: 0.9, blue: 0.5) :
                                          line.hasPrefix("-") ? Color(red: 0.9, green: 0.4, blue: 0.4) :
                                          Color(red: 0.60, green: 0.60, blue: 0.70))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
            .background(Color(red: 0.07, green: 0.07, blue: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    private var applyAndRebuildButton: some View {
        Button {
            let name = featureName.isEmpty ? "Custom Feature" : featureName
            let msg  = commitMessage
            activeSection = .build
            Task {
                await evo.applyPatchesAndRebuild(featureName: name, gitCommitMessage: msg)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill").font(.system(size: 12))
                Text("Apply & Rebuild")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.7, green: 0.2, blue: 0.9), Color(red: 0.3, green: 0.2, blue: 0.9)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .shadow(color: Color(red: 0.5, green: 0.1, blue: 0.8).opacity(0.5), radius: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .disabled(featureName.isEmpty)
    }

    // MARK: - Build Section

    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Build state banner
            buildStateBanner
                .padding(.horizontal, 12).padding(.top, 10)

            // Launch button
            if case .succeeded(let url) = evo.buildState {
                Button {
                    evo.launchNewBinary()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 12))
                        Text("新バージョンを起動")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.8, blue: 0.55), Color(red: 0.1, green: 0.6, blue: 0.4)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)

                Text("📁 \(url.path)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                // Auto-switch to PR tab
                Button {
                    let draft = pr.generatePRBody(
                        featureName: featureName.isEmpty ? "Custom Feature" : featureName,
                        patches: evo.pendingPatches
                    )
                    prTitle = draft.title
                    prBody  = draft.body
                    activeSection = .prSubmit
                } label: {
                    Label("PR を作成する", systemImage: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }

            // Live build log
            buildLogView
        }
    }

    private var buildStateBanner: some View {
        HStack(spacing: 8) {
            switch evo.buildState {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("待機中").foregroundStyle(.secondary)
            case .building(let p):
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                    .frame(width: 80)
                Text(String(format: "ビルド中… %.0f%%", p * 100))
                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                Text("ビルド成功！").foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("ビルド失敗").foregroundStyle(.red)
            case .safeMode:
                Image(systemName: "shield.fill").foregroundStyle(.orange)
                Text("セーフモードで起動中").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private var buildLogView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(evo.buildLog.isEmpty ? "ビルドログがここに表示されます…" : evo.buildLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(red: 0.5, green: 0.88, blue: 0.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logBottom")
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.05))
            .frame(maxHeight: .infinity)
            .onChange(of: evo.buildLog) { _ in
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if evo.appliedFeatures.isEmpty {
                VStack(spacing: 10) {
                    Spacer().frame(height: 20)
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("適用済み機能なし")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                }
                .frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                ForEach(evo.appliedFeatures) { feat in
                    featureCard(feat)
                }
            }
        }
        .padding(.top, 8)
    }

    private func featureCard(_ feat: SelfEvolutionEngine.AppliedFeature) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.55))
                    .font(.system(size: 10))
                Text(feat.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.92))
                Spacer()
                Text(feat.appliedAt, style: .relative)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(feat.branchName)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.65))

            if let prURL = feat.prURL {
                Link(destination: URL(string: prURL)!) {
                    Label("PR を見る", systemImage: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    // MARK: - PR Section

    private var prSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Config check
            if pr.config.githubToken.isEmpty || pr.config.upstreamOwner.isEmpty {
                infoBanner("GitHub Token と リポジトリ設定が必要です。右上の 🔑 ボタンから設定してください。")
                    .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    labeledField("PR タイトル", text: $prTitle)
                    labeledTextEditor("PR 説明 (Markdown)", text: $prBody)

                    // Branch info
                    if !evo.customBranch.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(evo.customBranch)
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }

                    // Submit button
                    Button {
                        Task {
                            guard let root = evo.repoRoot else { return }
                            let draft = GitHubPREngine.PRDraft(
                                title: prTitle, body: prBody, headBranch: evo.customBranch
                            )
                            if let record = await pr.submitPR(draft: draft, in: root) {
                                submittedPR = record
                                // Update applied feature with PR URL
                                if let idx = evo.appliedFeatures.firstIndex(where: { $0.branchName == evo.customBranch }) {
                                    evo.appliedFeatures[idx].prURL = record.url
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if pr.isSubmitting {
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.up.doc.on.clipboard").font(.system(size: 12))
                            }
                            Text(pr.isSubmitting ? "送信中…" : "Pull Request を送信")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(prTitle.isEmpty ? Color.gray.opacity(0.3)
                                      : Color(red: 0.15, green: 0.35, blue: 0.65))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(prTitle.isEmpty || pr.isSubmitting)

                    if let err = pr.lastError {
                        Text("⚠️ \(err)")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }

                    if let rec = submittedPR {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                            Link("PR を GitHub で見る →", destination: URL(string: rec.url)!)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                        }
                    }

                    // Past PRs
                    if !pr.submittedPRs.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("送信済み PR")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(pr.submittedPRs) { prec in
                            HStack {
                                Circle()
                                    .fill(prec.state == "open"
                                          ? Color(red: 0.3, green: 0.9, blue: 0.4)
                                          : Color.purple)
                                    .frame(width: 7, height: 7)
                                Link(prec.title, destination: URL(string: prec.url)!)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0))
                                Spacer()
                                Text(prec.state)
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
        }
    }

    // MARK: - Helpers

    private func infoBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.25))
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.80, green: 0.80, blue: 0.88))
        }
        .padding(10)
        .background(Color(red: 0.15, green: 0.14, blue: 0.08).opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 1.0, green: 0.85, blue: 0.25).opacity(0.3), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func labeledTextEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - GitHubConfigView

struct GitHubConfigView: View {
    @Binding var config: GitHubPREngine.Config
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub 設定")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 4)

            Group {
                configField("GitHub Token (repo + PR scope)", text: $config.githubToken, secure: true)
                configField("Upstream Owner (例: motonishikoudai)", text: $config.upstreamOwner)
                configField("Upstream Repo (例: verantyx-ide)", text: $config.upstreamRepo)
                configField("Your Fork Owner (あなたのGitHubユーザー名)", text: $config.yourForkOwner)
            }

            Button("保存") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Text("❗ Token は GITHUB_TOKEN 環境変数でも設定できます")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(red: 0.13, green: 0.13, blue: 0.17))
    }

    private func configField(_ label: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            if secure {
                SecureField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            } else {
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
