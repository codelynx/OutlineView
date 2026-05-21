import SwiftUI

/// A SwiftUI outline view for hierarchical data, working on macOS and iOS.
///
/// Renders a flat list of rows from a tree by flattening expanded subtrees,
/// owning row layout (indent + disclosure chevron + row content) itself.
/// Notably **does not** use `List(_:children:)` — selection, drag/drop, and
/// programmatic expand/collapse all want behaviors that `List` + `.onMove`
/// constrains.
///
/// Slice 1 scope: selection (single-tap-to-replace) + programmatic expand.
/// Drag/drop and multi-select gestures (cmd-click / shift-click) land later.
public struct OutlineView<Data, ID, RowContent>: View
where Data: RandomAccessCollection,
	  Data.Element: Identifiable,
	  ID == Data.Element.ID,
	  RowContent: View
{
	private let data: Data
	private let children: KeyPath<Data.Element, Data?>
	@Binding private var selection: Set<ID>
	@Binding private var expanded: Set<ID>
	private let rowContent: (Data.Element) -> RowContent

	public init(
		_ data: Data,
		children: KeyPath<Data.Element, Data?>,
		selection: Binding<Set<ID>>,
		expanded: Binding<Set<ID>>,
		@ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
	) {
		self.data = data
		self.children = children
		self._selection = selection
		self._expanded = expanded
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
		HStack(spacing: 4) {
			Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
			disclosureControl(for: row)
				.frame(width: 16, height: 16)
			rowContent(row.element)
			Spacer(minLength: 0)
		}
		.padding(.vertical, 4)
		.padding(.horizontal, 8)
		.background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
		.contentShape(Rectangle())
		.onTapGesture {
			selection = [row.element.id]
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
