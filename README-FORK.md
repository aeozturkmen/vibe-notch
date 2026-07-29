# Vibe Notch — no-Xcode fork

A fork of **[farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch)**
that can be built **without Xcode**, plus two bug fixes.

This is an unofficial fork. It is not affiliated with or endorsed by the original
author. All credit for the app belongs upstream; please star and follow
[the original repository](https://github.com/farouqaldori/vibe-notch).
Licensed under Apache 2.0, same as upstream — see [LICENSE.md](LICENSE.md).

---

## Why this fork exists

Upstream builds with `xcodebuild`, which requires full Xcode (~20 GB). On a machine
with only Command Line Tools — and no room for Xcode — there was no way to build
the app or test a patch. The SwiftPM that ships with Command Line Tools did not
help either; it fails on its own `swift package init` template.

So this fork adds a build path that uses nothing but the Swift compiler.

## What changed

### 1. Build without Xcode

```bash
./scripts/build-without-xcode.sh
open "build/Vibe Notch Local.app"
```

Requires only Command Line Tools (`xcode-select --install`). Compiles the sources
directly with `swiftc` — no `xcodebuild`, no SwiftPM, no package resolution.

To make that work it produces a **reduced** build, assembled in a temporary staging
copy — **your working tree is never modified**:

| Removed | Effect |
|---|---|
| Sparkle | No auto-update. An ad-hoc signed local build must not replace itself with a signed upstream release. |
| Mixpanel | **No analytics.** Upstream sends app/OS/Claude Code versions and a session-started event, keyed to a stable hardware UUID, with no opt-out. |
| swift-markdown | Replaced with Foundation's built-in `AttributedString` markdown parsing, so the build has zero package dependencies. |
| `#Preview` blocks | The macro needs an Xcode plugin. Development-only, no runtime effect. |

Everything else is the unmodified app: notch UI, hooks, session monitoring,
permission approvals.

The resulting app is **ad-hoc signed**, so it is not notarized. If you want a
signed, notarized, auto-updating build, use the
[official release](https://github.com/farouqaldori/vibe-notch/releases/latest).

### 2. Fix: sessions showed their first message instead of their title

`displayTitle` resolved to `summary ?? firstUserMessage ?? projectName`, where
`summary` came from a `type: "summary"` record in the JSONL transcript. Current
Claude Code versions no longer write those records, so every session fell through
to its raw first user message — a pasted URL, a one-line question, whatever was
typed first.

The real title is on disk, just not where the app was looking:

```
~/Library/Application Support/Claude/claude-code-sessions/
    <accountId>/<workspaceId>/local_<uuid>.json     →  { "title": …, "cliSessionId": … }
```

`cliSessionId` matches the transcript UUID the app already tracks. New
`DesktopSessionTitles` reads and caches that mapping, and `displayTitle` now
prefers it. Verified working.

### 3. Fix: `idle → waitingForInput` was rejected as an invalid transition

`SessionPhase.canTransition(to:)` had no case for it, so a fresh session whose
`SessionStart` reports `waiting_for_input` was logged as
`Invalid transition: idle -> waitingForInput, ignoring` and left in `.idle`.

Observed in logs and fixed by adding the case. Not verified end-to-end — treat
this one as a plausible fix rather than a confirmed one.

### 4. Fix: sessions stayed on "Processing..." after the turn ended

The most visible bug of the three. Captured across a real turn boundary:

```
18:21:23.424  Received: Stop          → waitingForInput   ✅
18:21:26.514  Received: SubagentStop  → processing        ❌  (3.09s later)
              … nothing until 18:33 — stuck for 11m42s
```

The hook script maps `SubagentStop` to `"processing"`, on the comment's stated
assumption that "main session continues processing". That is wrong when a
subagent finishes *after* the main turn already stopped: the late event drags the
session back into `.processing`, where it stays until the next user prompt — the
notch shows "Processing..." for a session that finished minutes ago.

`SubagentStop` is now ignored when the session is already in `.waitingForInput`.
Verified by replaying the exact sequence.

## Known issues, not fixed here

Two more findings from the same investigation, left alone because they are
upstream design decisions rather than clear bugs:

- **Claude.app is missing from `TerminalAppRegistry`.** For sessions run inside
  the Claude desktop app, `isTerminalFrontmost()` is always false, so
  `isSessionFocused()` never returns true — the notification sound fires even
  while you are looking straight at the session, and click-to-focus cannot
  resolve a window. Related upstream issues: #53, #39, #38.

- **Cowork sessions never appear.** Cowork runs each session against its own
  sandboxed `.claude` directory inside
  `~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<workspace>/local_<uuid>/`,
  so hooks registered in `~/.claude/settings.json` are never loaded and
  transcripts never land in `~/.claude/projects/`. The data is there —
  `audit.jsonl` carries tool names, inputs, decisions and usage — the watcher is
  simply pointed elsewhere. Supporting it would mean watching that tree too.

## Upstream

Bug reports about the app itself belong
[upstream](https://github.com/farouqaldori/vibe-notch/issues). Only open issues
here for the no-Xcode build path.
