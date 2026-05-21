import Foundation
import OutlineView

/// One node in the memo tree.
///
/// `children` is the source-of-truth for kind: `nil` means a memo (leaf with
/// text content), any array value means a folder (branch — including empty
/// folders, which use `[]`). This matches the `kids != nil` predicate that
/// `OutlineView` uses to identify branches.
///
/// In-memory only — no persistence. The whole tree resets on app relaunch.
struct Item: Identifiable, Hashable {
	let id: UUID
	var name: String
	var children: [Item]?
	var memoText: String

	init(id: UUID = UUID(), name: String, children: [Item]? = nil, memoText: String = "") {
		self.id = id
		self.name = name
		self.children = children
		self.memoText = memoText
	}

	static func folder(_ name: String, _ children: [Item] = []) -> Item {
		Item(name: name, children: children)
	}

	static func memo(_ name: String, _ text: String = "") -> Item {
		Item(name: name, children: nil, memoText: text)
	}

	var isFolder: Bool { children != nil }
	var displayName: String { isFolder ? name : "\(name).txt" }
}

/// Sample seed tree shown on first launch. Includes an empty folder and a
/// root-level memo so the DnD smoke recipe works without manual setup.
enum SampleTree {
	static func seed() -> [Item] {
		[
			.folder("Travel", [
				.memo("Tokyo", "ramen, museums, Akihabara walk"),
				.memo("Kyoto", "Fushimi Inari at dawn, tea ceremony"),
			]),
			.folder("Recipes", [
				.memo("Pancakes", "1c flour, 1c milk, 1 egg, sugar, baking powder"),
				.memo("Toast", "bread, heat, butter"),
			]),
			.folder("Empty folder", []),
			.memo("Inbox", "drop ideas here"),
		]
	}
}

// MARK: - Tree operations

/// Returns true if any item in `subtree` (including `subtree` itself) has the
/// given id. Used to refuse drops that would orphan the source by landing on
/// or inside its own subtree.
func subtree(_ items: [Item], contains id: UUID) -> Bool {
	for item in items {
		if item.id == id { return true }
		if let kids = item.children, subtree(kids, contains: id) { return true }
	}
	return false
}

/// Remove the item with the given id from `items` (recursively). Returns the
/// removed item, or nil if not found.
@discardableResult
func removeItem(_ id: UUID, from items: inout [Item]) -> Item? {
	if let idx = items.firstIndex(where: { $0.id == id }) {
		return items.remove(at: idx)
	}
	for i in items.indices {
		guard items[i].children != nil else { continue }
		if let found = removeItem(id, from: &items[i].children!) {
			return found
		}
	}
	return nil
}

/// Insert `newItem` relative to the item identified by `target` and `position`.
/// Returns true on success, false if `target` couldn't be located.
@discardableResult
func insertItem(
	_ newItem: Item,
	relativeTo target: UUID,
	position: DropPosition,
	in items: inout [Item]
) -> Bool {
	if let idx = items.firstIndex(where: { $0.id == target }) {
		switch position {
		case .before:
			items.insert(newItem, at: idx)
		case .after:
			items.insert(newItem, at: idx + 1)
		case .on:
			if items[idx].children == nil {
				items[idx].children = []
			}
			items[idx].children!.append(newItem)
		}
		return true
	}
	for i in items.indices {
		guard items[i].children != nil else { continue }
		if insertItem(newItem, relativeTo: target, position: position, in: &items[i].children!) {
			return true
		}
	}
	return false
}

/// Locate the item with the given id; returns nil if not found.
func findItem(_ id: UUID, in items: [Item]) -> Item? {
	for item in items {
		if item.id == id { return item }
		if let kids = item.children, let found = findItem(id, in: kids) { return found }
	}
	return nil
}

/// Render the tree as 2-space-indented text. Folders end with `/`, memos with
/// `.txt`. Designed to paste cleanly into a code review or Slack DM.
func renderTreeAsText(_ items: [Item], depth: Int = 0) -> String {
	var lines: [String] = []
	let indent = String(repeating: "  ", count: depth)
	for item in items {
		if item.isFolder {
			lines.append("\(indent)\(item.name)/")
			if let kids = item.children, !kids.isEmpty {
				lines.append(renderTreeAsText(kids, depth: depth + 1))
			}
		} else {
			lines.append("\(indent)\(item.name).txt")
		}
	}
	return lines.joined(separator: "\n")
}
