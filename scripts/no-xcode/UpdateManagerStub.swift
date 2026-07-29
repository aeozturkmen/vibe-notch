//
//  UpdateManagerStub.swift
//  VibeNotch (local build)
//
//  Sparkle is not part of this build, so auto-update is unavailable.
//  This keeps UpdateManager's API surface intact for NotchMenuView while
//  reporting a fixed "no updates" state — a local build should never try
//  to replace itself with a signed upstream release.
//

import Foundation

/// Mirrors the upstream Sparkle-backed state machine so the settings UI
/// compiles and renders unchanged.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case found(version: String, releaseNotes: String?)
    case downloading(progress: Double)
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    var isActive: Bool {
        switch self {
        case .idle, .upToDate, .error:
            return false
        default:
            return true
        }
    }
}

/// No-op stand-in for the Sparkle updater.
///
/// `checkForUpdates()` reports `.upToDate` rather than `.error`, so the
/// settings panel shows a calm state instead of a failure the user cannot act on.
/// Install actions are intentionally inert.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate: Bool = false

    override init() {
        super.init()
    }

    func checkForUpdates() {
        state = .upToDate
    }

    func downloadAndInstall() {
        // No updater in a local build — nothing to download.
    }

    func installAndRelaunch() {
        // No updater in a local build — nothing to install.
    }

    func markUpdateSeen() {
        hasUnseenUpdate = false
    }
}
