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
/// - **Slice 3a** — empty container is a branch (was a leaf — the predicate
///   bug that motivated leaving `List` in the first place).
/// - **Slice 3b** — zone-specific visual feedback. Insertion line at the
///   row edge for `.before` / `.after`; fill highlight for `.on`. Three
///   separate `.dropDestination` overlays per row instead of resolving
///   position from a CGPoint — each zone's `isTargeted` callback drives
///   the indicator directly.
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

	@State private var targetedZone: DropHighlight<ID>? = nil

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

		if onDrop != nil {
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
		Color.clear
			.frame(maxWidth: .infinity)
			.frame(height: Self.rowHeight * fraction)
			// Explicit hit shape so the drop zone is testable on iOS during a
			// touch drag — without this, `Color.clear` overlays are ignored
			// by the drop hit-test on iPad and the drag snaps back unaccepted.
			.contentShape(Rectangle())
			// Each zone is BOTH a drag source (for this row's item) AND a drop
			// target. Putting `.draggable` here rather than on the base view
			// keeps the source attached to the same hit-testable surface as
			// the drop destinations — otherwise the zone overlays would catch
			// mouse-down on macOS before `.draggable` on the base ever saw it
			// (the bug that broke macOS drag after the slice-3b refactor).
			.draggable(OutlineDragItem(id: sourceItem.id)) {
				dragPreview(for: sourceItem)
			}
			.dropDestination(for: OutlineDragItem<ID>.self) { items, _ in
				guard let item = items.first, let onDrop else { return false }
				return onDrop(OutlineDrop(sourceID: item.id, targetID: sourceItem.id, position: position))
			} isTargeted: { targeted in
				let entry = DropHighlight(rowID: sourceItem.id, position: position)
				if targeted {
					targetedZone = entry
				} else if targetedZone == entry {
					targetedZone = nil
				}
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

/// Drag payload — wraps the row's ID so SwiftUI can deliver it to the drop
/// destination's `onDrop` callback. Private to the package; callers never
/// construct it directly.
struct OutlineDragItem<ID: Codable & Hashable & Sendable>: Codable, Hashable, Transferable {
	let id: ID

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .data)
	}
}
