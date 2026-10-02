import SwiftUI
import UIKit

@main
struct FramewiseApp: App {
    @StateObject private var library = LocalPhotoLibrary()

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        AppDiagnostics.shared.log("app", "Launch · version \(version) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
    }

    var body: some Scene {
        WindowGroup {
            CameraView(library: library)
        }
    }
}
