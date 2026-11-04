import AppKit
import SwiftUI

/// Dark palette and shared building blocks for the main window.
enum Theme {
    static let window = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let card = Color(red: 0.113, green: 0.113, blue: 0.125)
    static let row = Color(red: 0.145, green: 0.145, blue: 0.16)
    static let rowHover = Color(red: 0.175, green: 0.175, blue: 0.19)
    static let border = Color.white.opacity(0.08)
    static let text = Color(white: 0.92)
    static let secondary = Color(white: 0.58)
    static let tertiary = Color(white: 0.4)
    static let accent = Color(red: 0.62, green: 0.55, blue: 0.98)
    static let accentSoft = Color(red: 0.62, green: 0.55, blue: 0.98).opacity(0.18)
    static let navSelected = Color.white.opacity(0.09)
    static let radius: CGFloat = 16
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            trailing
        }
        .padding(.bottom, 22)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// Underlined tab strip like Wispr's "All / Personal / Shared".
struct Tabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 26) {
                ForEach(items, id: \.0) { key, label in
                    let on = key == selection
                    Button { selection = key } label: {
                        VStack(spacing: 10) {
                            Text(label)
                                .font(.system(size: 15, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.secondary)
                            Rectangle().fill(on ? Theme.text : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.bottom, 18)
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Theme.text, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1, green: 0.45, blue: 0.45) : Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// Small icon button that only shows on row hover.
struct IconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A bordered row that highlights on hover and reveals trailing actions.
struct RowCard<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            content
            Spacer(minLength: 0)
            actions.opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(hover ? Theme.rowHover : Theme.row)
        .onHover { hover = $0 }
    }
}

struct CardList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.row)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

struct StatTile<Extra: View>: View {
    let value: String
    let label: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.text)
            Text(label.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1.2).foregroundStyle(Theme.secondary)
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

extension StatTile where Extra == EmptyView {
    init(value: String, label: String) { self.init(value: value, label: label, extra: { EmptyView() }) }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }
}
extension View { func field() -> some View { modifier(FieldStyle()) } }

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.secondary)
    }
}

func appDisplayName(for bundle: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundle.components(separatedBy: ".").last ?? bundle
}

func appIcon(for bundle: String?) -> NSImage? {
    guard let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}
