import SwiftUI

/// Renders ASG Nodes into SwiftUI native views
struct ASGRenderer: View {
    let node: ASGNode
    @Bindable var stateCore = WorkspaceStateCore.shared
    
    var body: some View {
        renderNode(node)
    }
    
    @ViewBuilder
    private func renderNode(_ node: ASGNode) -> some View {
        switch node.type {
        case .container:
            if node.axis == "horizontal" {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(node.children ?? []) { child in
                        ASGRenderer(node: child)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(node.children ?? []) { child in
                        ASGRenderer(node: child)
                    }
                }
                .padding()
            }
            
        case .text:
            let resolvedText = WorkspaceStateCore.shared.resolveString(node.content) ?? ""
            Text(resolvedText)
                .font(fontForStyle(node.style))
                .foregroundColor(colorForStyle(node.style))
            
        case .button:
            Button(action: {
                if let action = WorkspaceStateCore.shared.resolveString(node.action) {
                    WorkspaceStateCore.shared.dispatchAction(action, nodeId: node.id)
                }
            }) {
                let resolvedLabel = WorkspaceStateCore.shared.resolveString(node.label) ?? "Button"
                Text(resolvedLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            
        case .input:
            // Dynamic binding via states dictionary
            let resolvedPlaceholder = WorkspaceStateCore.shared.resolveString(node.placeholder) ?? ""
            TextField(
                resolvedPlaceholder,
                text: Binding(
                    get: { WorkspaceStateCore.shared.inputStates[node.id] ?? "" },
                    set: { WorkspaceStateCore.shared.updateInputState(nodeId: node.id, text: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            
        case .thumbnail:
            ZStack {
                Color.gray.opacity(0.3)
                let resolvedUrl = WorkspaceStateCore.shared.resolveString(node.url) ?? ""
                Text("Image: \(resolvedUrl)")
                    .font(.caption)
            }
            .frame(width: 80, height: 80)
            .cornerRadius(8)
            
        case .template:
            // Route to the dedicated Template Registry
            TemplateRegistry.shared.resolve(node: node)
        }
    }
    
    // Helper to map style strings to fonts
    private func fontForStyle(_ style: String?) -> Font {
        switch style {
        case "headline": return .title.bold()
        case "body": return .body
        default: return .body
        }
    }
    
    private func colorForStyle(_ style: String?) -> Color {
        switch style {
        case "headline": return .primary
        case "secondary": return .secondary
        default: return .primary
        }
    }
}
