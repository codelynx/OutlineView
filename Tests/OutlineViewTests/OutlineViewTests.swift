import Testing
import SwiftUI
@testable import OutlineView

private struct Node: Identifiable {
	let id: Int
	let title: String
	var children: [Node]?
}

private struct PlainID: Hashable, Sendable {
	let rawValue: Int
}

private struct PlainNode: Identifiable {
	let id: PlainID
	let title: String
	var children: [PlainNode]?
}

private let sampleTree: [Node] = [
	Node(id: 1, title: "Root", children: [
		Node(id: 2, title: "Child A", children: nil),
		Node(id: 3, title: "Child B", children: [
			Node(id: 4, title: "Leaf", children: nil),
		]),
	]),
]

@Test @MainActor func buildsWithHierarchicalData() async throws {
	_ = OutlineView(
		sampleTree,
		children: \.children,
		selection: .constant([]),
		expanded: .constant([])
	) { node in
		Text(node.title)
	}
}

@Test @MainActor func buildsWithNonCodableIDsWhenDragIsDisabled() async throws {
	let tree = [
		PlainNode(id: PlainID(rawValue: 1), title: "Root", children: [
			PlainNode(id: PlainID(rawValue: 2), title: "Leaf", children: nil),
		]),
	]
	_ = OutlineView(
		tree,
		children: \.children,
		selection: .constant([]),
		expanded: .constant([])
	) { node in
		Text(node.title)
	}
}

@Test func collapsedTreeShowsOnlyRoots() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set<Int>())

	#expect(rows.map(\.element.id) == [1])
	#expect(rows[0].depth == 0)
	#expect(rows[0].isBranch == true)
}

@Test func expandedRootIncludesChildrenButNotGrandchildren() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([1]))

	#expect(rows.map(\.element.id) == [1, 2, 3])
	#expect(rows.map(\.depth) == [0, 1, 1])
}

@Test func expandedBranchIncludesGrandchildren() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([1, 3]))

	#expect(rows.map(\.element.id) == [1, 2, 3, 4])
	#expect(rows.map(\.depth) == [0, 1, 1, 2])
}

@Test func isBranchDistinguishesContainersFromLeaves() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([1, 3]))
	let isBranch = Dictionary(uniqueKeysWithValues: rows.map { ($0.element.id, $0.isBranch) })

	// id 1 has children [Child A, Child B] → container
	// id 2 has nil children → leaf
	// id 3 has children [Leaf] → container
	// id 4 has nil children → leaf
	#expect(isBranch[1] == true)
	#expect(isBranch[2] == false)
	#expect(isBranch[3] == true)
	#expect(isBranch[4] == false)
}

@Test func emptyChildrenArrayStillCountsAsBranch() {
	// Regression test for the predicate bug: `kids?.isEmpty == false` would
	// classify an empty container as a leaf, removing its `.on` drop zone
	// and re-introducing the exact empty-group-is-unreachable trap that
	// motivated leaving `List(_:children:)`. The correct predicate is
	// `kids != nil` — the container exists, it's just empty.
	let mixed: [Node] = [
		Node(id: 10, title: "EmptyGroup", children: []),
		Node(id: 11, title: "FileLeaf",   children: nil),
	]
	let rows = flattenTree(mixed, children: \.children, expanded: Set([10]))

	// Empty expanded group emits no child rows under it.
	#expect(rows.map(\.element.id) == [10, 11])

	let isBranch = Dictionary(uniqueKeysWithValues: rows.map { ($0.element.id, $0.isBranch) })
	#expect(isBranch[10] == true,  "empty container must remain a branch — a valid .on drop target")
	#expect(isBranch[11] == false, "nil children = leaf, no children container at all")
}

@Test func expandingALeafIsHarmless() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([2, 4]))

	#expect(rows.map(\.element.id) == [1])
}

// MARK: - Drop zone math

@Test func branchZonesSplitAtQuarters() {
	let f = dropZoneFractions(isBranch: true)
	#expect(f.before == 0.25)
	#expect(f.on == 0.5)
	#expect(f.after == 0.25)
	// The three zones must tile the row exactly — no gaps, no overlap.
	#expect(f.before + (f.on ?? 0) + f.after == 1.0)
}

@Test func leafZonesSplitAtHalf() {
	let f = dropZoneFractions(isBranch: false)
	#expect(f.before == 0.5)
	#expect(f.on == nil, "leaf row has no .on zone — nothing to drop into")
	#expect(f.after == 0.5)
	#expect(f.before + f.after == 1.0)
}

@Test func dropHighlightIsHashableValueType() {
	let a = DropHighlight(rowID: 1, position: DropPosition.on)
	let b = DropHighlight(rowID: 1, position: DropPosition.on)
	let c = DropHighlight(rowID: 1, position: DropPosition.before)
	#expect(a == b)
	#expect(a != c)
	#expect(Set([a, b, c]).count == 2)
}

// MARK: - DnD-enabled OutlineView builds

@Test @MainActor func buildsWithOnDropClosure() async throws {
	_ = OutlineView(
		sampleTree,
		children: \.children,
		selection: .constant([]),
		expanded: .constant([]),
		onDrop: { drop in
			// Closure runs at drop time, not build time — just confirming
			// the OutlineView accepts the signature.
			_ = drop.sourceID
			_ = drop.targetID
			_ = drop.position
			return true
		}
	) { node in
		Text(node.title)
	}
}

@Test func outlineDropIsValueAndHashable() {
	let a = OutlineDrop(sourceID: 1, targetID: 2, position: DropPosition.on)
	let b = OutlineDrop(sourceID: 1, targetID: 2, position: DropPosition.on)
	#expect(a == b)
	#expect(Set([a, b]).count == 1)
}

@Test @MainActor func buildsWithOnMoveClosureAndNonCodableIDs() async throws {
	let tree = [
		PlainNode(id: PlainID(rawValue: 1), title: "Root", children: []),
	]
	_ = OutlineView(
		tree,
		children: \.children,
		selection: .constant([]),
		expanded: .constant([]),
		onMove: { move in
			_ = move.sourceID
			_ = move.destination
			return true
		}
	) { node in
		Text(node.title)
	}
}

@Test func outlineMoveSupportsRootDestination() {
	let move = OutlineMove(sourceID: 1, destination: OutlineMoveDestination<Int>.root)

	#expect(move.sourceID == 1)
	#expect(move.destination == .root)
	#expect(OutlineDrop(move) == nil)
}

@Test func outlineMoveCanAdaptToLegacyOutlineDrop() throws {
	let before = OutlineMove(sourceID: 1, destination: OutlineMoveDestination.before(2))
	let inside = OutlineMove(sourceID: 1, destination: OutlineMoveDestination.inside(2))
	let after = OutlineMove(sourceID: 1, destination: OutlineMoveDestination.after(2))

	#expect(try #require(OutlineDrop(before)).position == .before)
	#expect(try #require(OutlineDrop(inside)).position == .on)
	#expect(try #require(OutlineDrop(after)).position == .after)
}
