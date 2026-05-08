import SwiftUI

struct ChatMessageTemplate: View {
    let node: ASGNode
    
    var isUser: Bool {
        let senderStr = WorkspaceStateCore.shared.resolveString(node.properties?["sender"])
        return senderStr == "user"
    }
    
    var senderName: String {
        let nameStr = WorkspaceStateCore.shared.resolveString(node.properties?["senderName"])
        return nameStr ?? (isUser ? "You" : "AI")
    }
    
    var messageText: String? {
        return WorkspaceStateCore.shared.resolveString(node.properties?["text"])
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer() // Push to right
            } else {
                // AI Avatar
                Circle()
                    .fill(Color.orange.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .overlay(Text(String(senderName.prefix(1))).font(.caption).foregroundColor(.white))
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(senderName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    if let text = messageText {
                        Text(text)
                            .font(.body)
                    }
                    
                    // Render any embedded complex children (e.g. inner code blocks, thumbnails)
                    if let children = node.children, !children.isEmpty {
                        ForEach(children) { child in
                            ASGRenderer(node: child)
                        }
                    }
                }
                .padding(12)
                .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                .foregroundColor(isUser ? .white : .primary)
                .cornerRadius(16)
            }
            
            if !isUser {
                Spacer() // Push to left
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
