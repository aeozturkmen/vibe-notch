//
//  DesktopSessionTitles.swift
//  ClaudeIsland
//
//  Resolves the real conversation title for a session.
//
//  Claude Code's desktop app stores each session's title outside ~/.claude, in
//     ~/Library/Application Support/Claude/claude-code-sessions/
//         <accountId>/<workspaceId>/local_<uuid>.json
//  where `cliSessionId` matches the transcript UUID we already track.
//
//  Without this, `displayTitle` falls back to the session's first user message,
//  because current Claude Code versions no longer write `type: "summary"`
//  records into the JSONL transcript that the parser looks for.
//

import Foundation

/// Cached lookup of desktop-app session titles, keyed by CLI session id.
enum DesktopSessionTitles {

    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]
    private static var lastScan: Date = .distantPast

    /// Re-scan at most this often; titles are assigned once and rarely change,
    /// and the directory is small (tens of files).
    private static let refreshInterval: TimeInterval = 30

    /// Root that the desktop app writes session metadata into.
    private static var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Title for a CLI session id, or nil when the session has no desktop-app
    /// entry (for example a session started from a terminal).
    static func title(forSessionId sessionId: String) -> String? {
        refreshIfNeeded()

        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[sessionId]
    }

    /// Force the next lookup to re-read from disk.
    static func invalidate() {
        cacheLock.lock()
        lastScan = .distantPast
        cacheLock.unlock()
    }

    // MARK: - Private

    private static func refreshIfNeeded() {
        cacheLock.lock()
        let isStale = Date().timeIntervalSince(lastScan) > refreshInterval
        cacheLock.unlock()

        guard isStale else { return }

        let scanned = scan()

        cacheLock.lock()
        cache = scanned
        lastScan = Date()
        cacheLock.unlock()
    }

    /// Walk `<root>/<account>/<workspace>/*.json` and map cliSessionId -> title.
    private static func scan() -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]

        guard let accounts = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil
        ) else {
            return result
        }

        for account in accounts {
            guard let workspaces = try? fm.contentsOfDirectory(
                at: account, includingPropertiesForKeys: nil
            ) else { continue }

            for workspace in workspaces {
                guard let files = try? fm.contentsOfDirectory(
                    at: workspace, includingPropertiesForKeys: nil
                ) else { continue }

                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let cliSessionId = json["cliSessionId"] as? String,
                          let title = json["title"] as? String,
                          !cliSessionId.isEmpty,
                          !title.isEmpty
                    else { continue }

                    result[cliSessionId] = title
                }
            }
        }

        return result
    }
}
