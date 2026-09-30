import Foundation

/// The version this build carries, as project.yml sets it.
///
/// Siggy has no auto-updater: a copy only ever changes when someone installs a
/// new one by hand, so nothing can replace it from a feed it does not control.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
