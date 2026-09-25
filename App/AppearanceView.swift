import SwiftUI

struct AppearanceView: View {
    static let modeKey = "appearanceMode"
    static func colorScheme(for mode: String) -> ColorScheme? {
        switch mode { case "light": .light; case "dark": .dark; default: nil }
    }

    @Environment(\.appearance) private var appearance

    private var accent: AccentTheme { appearance.accent }
    /// Dynamic Type factor for the status mark, as `MessageStatusView` scales it with caption2.
    @ScaledMetric(relativeTo: .caption2) private var statusScale: CGFloat = 1

    var body: some View {
        @Bindable var appearance = appearance
        List {
            Section("Theme") {
                Picker("Theme", selection: $appearance.mode) {
                    Text("Automatic").tag("automatic")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                    ForEach(AccentTheme.allCases) { theme in
                        let selected = theme == accent
                        Button { appearance.accent = theme } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(theme.swatch)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if selected {
                                            Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(Color(uiColor: theme.bubbleText))
                                            Circle().stroke(Color(uiColor: theme.tint), lineWidth: 2).padding(-4)
                                        }
                                    }
                                Text(theme.title)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Preview") {
                VStack(spacing: 6) {
                    bubble("Coffee tomorrow?", time: "18:02", incoming: true)
                    bubble("Ten it is ☕️", time: "18:05", incoming: false)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .themedRoot()
    }

    /// The real bubble's footer at preview size: caption2 time and the shared read mark, both in the
    /// meta colour, inside the 20 pt bubble with the timeline's 12/10/8 insets.
    private func bubble(_ text: String, time: String, incoming: Bool) -> some View {
        let textColor = incoming ? Color.primary : Color(uiColor: accent.bubbleText)
        let meta = incoming ? Color(uiColor: .secondaryLabel) : Color(uiColor: accent.bubbleText.withAlphaComponent(0.75))
        return HStack {
            if !incoming { Spacer(minLength: 60) }
            VStack(alignment: .trailing, spacing: 3) {
                Text(text).foregroundStyle(textColor)
                HStack(spacing: 5) {
                    Text(time).font(.caption2)
                    if !incoming {
                        Image(uiImage: MessageStatusArt.image(.read, scale: statusScale))
                            .renderingMode(.template)
                            .frame(width: MessageStatusArt.slotWidth * statusScale,
                                   height: MessageStatusArt.designHeight * statusScale, alignment: .trailing)
                    }
                }
                .foregroundStyle(meta)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .background(incoming ? Color(uiColor: .tertiarySystemFill) : accent.swatch, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if incoming { Spacer(minLength: 60) }
        }
    }
}
