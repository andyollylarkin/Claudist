import ClaudistCore
import AppKit
import SwiftUI

/// Visual language: warm sidebar, red accent, priority-colored circles, colored dates.
enum Theme {
    static let accent = Color(hex: 0xDC4C3E)
    static let accentSoft = adaptive(light: 0xFFEFE5, dark: 0x3A2522)

    static let background = adaptive(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let sidebar = adaptive(light: 0xFCFAF8, dark: 0x262626)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2A2A)
    static let hover = adaptive(light: 0xF5F3F0, dark: 0x303030)
    static let divider = adaptive(light: 0xEEEEEE, dark: 0x363636)
    static let border = adaptive(light: 0xE5E5E5, dark: 0x3D3D3D)
    static let text = adaptive(light: 0x202020, dark: 0xE8E8E8)
    static let secondary = adaptive(light: 0x666666, dark: 0xA8A8A8)
    static let tertiary = adaptive(light: 0x8A8A8A, dark: 0x7A7A7A)

    static let green = Color(hex: 0x058527)
    static let orange = Color(hex: 0xAD6200)
    static let purple = Color(hex: 0x692EC2)
    static let blue = Color(hex: 0x246FE0)
    static let red = Color(hex: 0xD1453B)

    static func priority(_ p: Int) -> Color {
        switch p {
        case 1: red
        case 2: Color(hex: 0xEB8909)
        case 3: blue
        default: tertiary
        }
    }

    static let colorNames = ["gray", "red", "orange", "yellow", "olive", "green", "mint", "teal", "sky", "blue", "grape", "violet", "magenta", "salmon", "taupe", "brown"]

    static func color(_ name: String) -> Color {
        switch name {
        case "red": Color(hex: 0xDC4C3E)
        case "orange": Color(hex: 0xC77100)
        case "yellow": Color(hex: 0xB29104)
        case "olive": Color(hex: 0x949C31)
        case "green": Color(hex: 0x369307)
        case "mint": Color(hex: 0x42A393)
        case "teal": Color(hex: 0x148FAD)
        case "sky": Color(hex: 0x319DC0)
        case "blue", "indigo": Color(hex: 0x4180FF)
        case "grape", "purple": Color(hex: 0x692EC2)
        case "violet": Color(hex: 0xCA3FEE)
        case "magenta", "pink": Color(hex: 0xE05095)
        case "salmon": Color(hex: 0xC9766F)
        case "taupe": Color(hex: 0x8F7A69)
        case "brown": Color(hex: 0x8B5A2B)
        default: Color(hex: 0x999999)
        }
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Building blocks

/// Large page title used at the top of every main view.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var iconColor: Color = Theme.secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String? = nil, iconColor: Color = Theme.secondary) {
        self.init(title: title, subtitle: subtitle, icon: icon, iconColor: iconColor) { EmptyView() }
    }
}

/// Bold group title with a count and a hairline underneath.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>?
    /// Replaces the plain title (e.g. an editable one).
    var titleView: AnyView?
    var trailing: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let collapsed {
                    Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.wrappedValue.toggle() } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                }
                if let titleView { titleView } else {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                }
                if let count {
                    Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if let trailing { trailing }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .padding(.top, 14)
    }
}

/// Small rounded pill for metadata (labels, agents, statuses).
struct Pill: View {
    let text: String
    var icon: String?
    var color: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
    }
}

/// Text-only button in the accent color, e.g. "Add task".
struct AccentButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(prominent ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Theme.hover))
    }
}

/// Plain row button with hover highlight.
struct HoverRow<Content: View>: View {
    var selected = false
    var cornerRadius: CGFloat = 5
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
            .onHover { hovering = $0 }
    }
}

/// Icon-only toolbar-like button.
struct IconButton: View {
    let icon: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Segmented control with an underline, used for tabs inside panels.
struct UnderlineTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Button { selection = i } label: {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: selection == i ? .semibold : .regular))
                            .foregroundStyle(selection == i ? Theme.text : Theme.secondary)
                        Rectangle().fill(selection == i ? Theme.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// Centers page content in a readable column, Todoist-style.
struct ReadableColumn<Content: View>: View {
    var maxWidth: CGFloat = 820
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Forms

/// Rounded container with a title, used instead of grouped Forms.
struct Card<Content: View>: View {
    var title: String?
    var footer: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label on the left, control on the right, hairline below.
struct FieldRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var last = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(2)
                }
            }
            .frame(minWidth: 110, alignment: .leading)
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 14) }
        }
    }
}

/// Plain text field with a soft border.
struct BoxedField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

/// Multi-line editor with a soft border.
struct BoxedEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var monospaced = true

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

/// Square checkbox row used for skill / secret selection.
struct CheckRow: View {
    let title: String
    var subtitle: String?
    var note: String?
    var monospaced = false
    var last = false
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Theme.accent : Theme.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, design: monospaced ? .monospaced : .default)).foregroundStyle(Theme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.green)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 40) }
        }
    }
}

/// Empty state inside a card.
struct CardEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Menu-based picker that looks like plain text with chevrons.
struct InlineMenu: View {
    let value: String
    let options: [(String, String)]
    let select: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { key, title in Button(title) { select(key) } }
        } label: {
            HStack(spacing: 4) {
                Text(value).foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Small text button in the accent color, e.g. "+ New secret".
struct LinkButton: View {
    let title: String
    var icon = "plus"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }
}
