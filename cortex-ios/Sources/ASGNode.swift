import Foundation
import SwiftUI

/// Abstract Semantic Graph (ASG) Node Enum
enum ASGNodeType: String, Codable {
    case container
    case text
    case input
    case button
    case thumbnail
    case template
}

/// Abstract Semantic Graph (ASG) Node structural representation
struct ASGNode: Codable, Identifiable {
    let id: String
    let type: ASGNodeType
    
    // Optional properties depending on the node type
    let axis: String? // "vertical", "horizontal", "z" (for container)
    let content: String? // for text
    let label: String? // for button label
    let placeholder: String? // for input
    let url: String? // for thumbnail
    let style: String? // "headline", "body", "primary", "secondary"
    let action: String? // action identifier mapped to the event
    
    // Template specific properties
    let templateName: String? // "chat_message", "sidebar"
    let properties: [String: String]? // Dynamic properties mapping (e.g. "sender": "Claude")
    
    // Recursive children
    let children: [ASGNode]?
    
    // Enforce decode and encode manually if needed, but standard synth is okay if types match
}

/// The root payload separating the Dictionary and Topology
struct ASGPayload: Codable {
    let dictionary: [String: String]
    let topology: ASGNode
}
