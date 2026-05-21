import Testing
import SwiftUI
@testable import OutlineView

private struct Node: Identifiable {
	let id: Int
	let title: String
	var children: [Node]?
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

@Test func collapsedTreeShowsOnlyRoots() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set<Int>())

	#expect(rows.map(\.element.id) == [1])
	#expect(rows[0].depth == 0)
	#expect(rows[0].hasChildren == true)
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

@Test func hasChildrenDistinguishesLeavesFromBranches() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([1, 3]))
	let hasKids = Dictionary(uniqueKeysWithValues: rows.map { ($0.element.id, $0.hasChildren) })

	#expect(hasKids[1] == true)
	#expect(hasKids[2] == false)
	#expect(hasKids[3] == true)
	#expect(hasKids[4] == false)
}

@Test func emptyChildrenArrayCountsAsLeaf() {
	let withEmptyArray: [Node] = [
		Node(id: 10, title: "Group", children: []),
		Node(id: 11, title: "Nil", children: nil),
	]
	let rows = flattenTree(withEmptyArray, children: \.children, expanded: Set([10]))

	#expect(rows.map(\.element.id) == [10, 11])
	#expect(rows.allSatisfy { !$0.hasChildren })
}

@Test func expandingALeafIsHarmless() {
	let rows = flattenTree(sampleTree, children: \.children, expanded: Set([2, 4]))

	#expect(rows.map(\.element.id) == [1])
}
