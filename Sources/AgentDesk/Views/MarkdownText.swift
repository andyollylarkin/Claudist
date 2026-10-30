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
