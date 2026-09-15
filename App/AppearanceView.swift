import SwiftUI

struct AppearanceView: View {
    static let modeKey = "appearanceMode"
    static func colorScheme(for mode: String) -> ColorScheme? {
        switch mode { case "light": .light; case "dark": .dark; default: nil }
    }

    @AppStorage(AppearanceView.modeKey) private var mode = "automatic"
    @AppStorage(AccentTheme.storageKey) private var accentRaw = AccentTheme.indigo.rawValue

    private var accent: AccentTheme { AccentTheme(rawValue: accentRaw) ?? .indigo }

    var body: some View {
        List {
            Section("Theme") {
                Picker("Theme", selection: $mode) {
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
                        Button { accentRaw = theme.rawValue } label: {
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
    }

    private func bubble(_ text: String, time: String, incoming: Bool) -> some View {
        HStack {
            if !incoming { Spacer(minLength: 60) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(text)
                HStack(spacing: 3) {
                    Text(time)
                    if !incoming { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                }
                .font(.caption2).opacity(0.7)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(incoming ? Color.primary : Color(uiColor: accent.bubbleText))
            .background(incoming ? Color(uiColor: .systemGray5) : accent.swatch, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if incoming { Spacer(minLength: 60) }
        }
    }
}
