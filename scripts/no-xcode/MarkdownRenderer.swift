//
//  MarkdownRenderer.swift
//  VibeNotch (local build)
//
//  Local-build replacement for the swift-markdown based renderer.
//  Uses Foundation's built-in AttributedString markdown parsing so the app
//  has no external package dependencies and can be compiled with swiftc
//  alone (this machine has no Xcode, and its SwiftPM install is broken).
//
//  Keeps the original public API: MarkdownText(_:color:fontSize:)
//

import SwiftUI

/// Renders a markdown string as SwiftUI text.
///
/// Fenced code blocks are handled separately, since Foundation's inline
/// markdown parser would otherwise collapse their formatting. Everything
/// else is rendered with inline styling — bold, italic, inline code, links.
struct MarkdownText: View {
    private let text: String
    private let color: Color
    private let fontSize: CGFloat

    init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13) {
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.segments(from: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let code):
                    Text(code)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundStyle(color.opacity(0.85))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .font(.system(size: fontSize))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Parsing

    fileprivate enum Segment {
        case prose(String)
        case code(String)
    }

    /// Split the input on fenced code blocks so code keeps its formatting.
    fileprivate static func segments(from text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var inFence = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.prose(joined)) }
            prose.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    result.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inFence = false
                } else {
                    flushProse()
                    inFence = true
                }
                continue
            }
            if inFence { code.append(line) } else { prose.append(line) }
        }

        // Unterminated fence — keep what we have rather than dropping it.
        if inFence, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return result
    }

    /// Inline markdown via Foundation. Falls back to the raw string when the
    /// text isn't valid markdown, so content is never lost.
    fileprivate static func attributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: string, options: options) {
            return parsed
        }
        return AttributedString(string)
    }
}
