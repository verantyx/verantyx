import SwiftUI

struct FormCardTemplate: View {
    let node: ASGNode
    
    var title: String? {
        return WorkspaceStateCore.shared.resolveString(node.properties?["title"])
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 16)
            }
            
            VStack(spacing: 0) {
                if let children = node.children, !children.isEmpty {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        ASGRenderer(node: child)
                            .padding()
                        
                        if index < children.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                } else {
                    Text("Empty Form")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
