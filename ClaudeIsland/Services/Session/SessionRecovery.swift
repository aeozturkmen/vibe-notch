//
//  SessionRecovery.swift
//  ClaudeIsland
//
//  Rediscovers live Claude Code sessions at launch.
//
//  Sessions are held only in memory, so quitting or restarting the app used to
//  drop every one of them. They reappeared only when a session happened to fire
//  its next hook event — which for a session deep in a long turn can be many
//  minutes, during which the notch shows nothing.
//
//  Claude Code keeps its own registry of live sessions, one small JSON file per
//  process, named after the pid:
//
//      <claude dir>/sessions/<pid>.json
//      { "pid": 14704, "sessionId": "…", "cwd": "…", "startedAt": …,
//        "entrypoint": "claude-desktop", "kind": "interactive", … }
//
//  Reading it at startup restores the session list immediately. Entries whose
//  process is gone are ignored, so stale files do not resurrect dead sessions.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Recovery")

/// A live session found in Claude Code's own registry.
struct RecoveredSession: Sendable {
    let sessionId: String
    let cwd: String
    let pid: Int
}

enum SessionRecovery {

    /// Directory Claude Code writes its live-session registry into.
    private static var sessionsDir: URL {
        ClaudePaths.claudeDir.appendingPathComponent("sessions")
    }

    /// Every registry entry whose process is still alive.
    ///
    /// Returns an empty array when the directory is missing — an older Claude
    /// Code, or a config layout without it — so recovery degrades to the old
    /// behaviour rather than failing.
    static func discoverLiveSessions() -> [RecoveredSession] {
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            logger.debug("No sessions registry at \(sessionsDir.path, privacy: .public)")
            return []
        }

        var recovered: [RecoveredSession] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String,
                  let pid = json["pid"] as? Int,
                  !sessionId.isEmpty
            else { continue }

            // A registry file outlives its process; only trust live ones.
            guard isProcessAlive(pid) else {
                logger.debug("Skipping \(sessionId.prefix(8), privacy: .public) — pid \(pid) is gone")
                continue
            }

            recovered.append(RecoveredSession(sessionId: sessionId, cwd: cwd, pid: pid))
        }

        if !recovered.isEmpty {
            logger.info("Recovered \(recovered.count) live session(s) from registry")
        }

        return recovered
    }

    private static func isProcessAlive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }
}
