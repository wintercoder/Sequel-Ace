import AppKit

/// App-only bridge for placing validated JSON favorites into existing folders.
@objc final class SAJSONFavoritePlacement: NSObject {
    @objc(addFavorite:path:controller:)
    static func addFavorite(_ favorite: NSMutableDictionary, path: [String], controller: SPFavoritesController) -> SPTreeNode {
        controller.addFavoriteNode(withData: favorite, asChildOf: folder(path: path, controller: controller))
    }

    @objc(moveFavorite:path:controller:)
    static func moveFavorite(_ node: SPTreeNode, path: [String], controller: SPFavoritesController) {
        // No grouping fields preserves an updated favorite's current folder.
        guard !path.isEmpty, let destination = folder(path: path, controller: controller),
              node.parent !== destination else { return }
        node.parent?.mutableChildren.remove(node)
        destination.mutableChildren.add(node)
        controller.saveFavorites()
    }

    private static func folder(path: [String], controller: SPFavoritesController) -> SPTreeNode? {
        guard !path.isEmpty, var parent = controller.favoritesTree.children?.first as? SPTreeNode else { return nil }
        for name in path {
            if let existing = parent.children?.first(where: {
                $0.isGroup && ($0.representedObject as? SPGroupNode)?.nodeName == name
            }) {
                parent = existing
            } else {
                parent = controller.addGroupNode(withName: name, asChildOf: parent)
            }
            (parent.representedObject as? SPGroupNode)?.nodeIsExpanded = true
        }
        return parent
    }
}
