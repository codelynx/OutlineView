import SwiftUI
import OutlineView
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
	@State private var items: [Item] = SampleTree.seed()
	@State private var selection: Set<UUID> = []
	@State private var expanded: Set<UUID> = []
	@State private var dropLog: [String] = []
	@State private var lastCopyConfirmation: String? = nil

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			Divider()
			treeArea
			Divider()
			footer
		}
		.onAppear {
			// Auto-expand the two seed folders that have children so the
			// smoke recipe lands on a useful starting view.
			expanded = Set(items.filter { !($0.children?.isEmpty ?? true) }.map(\.id))
		}
	}

	// MARK: - Toolbar

	private var toolbar: some View {
		HStack(spacing: 8) {
			Button {
				addItem(.folder("New Folder"))
			} label: {
				Label("New Folder", systemImage: "folder.badge.plus")
			}
			Button {
				addItem(.memo("Untitled"))
			} label: {
				Label("New Memo", systemImage: "doc.badge.plus")
			}
			Spacer()
			Button {
				copyStructureToClipboard()
			} label: {
				Label("Copy structure", systemImage: "doc.on.clipboard")
			}
		}
		.padding(8)
	}

	// MARK: - Tree

	private var treeArea: some View {
		OutlineView(
			items,
			children: \.children,
			selection: $selection,
			expanded: $expanded,
			onDrop: handleDrop
		) { item in
			rowLabel(for: item)
		}
	}

	private func rowLabel(for item: Item) -> some View {
		HStack(spacing: 6) {
			Image(systemName: item.isFolder ? "folder" : "doc.text")
				.foregroundStyle(item.isFolder ? .blue : .secondary)
			Text(item.displayName)
		}
	}

	// MARK: - Footer

	private var footer: some View {
		VStack(alignment: .leading, spacing: 4) {
			if let confirmation = lastCopyConfirmation {
				Text(confirmation)
					.font(.caption)
					.foregroundStyle(.green)
			}
			Text("Drop log (most recent first)")
				.font(.caption2)
				.foregroundStyle(.secondary)
			if dropLog.isEmpty {
				Text("Drag a row onto another row to see the resolved position.")
					.font(.caption)
					.foregroundStyle(.tertiary)
			} else {
				ForEach(dropLog.prefix(4), id: \.self) { line in
					Text(line)
						.font(.caption.monospaced())
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(8)
		.background(Color.secondary.opacity(0.08))
	}

	// MARK: - Actions

	private func addItem(_ newItem: Item) {
		// Insert at the end of the selected folder's children, or at root if
		// no folder is selected. The freshly created item is always visible
		// at the bottom of its parent.
		if let selectedID = selection.first,
		   let selected = findItem(selectedID, in: items),
		   selected.isFolder {
			insertItem(newItem, relativeTo: selectedID, position: .on, in: &items)
			expanded.insert(selectedID)
		} else {
			items.append(newItem)
		}
		selection = [newItem.id]
	}

	private func handleDrop(_ drop: OutlineDrop<UUID>) -> Bool {
		// Snapshot names before mutation so the log line is useful even after
		// the source moves.
		let sourceName = findItem(drop.sourceID, in: items)?.displayName ?? drop.sourceID.shortDescription
		let targetName = findItem(drop.targetID, in: items)?.displayName ?? drop.targetID.shortDescription

		guard drop.sourceID != drop.targetID else {
			logDrop(drop, sourceName: sourceName, targetName: targetName, accepted: false, note: "self-drop")
			return false
		}

		// Refuse drop onto own subtree — would orphan the moved item.
		if let sourceItem = findItem(drop.sourceID, in: items),
		   subtree([sourceItem], contains: drop.targetID) {
			logDrop(drop, sourceName: sourceName, targetName: targetName, accepted: false, note: "would land in own subtree")
			return false
		}

		guard let moved = removeItem(drop.sourceID, from: &items) else { return false }
		let inserted = insertItem(moved, relativeTo: drop.targetID, position: drop.position, in: &items)
		if !inserted {
			// Insertion target vanished mid-flight (shouldn't happen here,
			// but be safe): restore at root tail so we don't lose the item.
			items.append(moved)
		}
		logDrop(drop, sourceName: sourceName, targetName: targetName, accepted: inserted)
		return inserted
	}

	private func copyStructureToClipboard() {
		let text = renderTreeAsText(items)
		copyToClipboard(text)
		lastCopyConfirmation = "Copied \(items.flatCount) items to clipboard."
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 1_800_000_000)
			lastCopyConfirmation = nil
		}
	}

	// MARK: - Logging

	private func logDrop(
		_ drop: OutlineDrop<UUID>,
		sourceName: String,
		targetName: String,
		accepted: Bool,
		note: String? = nil
	) {
		let verb: String
		switch drop.position {
		case .before: verb = "BEFORE"
		case .on:     verb = "ON"
		case .after:  verb = "AFTER"
		}
		let status = accepted ? "✓" : "✗"
		var line = "\(status) \(sourceName) → \(verb) \(targetName)"
		if let note { line += "  (\(note))" }
		dropLog.insert(line, at: 0)
		if dropLog.count > 10 { dropLog.removeLast(dropLog.count - 10) }
	}
}

// MARK: - Helpers

private extension Array where Element == Item {
	/// Recursive count of all items (folders + memos) in the tree.
	var flatCount: Int {
		var n = 0
		for item in self {
			n += 1
			if let kids = item.children { n += kids.flatCount }
		}
		return n
	}
}

private extension UUID {
	var shortDescription: String { String(uuidString.prefix(8)) }
}

private func copyToClipboard(_ text: String) {
	#if canImport(AppKit)
	NSPasteboard.general.clearContents()
	NSPasteboard.general.setString(text, forType: .string)
	#elseif canImport(UIKit)
	UIPasteboard.general.string = text
	#endif
}

#Preview {
	ContentView()
		.frame(width: 480, height: 540)
}
