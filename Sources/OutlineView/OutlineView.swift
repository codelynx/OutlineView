import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A SwiftUI outline view for hierarchical data on macOS and iOS.
///
/// Renders a flat list of rows from a tree by flattening expanded subtrees,
/// owning row layout itself: indentation, disclosure chevron, selection
/// background, row content, and drag/drop indicators.
///
/// `OutlineView` does not use `List(_:children:)`. Selection, programmatic
/// expansion, root drops, and row-relative move destinations are all controlled
/// by the caller through explicit bindings and callbacks.
///
/// Branches are identified by the presence of a children collection:
/// `children == nil` is a leaf, while `children != nil` is a branch, including
/// an empty branch with `[]`. That lets an empty folder or group remain a valid
/// "drop inside" destination.
public struct OutlineView<Data, ID, RowContent, ContextMenuContent>: View
where Data: RandomAccessCollection,
	  Data.Element: Identifiable,
	  ID == Data.Element.ID,
	  ID: Hashable & Sendable,
	  RowContent: View,
	  ContextMenuContent: View
{
	private let data: Data
	private let children: KeyPath<Data.Element, Data?>
	@Binding private var selection: Set<ID>
	@Binding private var expanded: Set<ID>
	private let onMove: ((OutlineMove<ID>) -> Bool)?
	private let acceptsRootDrop: Bool
	private let rowContent: (Data.Element) -> RowContent
	private let contextMenuContent: ((Data.Element) -> ContextMenuContent)?

	@State private var targetedZone: DropHighlight<ID>? = nil
	@State private var rootDropTargeted = false
	@State private var dragSourcesByToken: [UUID: ID] = [:]

	static var rowHeight: CGFloat { 28 }
	static var indentPerDepth: CGFloat { 16 }
	static var insertionLineHeight: CGFloat { 2 }
	static var insertionDotDiameter: CGFloat { 6 }
	/// Horizontal padding applied to the row's outer edges.
	static var rowOuterPadding: CGFloat { 8 }
	/// Width of the chevron column (present on every row to keep depth math aligned).
	static var chevronColumnWidth: CGFloat { 16 }
	/// HStack spacing inside the row.
	static var rowHStackSpacing: CGFloat { 4 }

	public init(
		_ data: Data,
		children: KeyPath<Data.Element, Data?>,
		selection: Binding<Set<ID>>,
		expanded: Binding<Set<ID>>,
		onDrop: ((OutlineDrop<ID>) -> Bool)? = nil,
		@ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
	) where ContextMenuContent == EmptyView {
		self.data = data
		self.children = children
		self._selection = selection
		self._expanded = expanded
		self.onMove = onDrop.map { legacyOnDrop in
			{ move in
				guard let drop = OutlineDrop(move) else { return false }
				return legacyOnDrop(drop)
			}
		}
		self.acceptsRootDrop = false
		self.rowContent = rowContent
		self.contextMenuContent = nil
	}

	/// Creates an outline with the preferred generic move callback.
	///
	/// Use this initializer when the model supports reordering or reparenting.
	/// `onMove` receives root, before, inside, and after destinations; the
	/// caller owns validation and mutation of the backing tree.
	public init(
		_ data: Data,
		children: KeyPath<Data.Element, Data?>,
		selection: Binding<Set<ID>>,
		expanded: Binding<Set<ID>>,
		onMove: @escaping (OutlineMove<ID>) -> Bool,
		@ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
	) where ContextMenuContent == EmptyView {
		self.data = data
		self.children = children
		self._selection = selection
		self._expanded = expanded
		self.onMove = onMove
		self.acceptsRootDrop = true
		self.rowContent = rowContent
		self.contextMenuContent = nil
	}

	/// Creates an outline with row-relative move handling and caller-supplied
	/// row context menus.
	///
	/// Context menus are attached to the final row surface after the drag/drop
	/// overlay. This keeps secondary-click and long-press menus reachable even
	/// when drop zones own row hit testing.
	public init(
		_ data: Data,
		children: KeyPath<Data.Element, Data?>,
		selection: Binding<Set<ID>>,
		expanded: Binding<Set<ID>>,
		onMove: @escaping (OutlineMove<ID>) -> Bool,
		@ViewBuilder rowContent: @escaping (Data.Element) -> RowContent,
		@ViewBuilder contextMenu: @escaping (Data.Element) -> ContextMenuContent
	) {
		self.data = data
		self.children = children
		self._selection = selection
		self._expanded = expanded
		self.onMove = onMove
		self.acceptsRootDrop = true
		self.rowContent = rowContent
		self.contextMenuContent = contextMenu
	}

	public var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(flatRows, id: \.element.id) { row in
					rowView(for: row)
				}
				rootDropZone
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var flatRows: [FlatRow<Data.Element>] {
		flattenTree(data, children: children, expanded: expanded)
	}

	@ViewBuilder
	private func rowView(for row: FlatRow<Data.Element>) -> some View {
		let id = row.element.id
		let isSelected = selection.contains(id)
		let onTargeted = isZoneTargeted(id, .on)
		let beforeTargeted = isZoneTargeted(id, .before)
		let afterTargeted = isZoneTargeted(id, .after)

		let base = HStack(spacing: Self.rowHStackSpacing) {
			Color.clear.frame(width: CGFloat(row.depth) * Self.indentPerDepth, height: 1)
			disclosureControl(for: row).frame(width: Self.chevronColumnWidth, height: 16)
			rowContent(row.element)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, Self.rowOuterPadding)
		.frame(height: Self.rowHeight)
		.background(rowBackground(isSelected: isSelected, onTargeted: onTargeted))
		.overlay(alignment: .topLeading) {
			insertionLine(at: row.depth)
				.offset(y: -Self.insertionDotDiameter / 2)
				.opacity(beforeTargeted ? 1 : 0)
		}
		.overlay(alignment: .bottomLeading) {
			insertionLine(at: row.depth)
				.offset(y: Self.insertionDotDiameter / 2)
				.opacity(afterTargeted ? 1 : 0)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			selection = [id]
		}

		if let contextMenuContent {
			rowSurface(base, for: row).contextMenu {
				contextMenuContent(row.element)
			}
		} else {
			rowSurface(base, for: row)
		}
	}

	@ViewBuilder
	private func rowSurface<Content: View>(_ base: Content, for row: FlatRow<Data.Element>) -> some View {
		if onMove != nil {
			base.overlay {
				dropZoneOverlay(for: row)
			}
		} else {
			base
		}
	}

	@ViewBuilder
	private func rowBackground(isSelected: Bool, onTargeted: Bool) -> some View {
		if isSelected {
			Color.accentColor.opacity(0.2)
		} else if onTargeted {
			Color.accentColor.opacity(0.25)
		} else {
			Color.clear
		}
	}

	/// Depth-aware drop insertion indicator (NSOutlineView-style).
	///
	/// Renders as `o─────────` — a small filled dot at the depth's content
	/// leading edge, with a thin line extending to the row's trailing edge.
	/// The dot's horizontal position is the visual disambiguator between
	/// neighboring `.before X` and `.after Y` zones at row boundaries: the
	/// dot lands at the depth of the row whose zone is targeted, so the
	/// indent of the dot tells the user which depth they're about to drop
	/// into. Without this, a single-pixel cursor adjustment silently swaps
	/// the resulting tree shape — see Slice 3c smoke notes.
	private func insertionLine(at depth: Int) -> some View {
		HStack(spacing: 0) {
			Color.clear.frame(width: contentLeadingOffset(depth: depth))
			Circle()
				.fill(Color.accentColor)
				.frame(width: Self.insertionDotDiameter, height: Self.insertionDotDiameter)
			Rectangle()
				.fill(Color.accentColor)
				.frame(height: Self.insertionLineHeight)
		}
		.frame(height: Self.insertionDotDiameter)
	}

	/// Leading offset at which a row's content (icon + name) begins, for the
	/// given depth. Mirrors the row HStack layout so the insertion dot lines
	/// up exactly with where a freshly-inserted item's icon would sit.
	private func contentLeadingOffset(depth: Int) -> CGFloat {
		Self.rowOuterPadding
			+ CGFloat(depth) * Self.indentPerDepth
			+ Self.rowHStackSpacing
			+ Self.chevronColumnWidth
			+ Self.rowHStackSpacing
	}

	@ViewBuilder
	private func dropZoneOverlay(for row: FlatRow<Data.Element>) -> some View {
		let fractions = dropZoneFractions(isBranch: row.isBranch)
		// Inset the leading edge past the chevron column so the disclosure
		// button underneath remains clickable. Without the inset, the drop
		// zone's `.contentShape(Rectangle())` claims hit-testing across the
		// whole row width and intercepts clicks before they reach the chevron.
		HStack(spacing: 0) {
			Color.clear
				.frame(width: chevronTrailingEdge(depth: row.depth))
				.allowsHitTesting(false)
			VStack(spacing: 0) {
				dropZone(.before, fraction: fractions.before, sourceItem: row.element)
				if let onFraction = fractions.on {
					dropZone(.on, fraction: onFraction, sourceItem: row.element)
				}
				dropZone(.after, fraction: fractions.after, sourceItem: row.element)
			}
		}
	}

	@ViewBuilder
	private var rootDropZone: some View {
		if acceptsRootDrop, let onMove {
			RootDropZone(
				dragSourcesByToken: $dragSourcesByToken,
				isTargeted: $rootDropTargeted,
				onMove: onMove
			)
			.frame(height: flatRows.isEmpty ? Self.rowHeight * 4 : Self.rowHeight)
			.frame(maxWidth: .infinity)
			.background(rootDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
			.overlay(alignment: .topLeading) {
				insertionLine(at: 0)
					.offset(y: -Self.insertionDotDiameter / 2)
					.opacity(rootDropTargeted ? 1 : 0)
			}
		}
	}

	/// Leading offset at which the chevron column ends. Drop zones start here
	/// so the disclosure button stays exposed to taps above the overlay.
	private func chevronTrailingEdge(depth: Int) -> CGFloat {
		Self.rowOuterPadding
			+ CGFloat(depth) * Self.indentPerDepth
			+ Self.rowHStackSpacing
			+ Self.chevronColumnWidth
	}

	@ViewBuilder
	private func dropZone(_ position: DropPosition, fraction: CGFloat, sourceItem: Data.Element) -> some View {
		if let onMove {
			RowDropZone(
				sourceID: sourceItem.id,
				targetID: sourceItem.id,
				position: position,
				fraction: fraction,
				rowHeight: Self.rowHeight,
				dragSourcesByToken: $dragSourcesByToken,
				onMove: onMove,
				onSelect: {
					selection = [sourceItem.id]
				},
				onTargeted: { targeted in
					let entry = DropHighlight(rowID: sourceItem.id, position: position)
					if targeted {
						targetedZone = entry
					} else if targetedZone == entry {
						targetedZone = nil
					}
				},
				preview: {
					dragPreview(for: sourceItem)
				}
			)
		}
	}

	/// Small preview shown under the cursor / finger while a row is being
	/// dragged. Renders the caller's `rowContent` for the dragged item with
	/// a subtle material background so it reads as "the row, in flight."
	private func dragPreview(for item: Data.Element) -> some View {
		HStack(spacing: Self.rowHStackSpacing) {
			rowContent(item)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
	}

	private func isZoneTargeted(_ id: ID, _ position: DropPosition) -> Bool {
		targetedZone?.rowID == id && targetedZone?.position == position
	}

	@ViewBuilder
	private func disclosureControl(for row: FlatRow<Data.Element>) -> some View {
		if row.isBranch {
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
/// This type is used by the legacy `onDrop` API.
public enum DropPosition: Sendable, Hashable {
	case before
	case on
	case after
}

/// Destination for an intra-outline move.
///
/// This is the preferred callback payload for generic tree UIs because it can
/// express row-relative drops and root-level drops without forcing callers to
/// reinterpret a target row as a parent.
public enum OutlineMoveDestination<ID: Hashable & Sendable>: Sendable, Hashable {
	/// Move to the root level. Callers usually append or place at the root tail.
	case root
	/// Move before the target row in the target row's sibling collection.
	case before(ID)
	/// Move inside the target row, treating it as the destination parent.
	case inside(ID)
	/// Move after the target row in the target row's sibling collection.
	case after(ID)

	/// The row-relative target ID, or `nil` for root moves.
	public var targetID: ID? {
		switch self {
		case .root:
			return nil
		case let .before(id), let .inside(id), let .after(id):
			return id
		}
	}
}

/// Payload delivered to the caller's `onMove` closure.
///
/// The outline only reports the user's intent. The caller decides whether the
/// move is legal, mutates its model if accepted, and returns `true` or `false`.
public struct OutlineMove<ID: Hashable & Sendable>: Sendable, Hashable {
	/// The dragged row's ID.
	public let sourceID: ID
	/// The requested destination.
	public let destination: OutlineMoveDestination<ID>

	public init(sourceID: ID, destination: OutlineMoveDestination<ID>) {
		self.sourceID = sourceID
		self.destination = destination
	}
}

/// Payload delivered to the caller's legacy `onDrop` closure.
///
/// `OutlineDrop` cannot represent root drops. Prefer `OutlineMove` for new
/// code, especially for directory browsers and other generic tree controls.
public struct OutlineDrop<ID: Hashable & Sendable>: Sendable, Hashable {
	/// The dragged row's ID.
	public let sourceID: ID
	/// The row-relative target ID.
	public let targetID: ID
	/// The requested row-relative position.
	public let position: DropPosition

	public init(sourceID: ID, targetID: ID, position: DropPosition) {
		self.sourceID = sourceID
		self.targetID = targetID
		self.position = position
	}

	/// Converts a row-relative `OutlineMove` into the legacy drop payload.
	/// Returns `nil` for `.root` because `OutlineDrop` has no root case.
	public init?(_ move: OutlineMove<ID>) {
		switch move.destination {
		case .root:
			return nil
		case let .before(targetID):
			self.init(sourceID: move.sourceID, targetID: targetID, position: .before)
		case let .inside(targetID):
			self.init(sourceID: move.sourceID, targetID: targetID, position: .on)
		case let .after(targetID):
			self.init(sourceID: move.sourceID, targetID: targetID, position: .after)
		}
	}
}

private extension DropPosition {
	func moveDestination<ID: Hashable & Sendable>(relativeTo targetID: ID) -> OutlineMoveDestination<ID> {
		switch self {
		case .before: return .before(targetID)
		case .on:     return .inside(targetID)
		case .after:  return .after(targetID)
		}
	}
}

// MARK: - Internal helpers (visible to tests)

/// One visible row in the flattened tree.
///
/// `isBranch` means "this element has a children container" (`kids != nil`),
/// regardless of whether the container is empty. An empty branch still gets
/// `isBranch == true` and is therefore a valid `.on` drop target — that's
/// the fix for the empty-group-is-not-droppable trap that motivated leaving
/// `List(_:children:)` in the first place.
///
/// Internal: exposed only to the test target via `@testable import`.
struct FlatRow<Element: Identifiable>: Equatable where Element.ID: Hashable {
	let element: Element
	let depth: Int
	let isBranch: Bool

	static func == (lhs: FlatRow<Element>, rhs: FlatRow<Element>) -> Bool {
		lhs.element.id == rhs.element.id && lhs.depth == rhs.depth && lhs.isBranch == rhs.isBranch
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
		let isBranch = (kids != nil)
		out.append(FlatRow(element: item, depth: depth, isBranch: isBranch))
		if isBranch, expanded.contains(item.id), let kids {
			out.append(contentsOf: flattenTree(kids, children: children, expanded: expanded, depth: depth + 1))
		}
	}
	return out
}

/// Fractional heights of the per-row drop zones.
///
/// Branch rows: 25% `.before`, 50% `.on`, 25% `.after`. Leaf rows: 50% `.before`,
/// 50% `.after` (`.on` is `nil` because there's nothing to drop into).
///
/// The view renders three separate `.dropDestination` overlays sized by these
/// fractions, so each zone has its own `isTargeted` callback driving the
/// before/on/after indicator independently — no CGPoint-to-zone resolution at
/// render time.
struct DropZoneFractions: Equatable, Sendable {
	let before: CGFloat
	let on: CGFloat?
	let after: CGFloat
}

func dropZoneFractions(isBranch: Bool) -> DropZoneFractions {
	if isBranch {
		return DropZoneFractions(before: 0.25, on: 0.5, after: 0.25)
	} else {
		return DropZoneFractions(before: 0.5, on: nil, after: 0.5)
	}
}

/// Which row + zone is currently being hovered during a drag.
///
/// Internal: drives the per-row insertion-line / on-fill indicators. Set by
/// each zone's `isTargeted` callback.
struct DropHighlight<ID: Hashable & Sendable>: Equatable, Hashable, Sendable {
	let rowID: ID
	let position: DropPosition
}

private struct RowDropZone<ID, Preview>: View
where ID: Hashable & Sendable,
	  Preview: View
{
	let sourceID: ID
	let targetID: ID
	let position: DropPosition
	let fraction: CGFloat
	let rowHeight: CGFloat
	@Binding var dragSourcesByToken: [UUID: ID]
	let onMove: (OutlineMove<ID>) -> Bool
	let onSelect: () -> Void
	let onTargeted: (Bool) -> Void
	let preview: () -> Preview

	@State private var token = OutlineDragToken()

	var body: some View {
		Color.clear
			.frame(maxWidth: .infinity)
			.frame(height: rowHeight * fraction)
			// Explicit hit shape so the drop zone is testable on iOS during a
			// touch drag — without this, `Color.clear` overlays are ignored
			// by the drop hit-test on iPad and the drag snaps back unaccepted.
			.contentShape(Rectangle())
			.onAppear {
				dragSourcesByToken[token.id] = sourceID
			}
			.onChange(of: sourceID) { newValue in
				dragSourcesByToken[token.id] = newValue
			}
			.onDisappear {
				dragSourcesByToken.removeValue(forKey: token.id)
			}
			// Each zone is BOTH a drag source (for this row's item) AND a drop
			// target. Putting `.draggable` here rather than on the base view
			// keeps the source attached to the same hit-testable surface as
			// the drop destinations — otherwise the zone overlays would catch
			// mouse-down on macOS before `.draggable` on the base ever saw it
			// (the bug that broke macOS drag after the slice-3b refactor).
			.draggable(token) {
				preview()
			}
			.onTapGesture {
				onSelect()
			}
			.dropDestination(for: OutlineDragToken.self) { items, _ in
				guard let token = items.first,
					  let sourceID = dragSourcesByToken[token.id]
				else { return false }
				return onMove(OutlineMove(sourceID: sourceID, destination: position.moveDestination(relativeTo: targetID)))
			} isTargeted: { targeted in
				onTargeted(targeted)
			}
	}
}

private struct RootDropZone<ID: Hashable & Sendable>: View {
	@Binding var dragSourcesByToken: [UUID: ID]
	@Binding var isTargeted: Bool
	let onMove: (OutlineMove<ID>) -> Bool

	var body: some View {
		Color.clear
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.contentShape(Rectangle())
			.dropDestination(for: OutlineDragToken.self) { items, _ in
				guard let token = items.first,
					  let sourceID = dragSourcesByToken[token.id]
				else { return false }
				return onMove(OutlineMove(sourceID: sourceID, destination: .root))
			} isTargeted: { targeted in
				isTargeted = targeted
			}
	}
}

/// Drag payload — wraps an outline-local token so SwiftUI can deliver drags to
/// drop targets without forcing caller IDs to conform to `Codable`.
private struct OutlineDragToken: Codable, Hashable, Sendable, Transferable {
	let id: UUID

	init(id: UUID = UUID()) {
		self.id = id
	}

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .data)
	}
}
