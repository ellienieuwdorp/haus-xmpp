import SwiftUI

struct AppearanceView: View {
    static let modeKey = AppearanceStore.modeKey

    @Environment(\.appearance) private var appearance

    private var accent: AccentTheme { appearance.accent }
    /// Dynamic Type factor for the status mark, as `MessageStatusView` scales it with caption2.
    @ScaledMetric(relativeTo: .caption2) private var statusScale: CGFloat = 1

    var body: some View {
        @Bindable var appearance = appearance
        GroupedList {
            #if os(macOS)
            // A Mac pane: one row per choice, the accents as a row of swatches as in System Settings.
            Section {
                Picker("Theme", selection: $appearance.mode) {
                    Text("Automatic").tag("automatic")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent") { macAccents }
            }
            #else
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
                                                .foregroundStyle(Color(platform: theme.bubbleText))
                                            Circle().stroke(Color(platform: theme.tint), lineWidth: 2).padding(-4)
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
            #endif
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
        .inlineNavigationTitle()
        .themedRoot()
    }

    #if os(macOS)
    /// The accents as System Settings shows them: small swatches in a row, the chosen one ringed and named beside them.
    private var macAccents: some View {
        HStack(spacing: 8) {
            ForEach(AccentTheme.allCases) { theme in
                let selected = theme == accent
                Button { appearance.accent = theme } label: {
                    Circle()
                        .fill(theme.swatch)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selected { Circle().stroke(Color(platform: theme.tint), lineWidth: 2).padding(-3) }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.title)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Text(accent.title).foregroundStyle(.secondary).frame(minWidth: 64, alignment: .leading)
                .accessibilityHidden(true)
        }
    }
    #endif

    /// The real bubble's footer at preview size: caption2 time and the shared read mark, both in the
    /// meta colour, inside the 20 pt bubble with the timeline's 12/10/8 insets.
    private func bubble(_ text: String, time: String, incoming: Bool) -> some View {
        let textColor = incoming ? Color.primary : Color(platform: accent.bubbleText)
        let meta = incoming ? Color.secondaryLabel : Color(platform: accent.bubbleText.withAlphaComponent(0.75))
        return HStack {
            if !incoming { Spacer(minLength: 60) }
            VStack(alignment: .trailing, spacing: 3) {
                Text(text).foregroundStyle(textColor)
                HStack(spacing: 5) {
                    Text(time).font(.caption2)
                    if !incoming {
                        Image(platformImage: MessageStatusArt.image(.read, scale: statusScale))
                            .renderingMode(.template)
                            .frame(width: MessageStatusArt.slotWidth * statusScale,
                                   height: MessageStatusArt.designHeight * statusScale, alignment: .trailing)
                    }
                }
                .foregroundStyle(meta)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .background(incoming ? Color.tertiaryFill : accent.swatch, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if incoming { Spacer(minLength: 60) }
        }
    }
}
