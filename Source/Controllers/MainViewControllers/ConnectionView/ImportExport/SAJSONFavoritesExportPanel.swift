import AppKit
import UniformTypeIdentifiers

@objc final class SAJSONFavoritesExportPanel: NSObject {
    @objc(presentForNodes:window:keychain:plistExport:)
    static func present(nodes: [SPTreeNode], window: NSWindow, keychain: SAKeychainProviding, plistExport: @escaping () -> Void) {
        guard !nodes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Export Favorites", comment: "Favorites export format chooser title")
        alert.informativeText = NSLocalizedString(
            "Choose an export format. JSON includes retrievable saved passwords as plaintext and preserves up to five folder levels. Connections without a retrievable password are exported without the Password field.",
            comment: "Favorites export format and plaintext password explanation")
        alert.addButton(withTitle: NSLocalizedString("Plist Without Passwords", comment: "Legacy favorites export choice"))
        alert.addButton(withTitle: NSLocalizedString("JSON With Plaintext Passwords", comment: "JSON plaintext favorites export choice"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { plistExport() }
            if response == .alertSecondButtonReturn { save(nodes: nodes, window: window, keychain: keychain) }
        }
    }

    /// Preserve a leaf's full folder path even when only that leaf is selected.
    /// Selecting a group and its descendant exports each leaf exactly once.
    static func connections(from nodes: [SPTreeNode]) -> [SAJSONExportConnection] {
        var visited = Set<ObjectIdentifier>()
        var result: [SAJSONExportConnection] = []
        func collect(_ node: SPTreeNode) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isGroup {
                for child in node.children ?? [] { collect(child) }
            } else if let favorite = (node.representedObject as? SPFavoriteNode)?.nodeFavorite {
                var path: [String] = []
                var ancestor = node.parent
                // Exclude the virtual root and the built-in Favorites container.
                while let group = ancestor, group.parent?.parent != nil {
                    if let name = (group.representedObject as? SPGroupNode)?.nodeName { path.insert(name, at: 0) }
                    ancestor = group.parent
                }
                result.append(SAJSONExportConnection(favorite: NSDictionary(dictionary: favorite), groupPath: path))
            }
        }
        for node in nodes { collect(node) }
        return result
    }

    private static func save(nodes: [SPTreeNode], window: NSWindow, keychain: SAKeychainProviding) {
        let snapshot = connections(from: nodes)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "connections.json"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Delay password reads until the user accepts the save panel.
                let data = try SAJSONFavoritesExport.data(connections: snapshot, keychain: keychain)
                try data.write(to: url, options: [.atomic])
            } catch {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Favorites export error", comment: "Favorites export error title")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
                alert.beginSheetModal(for: window)
            }
        }
    }
}
