import SwiftUI

@main
struct FileBrowserApp: App {
    var body: some Scene {
        WindowGroup("File Browser") {
            ContentView()
                .frame(minWidth: 360, minHeight: 400)
        }
    }
}
