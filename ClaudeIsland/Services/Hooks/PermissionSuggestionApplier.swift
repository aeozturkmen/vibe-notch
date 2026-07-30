//
//  PermissionSuggestionApplier.swift
//  ClaudeIsland
//
//  Applies the permission rules that Claude Code's own "Always allow" button
//  would apply.
//
//  A PermissionRequest hook payload carries `permission_suggestions`, which is
//  Claude Code telling us exactly which rules to add and which settings file
//  they belong in. Using them means "Always allow" in the notch grants the same
//  scope as "Always allow" in the terminal — no rule is derived or guessed here.
//
//  Suggestion shape (from Claude Code's own schema):
//    { type: "addRules" | "replaceRules" | "removeRules" | "setMode" | …,
//      rules: [ { toolName: String, ruleContent: String? } ],
//      behavior: "allow" | "deny" | "ask",
//      destination: "userSettings" | "projectSettings" | "localSettings"
//                 | "session" | "cliArg" }
//
//  Only `addRules` with `behavior == "allow"` is applied — that is what the
//  button offers. Anything else is ignored rather than guessed at.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Permissions")

enum PermissionSuggestionApplier {

    /// Whether a set of suggestions contains something "Always allow" can act on.
    static func canApply(_ suggestions: [AnyCodable]?) -> Bool {
        !allowRuleGroups(from: suggestions).isEmpty
    }

    /// Apply every allow-rule suggestion. Returns true if at least one rule was
    /// written to disk.
    ///
    /// - Parameter cwd: the session's working directory, used to resolve
    ///   project- and local-scoped settings files.
    @discardableResult
    static func apply(_ suggestions: [AnyCodable]?, cwd: String) -> Bool {
        let groups = allowRuleGroups(from: suggestions)
        guard !groups.isEmpty else { return false }

        var wroteAnything = false

        for group in groups {
            guard let url = settingsURL(for: group.destination, cwd: cwd) else {
                // "session" and "cliArg" have no file to persist into. Claude Code
                // keeps those in memory for its own process, which we cannot reach.
                logger.debug("Skipping \(group.destination, privacy: .public) suggestion — not file-backed")
                continue
            }

            if addRules(group.rules, to: url) {
                wroteAnything = true
                logger.info("Added \(group.rules.count) allow rule(s) to \(url.lastPathComponent, privacy: .public)")
            }
        }

        return wroteAnything
    }

    // MARK: - Parsing

    private struct RuleGroup {
        let rules: [String]
        let destination: String
    }

    /// Extract `addRules` suggestions whose behavior is `allow`, rendering each
    /// rule into the `ToolName(ruleContent)` string form used in settings.json.
    private static func allowRuleGroups(from suggestions: [AnyCodable]?) -> [RuleGroup] {
        guard let suggestions else { return [] }

        var groups: [RuleGroup] = []

        for suggestion in suggestions {
            guard let dict = suggestion.value as? [String: Any],
                  dict["type"] as? String == "addRules",
                  dict["behavior"] as? String == "allow",
                  let rawRules = dict["rules"] as? [Any]
            else { continue }

            let destination = dict["destination"] as? String ?? "localSettings"

            let rendered = rawRules.compactMap { raw -> String? in
                guard let rule = raw as? [String: Any],
                      let toolName = rule["toolName"] as? String,
                      !toolName.isEmpty
                else { return nil }

                // A rule is `ToolName(content)`, or a bare `ToolName` when the
                // suggestion covers the whole tool.
                if let content = rule["ruleContent"] as? String, !content.isEmpty {
                    return "\(toolName)(\(content))"
                }
                return toolName
            }

            if !rendered.isEmpty {
                groups.append(RuleGroup(rules: rendered, destination: destination))
            }
        }

        return groups
    }

    // MARK: - Settings files

    /// Map a suggestion destination to the file Claude Code would write it to.
    private static func settingsURL(for destination: String, cwd: String) -> URL? {
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")

        switch destination {
        case "userSettings":
            return ClaudePaths.settingsFile
        case "projectSettings":
            return project.appendingPathComponent("settings.json")
        case "localSettings":
            return project.appendingPathComponent("settings.local.json")
        default:
            // session / cliArg live only inside Claude Code's process.
            return nil
        }
    }

    /// Merge rules into `permissions.allow`, preserving everything else in the
    /// file and skipping rules that are already present.
    private static func addRules(_ rules: [String], to url: URL) -> Bool {
        var json: [String: Any] = [:]

        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Refuse to touch a file we cannot parse — overwriting it would
                // discard the user's settings.
                logger.error("Not writing to \(url.lastPathComponent, privacy: .public): existing file is not valid JSON")
                return false
            }
            json = parsed
        }

        var permissions = json["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        let existing = Set(allow)
        let newRules = rules.filter { !existing.contains($0) }
        guard !newRules.isEmpty else {
            logger.debug("All suggested rules already present in \(url.lastPathComponent, privacy: .public)")
            return true
        }

        allow.append(contentsOf: newRules)
        permissions["allow"] = allow
        json["permissions"] = permissions

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            // Atomic so a crash mid-write cannot truncate the user's settings.
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            logger.error("Failed writing \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
