import SwiftUI

@main
struct PrintScan3DApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            ScanLibraryView()
                .environmentObject(store)
        }
    }
}
