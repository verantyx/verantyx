import SwiftUI

/// A central registry for dynamic layout components
struct TemplateRegistry {
    static let shared = TemplateRegistry()
    
    private init() {}
    
    @ViewBuilder
    func resolve(node: ASGNode) -> some View {
        if let templateName = node.templateName {
            switch templateName {
            case "chat_message":
                ChatMessageTemplate(node: node)
            case "side_navigation":
                SidebarTemplate(node: node)
            case "form_card":
                FormCardTemplate(node: node)
            default:
                fallbackView(name: templateName)
            }
        } else {
            fallbackView(name: "Unknown Template")
        }
    }
    
    private func fallbackView(name: String) -> some View {
        VStack {
            Text("Missing Template: \(name)")
                .font(.caption)
                .foregroundColor(.red)
        }
        .padding()
        .border(Color.red, width: 1)
    }
}
