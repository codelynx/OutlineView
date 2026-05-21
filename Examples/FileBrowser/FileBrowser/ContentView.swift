import SwiftUI
import UniformTypeIdentifiers
import OutlineView

struct ContentView: View {
    @State private var root: FileNode?
    @State private var scopedRoot: URL?
    @State private var showImporter = false
    @State private var selection: Set<URL> = []
    @State private var expanded: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
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
                expanded: $expanded
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

    private func setRoot(_ url: URL) {
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = url.startAccessingSecurityScopedResource() ? url : nil
        let node = FileNode(url: url)
        root = node
        selection = []
        expanded = [node.id]
    }
}

#Preview {
    ContentView()
        .frame(width: 480, height: 480)
}
