import SwiftUI
import UniformTypeIdentifiers
import OutlineView

struct ContentView: View {
    @State private var root: FileNode?
    @State private var scopedRoot: URL?
    @State private var showImporter = false
    @State private var selection: Set<URL> = []
    @State private var expanded: Set<URL> = []
    @State private var dropLog: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            if root != nil {
                Divider()
                dropLogFooter
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                setRoot(url)
            }
        }
        .onDisappear {
            scopedRoot?.stopAccessingSecurityScopedResource()
        }
    }

    private var toolbar: some View {
        HStack {
            Button("Choose Folder…") { showImporter = true }
            if let root {
                Text(root.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let root {
            OutlineView(
                [root],
                children: \.children,
                selection: $selection,
                expanded: $expanded,
                onDrop: { drop in
                    logDrop(drop)
                    // Read-only browser: don't actually move files. Returning
                    // true lets us see the gesture path resolve end-to-end
                    // (the row clears its targeted highlight, etc.) even
                    // though no mutation happens.
                    return true
                }
            ) { node in
                Label(node.name, systemImage: node.isDirectory ? "folder" : "doc")
            }
        } else {
            VStack {
                Spacer()
                Text("Choose a folder to browse.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dropLogFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
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

    private func setRoot(_ url: URL) {
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = url.startAccessingSecurityScopedResource() ? url : nil
        let node = FileNode(url: url)
        root = node
        selection = []
        expanded = [node.id]
        dropLog = []
    }

    private func logDrop(_ drop: OutlineDrop<URL>) {
        let verb: String
        switch drop.position {
        case .before: verb = "BEFORE"
        case .on:     verb = "ON"
        case .after:  verb = "AFTER"
        }
        let line = "\(drop.sourceID.lastPathComponent) → \(verb) \(drop.targetID.lastPathComponent)"
        dropLog.insert(line, at: 0)
        if dropLog.count > 10 { dropLog.removeLast(dropLog.count - 10) }
    }
}

#Preview {
    ContentView()
        .frame(width: 480, height: 480)
}
