import os

/// An agent app has no window to print into, so anything worth diagnosing has
/// to go somewhere you can read it:
///
///     log stream --predicate 'subsystem == "com.zachzama.siggy"' --level debug
enum Log {
    static let usage = Logger(subsystem: "com.zachzama.siggy", category: "usage")
    static let sessions = Logger(subsystem: "com.zachzama.siggy", category: "sessions")
}
