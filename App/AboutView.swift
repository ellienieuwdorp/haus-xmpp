import SwiftUI

/// What the About screen, the support mail and the Mac's About panel say about this build. Version, build and
/// copyright come from the bundle's Info.plist, so they are what was built.
enum AppInfo {
    static let name = "Haus XMPP"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static var versionLine: String { "Version \(version) (\(build))" }
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Ellie Nieuwdorp and the Haus XMPP contributors"
    }
    static let warranty = "Haus XMPP comes with ABSOLUTELY NO WARRANTY. This is free software under the GNU GPL version 3 or later; you may redistribute it under its terms."

    /// The repository; the exact source of each released build is tagged there.
    static let sourceCode = URL(string: "https://github.com/ellienieuwdorp/haus-xmpp")!
    static let privacyPolicy = URL(string: "https://xmpp.haus/privacy")!
    static let support = URL(string: "https://xmpp.haus/support")!
    static let supportAddress = "ellie@xmpp.haus"

    /// "iOS 26.1": the system and its version, nothing that tells one device from another.
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "\(ThisDevice.systemName) \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    /// A new mail to support with the app and system versions filled in. Nothing about the account, its server or the
    /// device goes in: the person adds what they want to share.
    static var supportMail: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Haus XMPP support"),
            URLQueryItem(name: "body", value: "\n\n\nHaus XMPP \(version) (\(build))\n\(systemVersion)\n")
        ]
        return components.url!
    }
}

/// Settings > About: the build, the copyright and licence notice, and where the source, privacy policy, support and
/// licences are.
struct AboutView: View {
    var body: some View {
        GroupedList {
            Section {
                VStack(spacing: 10) {
                    AppIconView()
                    Text(AppInfo.name).font(.title2.weight(.bold))
                    Text(AppInfo.versionLine).font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("aboutVersion")
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
            }
            Section {
                ExternalLinkRow(title: "Source code", url: AppInfo.sourceCode, systemName: "chevron.left.forwardslash.chevron.right", color: .gray)
                ExternalLinkRow(title: "Privacy policy", url: AppInfo.privacyPolicy, systemName: "hand.raised.fill", color: .blue)
                ExternalLinkRow(title: "Support", url: AppInfo.support, systemName: "questionmark", color: .green)
                NavigationLink { LicencesView() } label: {
                    Label { Text("Licences") } icon: { SettingsIconTile(systemName: "doc.text.fill", color: .indigo) }
                }
                .accessibilityIdentifier("licencesRow")
            } footer: {
                legalNotice
            }
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The copyright and licence notice every copy shows (GPL section 0, "Appropriate Legal Notices").
    private var legalNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppInfo.copyright)
            Text(AppInfo.warranty)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

/// A row that opens a web page, styled like the other settings rows rather than as tinted link text.
struct ExternalLinkRow: View {
    let title: String
    let url: URL
    let systemName: String
    let color: Color

    var body: some View {
        Link(destination: url) {
            HStack {
                Label { Text(title) } icon: { SettingsIconTile(systemName: systemName, color: color) }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityHint("Opens \(url.host() ?? "the page") in your browser")
    }
}

/// The app icon as the Home Screen or Dock shows it.
private struct AppIconView: View {
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 88

    var body: some View {
        // Grows with the text, but not past the point where it pushes the links off a phone's screen.
        let size = min(size, 120)
        if let icon = PlatformApplication.iconImage {
            Image(platformImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                #if os(iOS)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                #endif
                .accessibilityHidden(true)
        }
    }
}

// MARK: Licences

/// One component's notices, as bundled: whole files from the repository, or a component's section of
/// THIRD_PARTY_LICENSES.md. Nothing here repeats licence text; it only says where the text is.
struct LicenceEntry: Identifiable, Hashable {
    enum Source: Hashable {
        /// A bundled file, shown under `title`.
        case file(String, title: String)
        /// The `## heading` section of THIRD_PARTY_LICENSES.md.
        case thirdPartySection(String)
    }

    let name: String
    let sources: [Source]
    var id: String { name }

    static let thirdPartyFile = "THIRD_PARTY_LICENSES.md"

    /// Haus XMPP first, then each component THIRD_PARTY_LICENSES.md lists, in its order.
    static let all: [LicenceEntry] = [
        LicenceEntry(name: "Haus XMPP", sources: [
            .file("LICENSE-ADDITIONAL-PERMISSION", title: "Additional permission for Apple distribution"),
            .file("LICENSE", title: "GNU General Public License, version 3")
        ]),
        LicenceEntry(name: "libomemo-c", sources: [
            .file("NOTICE.libomemo-c", title: "Notice"),
            .file("LICENSE.libomemo-c", title: "GNU General Public License, version 3")
        ]),
        LicenceEntry(name: "curve25519-donna", sources: [.thirdPartySection("curve25519-donna")]),
        LicenceEntry(name: "ed25519 ref10 and nacl_sha512", sources: [.thirdPartySection("ed25519 ref10 and nacl_sha512")]),
        LicenceEntry(name: "uthash, utlist and utarray", sources: [.thirdPartySection("uthash, utlist, utarray")]),
        LicenceEntry(name: "vpool", sources: [.thirdPartySection("vpool")]),
        LicenceEntry(name: "protobuf-c", sources: [.file("LICENSE.protobuf-c", title: "Licence")])
    ]

    struct Document {
        let title: String?
        /// Nil when the bundle lacks it (a build that left a resource out).
        let text: String?
        /// A section of THIRD_PARTY_LICENSES.md, whose code spans are Markdown; the licence files are plain text.
        let isMarkdown: Bool
    }

    func documents(in bundle: Bundle = .main) -> [Document] {
        sources.map { source in
            switch source {
            case let .file(name, title): Document(title: title, text: Self.read(name, in: bundle), isMarkdown: false)
            case let .thirdPartySection(heading):
                Document(title: nil, text: Self.read(Self.thirdPartyFile, in: bundle).flatMap { Self.section(heading, of: $0) },
                         isMarkdown: true)
            }
        }
    }

    static func read(_ name: String, in bundle: Bundle) -> String? {
        bundle.url(forResource: name, withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The `## heading` section of a Markdown file, up to the next `## ` heading or rule, with the four-space indent of
    /// its quoted licence blocks removed.
    static func section(_ heading: String, of markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: "## " + heading) else { return nil }
        let body = lines[(start + 1)...].prefix { !$0.hasPrefix("## ") && $0 != "---" }
        return body.map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : $0 }.joined(separator: "\n")
    }

    /// The `## ` headings of a Markdown file, for checking that every listed component has an entry.
    static func headings(of markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
    }

    /// Plain text wrapped for a narrow screen: the files break lines at about 72 columns, which would leave ragged
    /// half-lines on a phone. Lines are joined within paragraphs (separated by blank lines), except that a list item
    /// ("(a) ", "1. ", "* ") starts a line of its own; runs of spaces collapse, and underline or rule lines of `=` or
    /// `-` are dropped.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (line.count >= 3 && line.allSatisfy { $0 == "=" || $0 == "-" }) { flush(); continue }
            if current.isEmpty { current = line }
            else { current += (line.wholeMatch(of: listItem) != nil ? "\n" : " ") + line }
        }
        flush()
        return result
    }

    private nonisolated(unsafe) static let listItem = /(\(?([a-z]|[0-9]{1,2})[.)]|[*•-]) .*/
}

/// Settings > About > Licences.
struct LicencesView: View {
    var body: some View {
        List(LicenceEntry.all) { entry in
            NavigationLink(entry.name) { LicenceTextView(entry: entry) }
        }
        .navigationTitle("Licences")
    }
}

/// One component's full licence text, selectable.
struct LicenceTextView: View {
    let entry: LicenceEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(entry.documents().enumerated()), id: \.offset) { _, document in
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = document.title {
                            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                        }
                        if let text = document.text {
                            Text(Self.rendered(text, markdown: document.isMarkdown))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("This text is missing from this build. It is in the source code.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.groupedBackground)
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Paragraphs one blank line apart; in Markdown, inline syntax (code spans) is rendered.
    private static func rendered(_ text: String, markdown: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = AttributedString()
        for (index, paragraph) in LicenceEntry.paragraphs(text).enumerated() {
            if index > 0 { result += AttributedString("\n\n") }
            let parsed = markdown ? try? AttributedString(markdown: paragraph, options: options) : nil
            result += parsed ?? AttributedString(paragraph)
        }
        return result
    }
}
