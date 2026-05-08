import SwiftUI

struct SidebarTemplate: View {
    let node: ASGNode
    
    var title: String {
        return WorkspaceStateCore.shared.resolveString(node.properties?["title"]) ?? "Menu"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    if let action = WorkspaceStateCore.shared.resolveString(node.properties?["closeAction"]) {
                        WorkspaceStateCore.shared.dispatchAction(action, nodeId: node.id)
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let children = node.children {
                        ForEach(children) { child in
                            ASGRenderer(node: child)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: 300) // Fixed max width for sidebar feel
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
    }
}
