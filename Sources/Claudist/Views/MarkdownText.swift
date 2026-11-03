import MarkdownUI
import SwiftUI

/// Full Markdown (headings, lists, code blocks, tables, quotes) in the app's style.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        Markdown(text)
            .markdownTheme(.agentDesk(size: size))
            .textSelection(.enabled)
    }
}

extension MarkdownUI.Theme {
    static func agentDesk(size: CGFloat) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(Theme.text)
                FontSize(size)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(Theme.hover)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(Theme.accent) }
            .heading1 { c in
                c.label
                    .markdownMargin(top: 14, bottom: 6)
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.35)) }
            }
            .heading2 { c in
                c.label
                    .markdownMargin(top: 12, bottom: 6)
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.2)) }
            }
            .heading3 { c in
                c.label
                    .markdownMargin(top: 10, bottom: 4)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.08)) }
            }
            .heading4 { c in
                c.label
                    .markdownMargin(top: 8, bottom: 4)
                    .markdownTextStyle { FontWeight(.semibold) }
            }
            .paragraph { c in
                c.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { c in
                c.label.markdownMargin(top: .em(0.2))
            }
            .taskListMarker { c in
                Image(systemName: c.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(c.isCompleted ? Theme.accent : Theme.tertiary)
                    .font(.system(size: size))
                    .relativeFrame(minWidth: .em(1.4), alignment: .leading)
            }
            .blockquote { c in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.border).frame(width: 3)
                    c.label
                        .markdownTextStyle { ForegroundColor(Theme.secondary) }
                        .padding(.leading, 10)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 8)
            }
            .codeBlock { c in
                VStack(alignment: .leading, spacing: 0) {
                    if let language = c.language, !language.isEmpty {
                        Text(language)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }
                    ScrollView(.horizontal) {
                        c.label
                            .relativeLineSpacing(.em(0.2))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                            }
                            .padding(10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
                .markdownMargin(top: 2, bottom: 8)
            }
            .table { c in
                c.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: Theme.border))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Theme.hover))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .tableCell { c in
                c.label
                    .markdownTextStyle { if c.row == 0 { FontWeight(.semibold) } }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
            }
            .thematicBreak {
                Divider().markdownMargin(top: 8, bottom: 8)
            }
    }
}

/// Short Markdown preview for rows and cards: inline styles (bold, code, links) and line breaks.
struct MarkdownPreview: View {
    let text: String
    var size: CGFloat = 12
    var lines = 2

    var body: some View {
        Text(Self.attributed(text))
            .font(.system(size: size))
            .foregroundStyle(Theme.secondary)
            .lineLimit(lines)
    }

    static func attributed(_ text: String) -> AttributedString {
        // Block syntax (headings, list markers) has no inline form; drop the markers, keep the words.
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            if l.hasPrefix("- [ ] ") || l.hasPrefix("- [x] ") { l = "☐ " + l.dropFirst(6) }
            else if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            else if l.hasPrefix("> ") { l = String(l.dropFirst(2)) }
            return l.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.hasPrefix("```") }
        .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }
}

/// Task description: rendered Markdown; double-click or the pencil edits it in a multi-line editor
/// where Return inserts a line break. Changes go to `text` as you type.
struct DescriptionField: View {
    @Binding var text: String
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 90, maxHeight: 360)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.6)))
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                HStack(spacing: 8) {
                    Text("Markdown: **bold**, *italic*, `code`, - lists, # headings, [links](https://…)")
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("Done") { editing = false }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Description")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
        } else {
            CappedScroll(maxHeight: 280) {
                MarkdownText(text: text, size: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = true }
            }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        IconButton(icon: "pencil", help: "Edit description") { editing = true }
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.background))
                    }
                }
                .onHover { hovering = $0 }
                .help("Double-click to edit")
        }
    }
}


/// As tall as its content up to `maxHeight`, scrolling beyond that.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
        }
        .scrollIndicators(height > maxHeight ? .visible : .hidden)
        .scrollDisabled(height <= maxHeight)
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
