import Foundation

/// Core state manager for pure ASG-based UI event dispatching
@Observable
class WorkspaceStateCore {
    /// Maps node IDs to current input text values
    var inputStates: [String: String] = [:]
    
    /// The latest UI configuration from the Mac Decomposer
    var liveSchema: ASGNode?
    
    /// Global Semantic Dictionary mapped from STR_N identifiers to text
    var semanticDictionary: [String: String] = [:]
    
    private var webSocketTask: URLSessionWebSocketTask?
    
    static let shared = WorkspaceStateCore()
    
    private init() {}
    
    func dispatchAction(_ action: String, nodeId: String) {
        print("🟢 [WorkspaceStateCore] Action Dispatched: \(action) from Node: \(nodeId)")
        
        // If there's an associated input state for this action context, log it too
        if action == "add_task_action" {
            let text = inputStates["new_task_input"] ?? ""
            print("   -> Attached State: new_task_input = '\(text)'")
            
            // Mock clear state after send
            inputStates["new_task_input"] = ""
        }
        
        // Forward to Mac
        sendActionToMac(action: action, nodeId: nodeId)
    }
    
    func updateInputState(nodeId: String, text: String) {
        inputStates[nodeId] = text
        print("🔵 [WorkspaceStateCore] Input State Updated -> \(nodeId): \(text)")
    }
    
    // MARK: - WebSocket Client
    
    func connect() {
        guard let url = URL(string: "ws://localhost:8080") else { return }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        print("🌐 Connecting to Mac WebSocket...")
        receiveMessages()
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("❌ WebSocket Receive Error: \(error)")
                // Try reconnecting after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.connect()
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.parseLiveSchema(jsonString: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.parseLiveSchema(jsonString: text)
                    }
                @unknown default:
                    break
                }
                // Keep listening
                self?.receiveMessages()
            }
        }
    }
    
    private func parseLiveSchema(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            // Try to decode as the new Payload first
            if let payload = try? decoder.decode(ASGPayload.self, from: data) {
                DispatchQueue.main.async {
                    // Merge new dictionary items
                    for (k, v) in payload.dictionary {
                        self.semanticDictionary[k] = v
                    }
                    self.liveSchema = payload.topology
                }
            } else {
                // Fallback for mock_schema or legacy formats
                let schema = try decoder.decode(ASGNode.self, from: data)
                DispatchQueue.main.async {
                    self.liveSchema = schema
                }
            }
        } catch {
            print("⚠️ Failed to parse live schema: \(error)")
        }
    }
    
    /// Helper to rehydrate internal string IDs
    func resolveString(_ input: String?) -> String? {
        guard let text = input else { return nil }
        return semanticDictionary[text] ?? text
    }
    
    private func sendActionToMac(action: String, nodeId: String) {
        let payload = "{\"action\": \"\(action)\", \"nodeId\": \"\(nodeId)\"}"
        let message = URLSessionWebSocketTask.Message.string(payload)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ WebSocket Send Error: \(error)")
            }
        }
    }
}
