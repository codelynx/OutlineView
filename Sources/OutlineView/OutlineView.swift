import SwiftUI
import UniformTypeIdentifiers

/// A SwiftUI outline view for hierarchical data, working on macOS and iOS.
///
/// Renders a flat list of rows from a tree by flattening expanded subtrees,
/// owning row layout (indent + disclosure chevron + row content) itself.
/// Notably **does not** use `List(_:children:)` — selection, drag/drop, and
/// programmatic expand/collapse all want behaviors that `List` + `.onMove`
/// constrains.
///
/// Slices landed:
/// - **Slice 1** — selection (single-tap-to-replace) + programmatic expand.
/// - **Slice 2** — per-row drag source + per-row drop target with
///   above / on / below zones. Caller's `onDrop` callback decides accept.
///
/// Still to come: multi-select gestures (cmd-click / shift-click).
public struct OutlineView<Data, ID, RowContent>: View
where Data: RandomAccessCollection,
	  Data.Element: Identifiable,
	  ID == Data.Element.ID,
	  ID: Codable & Sendable,
	  RowContent: View
{
	private let data: Data
	private let children: KeyPath<Data.Element, Data?>
	@Binding private var selection: Set<ID>
	@Binding private var expanded: Set<ID>
	private let onDrop: ((OutlineDrop<ID>) -> Bool)?
	private let rowContent: (Data.Element) -> RowContent

	@State private var targetedRowID: ID? = nil

	static var rowHeight: CGFloat { 28 }
	static var indentPerDepth: CGFloat { 16 }

	public init(
		_ data: Data,
		children: KeyPath<Data.Element, Data?>,
		selection: Binding<Set<ID>>,
		expanded: Binding<Set<ID>>,
		onDrop: ((OutlineDrop<ID>) -> Bool)? = nil,
		@ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
	) {
		self.data = data
		self.children = children
		self._selection = selection
		self._expanded = expanded
		self.onDrop = onDrop
		self.rowContent = rowContent
	}

	public var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(flatRows, id: \.element.id) { row in
					rowView(for: row)
				}
			}
		}
	}

	private var flatRows: [FlatRow<Data.Element>] {
		flattenTree(data, children: children, expanded: expanded)
	}

	@ViewBuilder
	private func rowView(for row: FlatRow<Data.Element>) -> some View {
		let isSelected = selection.contains(row.element.id)
		let isTargeted = targetedRowID == row.element.id
		let base = HStack(spacing: 4) {
			Color.clear.frame(width: CGFloat(row.depth) * Self.indentPerDepth, height: 1)
			disclosureControl(for: row).frame(width: 16, height: 16)
			rowContent(row.element)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.frame(height: Self.rowHeight)
		.background(
			isSelected ? Color.accentColor.opacity(0.2) :
				isTargeted ? Color.accentColor.opacity(0.1) : Color.clear
		)
		.contentShape(Rectangle())
		.onTapGesture {
			selection = [row.element.id]
		}

		if let onDrop {
			base
				.draggable(OutlineDragItem(id: row.element.id))
				.dropDestination(for: OutlineDragItem<ID>.self) { items, location in
					guard let item = items.first else { return false }
					let position = resolveDropPosition(
						localY: location.y,
						rowHeight: Self.rowHeight,
						hasChildren: row.hasChildren
					)
					return onDrop(OutlineDrop(
						sourceID: item.id,
						targetID: row.element.id,
						position: position
					))
				} isTargeted: { targeted in
					if targeted {
						targetedRowID = row.element.id
					} else if targetedRowID == row.element.id {
						targetedRowID = nil
					}
				}
		} else {
			base
		}
	}

	@ViewBuilder
	private func disclosureControl(for row: FlatRow<Data.Element>) -> some View {
		if row.hasChildren {
			let isExpanded = expanded.contains(row.element.id)
			Button {
				if isExpanded {
					expanded.remove(row.element.id)
				} else {
					expanded.insert(row.element.id)
				}
			} label: {
				Image(systemName: "chevron.right")
					.font(.system(size: 10, weight: .semibold))
					.rotationEffect(.degrees(isExpanded ? 90 : 0))
					.foregroundStyle(.secondary)
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		} else {
			Color.clear
		}
	}
}

// MARK: - Public drop types

/// Where in a row's bounds the drag landed.
///
/// `.on` means the drop should land *inside* the target row (treating it as
/// a container — reparent the source under it). `.before` and `.after` mean
/// the drop should land between rows (reorder among the target's siblings).
public enum DropPosition: Sendable, Hashable {
	case before
	case on
	case after
}

/// Payload delivered to the caller's `onDrop` closure.
public struct OutlineDrop<ID: Hashable & Sendable>: Sendable, Hashable {
	public let sourceID: ID
	public let targetID: ID
	public let position: DropPosition

	public init(sourceID: ID, targetID: ID, position: DropPosition) {
		self.sourceID = sourceID
		self.targetID = targetID
		self.position = position
	}
}

// MARK: - Internal helpers (visible to tests)

/// One visible row in the flattened tree.
///
/// Internal: exposed only to the test target via `@testable import`.
struct FlatRow<Element: Identifiable>: Equatable where Element.ID: Hashable {
	let element: Element
	let depth: Int
	let hasChildren: Bool

	static func == (lhs: FlatRow<Element>, rhs: FlatRow<Element>) -> Bool {
		lhs.element.id == rhs.element.id && lhs.depth == rhs.depth && lhs.hasChildren == rhs.hasChildren
	}
}

/// Walk a tree depth-first, emitting one row per visible element. Children of
/// a node only appear if its `id` is in `expanded`. Free function (rather than
/// a method) so the test target can exercise it without standing up a view.
func flattenTree<Data, ID>(
	_ data: Data,
	children: KeyPath<Data.Element, Data?>,
	expanded: Set<ID>,
	depth: Int = 0
) -> [FlatRow<Data.Element>]
where Data: RandomAccessCollection,
	  Data.Element: Identifiable,
	  ID == Data.Element.ID
{
	var out: [FlatRow<Data.Element>] = []
	for item in data {
		let kids = item[keyPath: children]
		let hasKids = (kids?.isEmpty == false)
		out.append(FlatRow(element: item, depth: depth, hasChildren: hasKids))
		if hasKids, expanded.contains(item.id), let kids {
			out.append(contentsOf: flattenTree(kids, children: children, expanded: expanded, depth: depth + 1))
		}
	}
	return out
}

/// Resolve which of `.before` / `.on` / `.after` a drop at `localY` falls in.
///
/// Branch rows (`hasChildren == true`) use a 25% / 50% / 25% split. Leaf rows
/// have no `.on` zone (no container to drop *into*) and use a 50% / 50% split
/// between `.before` and `.after`.
func resolveDropPosition(localY: CGFloat, rowHeight: CGFloat, hasChildren: Bool) -> DropPosition {
	guard rowHeight > 0 else { return .on }
	let fraction = max(0, min(1, localY / rowHeight))
	if hasChildren {
		if fraction < 0.25 { return .before }
		if fraction > 0.75 { return .after }
		return .on
	} else {
		return fraction < 0.5 ? .before : .after
	}
}

/// Drag payload — wraps the row's ID so SwiftUI can deliver it to the drop
/// destination's `onDrop` callback. Private to the package; callers never
/// construct it directly.
struct OutlineDragItem<ID: Codable & Hashable & Sendable>: Codable, Hashable, Transferable {
	let id: ID

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .data)
	}
}
