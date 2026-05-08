import SwiftUI

struct DynamicWorkspaceView: View {
    @State private var rootSchema: ASGNode?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                // Prioritize live schema over mock
                if let schema = WorkspaceStateCore.shared.liveSchema ?? rootSchema {
                    ASGRenderer(node: schema)
                        .padding()
                } else if let error = loadError {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .font(.largeTitle)
                        Text("Schema Load Error:")
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    ProgressView("Connecting to Mac Decomposer...")
                }
            }
            .navigationTitle("Verantyx Workspace")
            .onAppear {
                WorkspaceStateCore.shared.connect()
                loadSchema()
            }
        }
    }
    
    private func loadSchema() {
        // Attempt to load mock_advanced_schema.json from the bundle
        guard let url = Bundle.main.url(forResource: "mock_advanced_schema", withExtension: "json") else {
            self.loadError = "mock_advanced_schema.json not found in bundle."
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            if let payload = try? decoder.decode(ASGPayload.self, from: data) {
                // Initialize global dictionary
                for (k, v) in payload.dictionary {
                    WorkspaceStateCore.shared.semanticDictionary[k] = v
                }
                self.rootSchema = payload.topology
            } else {
                let schema = try decoder.decode(ASGNode.self, from: data)
                self.rootSchema = schema
            }
        } catch {
            self.loadError = error.localizedDescription
            print("❌ Decoder Error: \(error)")
        }
    }
}

#Preview {
    DynamicWorkspaceView()
}
