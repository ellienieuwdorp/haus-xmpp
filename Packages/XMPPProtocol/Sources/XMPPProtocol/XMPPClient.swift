import Foundation
#if canImport(os)
import os
#endif
import dnssd
import Network
import Security

public enum XMPPConnectionState: Sendable, Equatable {
    case disconnected(String?)
    case connecting
    case authenticating
    case binding
    case online(jid: String)
}

public struct XMPPMessage: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let body: String
    /// Untrusted sender-provided identifier, scoped by the application to its provenance.
    public let originID: String?
    public let type: String?
    public let provenance: XMPPMessageProvenance

    public init(id: String, from: String, to: String?, body: String, originID: String? = nil, type: String? = nil, provenance: XMPPMessageProvenance = .direct) {
        self.id = id; self.from = from; self.to = to; self.body = body
        self.originID = originID; self.type = type; self.provenance = provenance
    }
}

/// An unencrypted XEP-0444 reaction as widely deployed clients send it. The actor is only
/// server-authenticated; the target identifier is untrusted until the store resolves it uniquely.
public struct XMPPReaction: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let targetID: String
    public let reactions: [String]
    public let provenance: XMPPMessageProvenance
}

/// A peer's unencrypted XEP-0184 receipt or XEP-0333 marker. The actor is server-authenticated only.
public struct XMPPReceipt: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let targetID: String
    public let kind: MessageContent.Receipt.Kind
    public let provenance: XMPPMessageProvenance
    public init(id: String, from: String, to: String?, targetID: String, kind: MessageContent.Receipt.Kind, provenance: XMPPMessageProvenance = .direct) {
        self.id = id; self.from = from; self.to = to; self.targetID = targetID; self.kind = kind; self.provenance = provenance
    }
}

/// A caller-resolved direct-chat reply target plus a bounded plaintext fallback snapshot.
/// IDs must come from the original wire message, never a generated local database ID.
/// A nil ID emits only the quoted body, without structured reply/fallback metadata.
public struct XMPPReply: Sendable, Equatable {
    public let id: String?
    public let to: String
    public let body: String

    public init(id: String? = nil, to: String, body: String) {
        self.id = id; self.to = to; self.body = body
    }
}

/// An unencrypted XEP-0424 retraction; same trust as a plain reaction.
public struct XMPPRetraction: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let targetID: String
    public let provenance: XMPPMessageProvenance
    public init(id: String, from: String, to: String?, targetID: String, provenance: XMPPMessageProvenance = .direct) {
        self.id = id; self.from = from; self.to = to; self.targetID = targetID; self.provenance = provenance
    }
}

public enum XMPPEvent: Sendable, Equatable {
    case state(XMPPConnectionState)
    case message(XMPPMessage)
    case reaction(XMPPReaction)
    case retraction(XMPPRetraction)
    case receipt(XMPPReceipt)
    /// Emitted before the stanza's other event, so a state riding on a message is seen first.
    case chatState(XMPPChatState)
    case encryptedMessage(XMPPEncryptedMessage)
    case encryptedGroupMessage(XMPPEncryptedGroupMessage)
    case groupPresence(room: String)
    case omemoDevices(owner: String, profile: XMPPOMEMOProfile, devices: [UInt32])
    /// A contact's PEP avatar changed; nil means it was removed. The bytes are fetched lazily.
    case avatarMetadata(owner: String, metadata: XMPPAvatarMetadata?)
    case encryptionFailure(from: String, id: String?)
    /// A contact resource became available, idle or unavailable. Never stored.
    case contactPresence(XMPPContactPresence)
    /// A contact asked for, granted, withdrew or refused a presence subscription.
    case subscription(XMPPSubscriptionEvent)
    /// A roster fetch result (`replacesAll`) or one server push, in stream order.
    case rosterItems([XMPPRosterItem], replacesAll: Bool)
    /// XEP-0490 items another device of this account published; the notification came from our own bare JID.
    case displayedSync([XMPPDisplayedItem])
    /// Consume previous events durably before acknowledging this token.
    case streamManagementBarrier(XMPPInboundToken)
    case streamAcknowledged
}

/// What the session tells contacts and the server about the user's attention.
public enum XMPPAvailability: Sendable, Equatable, Codable {
    /// The app is in front: plain available presence, and CSI `<active/>` on a resumed stream.
    case active
    /// Away from the app (backgrounded, the notification extension, a notification action): XEP-0319
    /// `<idle since/>` with the last time the app was in front, then CSI `<inactive/>`. nil omits the timestamp,
    /// for an account that does not share last seen.
    case away(since: Date?)
}

public enum XMPPClientError: Error, Sendable {
    case invalidConfiguration, alreadyConnected, notConnected, authenticationUnavailable
    case authenticationFailed, bindingFailed, unexpectedProtocol, connectionClosed, timedOut, eventConsumerTooSlow
    /// The server could not check the credentials right now (`temporary-auth-failure`, `aborted`): retry later.
    case authenticationRetryable
    /// The account authenticated with SCRAM before and the server now offers only weaker mechanisms.
    case authenticationDowngrade
    /// A STARTTLS endpoint did not offer or refused TLS. Nothing was sent in plaintext.
    case encryptionUnavailable
    /// The domain's SRV records say it offers no client service (target ".").
    case serviceNotOffered
}

/// What a successful `connect` used; the caller remembers both for the next connection.
public struct XMPPConnectedSession: Sendable, Equatable {
    public let endpoint: XMPPEndpoint
    public let authenticatedWithSCRAM: Bool

    public init(endpoint: XMPPEndpoint, authenticatedWithSCRAM: Bool) {
        self.endpoint = endpoint; self.authenticatedWithSCRAM = authenticatedWithSCRAM
    }
}

/// Direct TLS or mandatory STARTTLS, reached through SRV discovery or a fixed endpoint, with SCRAM or PLAIN over SASL1,
/// OMEMO PEP, durable stream management and bounded archive recovery. Every mechanism runs only inside validated TLS.
/// Never use this API as an encryption fallback.
public actor XMPPClient {
    public nonisolated let events: AsyncStream<XMPPEvent>
    private let continuation: AsyncStream<XMPPEvent>.Continuation
    private let labCertificateAuthority: Data?
    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var liveness: Task<Void, Never>?
    /// Counts inbound reads; a probe that does not move it means the socket is dead.
    private var inboundActivity: UInt64 = 0
    /// Silence longer than this gets a probe; a probe unanswered within `probeTimeout` ends the stream.
    static let silenceInterval: Duration = .seconds(60)
    static let probeTimeout: Duration = .seconds(15)
    /// Every inbound `<message/>` yields two events (content and barrier), and stream management already
    /// ends the stream at 2,000 received-but-unhandled stanzas, so for message traffic that ceiling binds
    /// first. Overflow still ends the connection (`eventConsumerTooSlow`); nothing dropped is acknowledged.
    static let eventBufferLimit = 4096
    /// The default reply deadline for a request.
    public static let iqTimeout: Duration = .seconds(15)
    /// A MAM `<fin/>` arrives only after every result of the page was streamed: 100 results of a few KiB
    /// take tens of seconds on a slow link. Still within one liveness interval, so a dead query stays bounded.
    static let archiveQueryTimeout: Duration = .seconds(60)
    /// A deliberate disconnect's last writes (away presence, final `<a/>`): a socket that cannot take a few hundred
    /// bytes in this time is closed without them.
    static let farewellWriteLimit: Duration = .milliseconds(500)
    /// The round trip before a final `<a/>`; on a dead socket the disconnect gives up on it this quickly.
    static let farewellRoundTripLimit: Duration = .milliseconds(750)
    private var generation = UUID()
    private var phase: Phase = .idle
    private var framer = XMLStreamFramer()
    private(set) var domain = ""
    private var username = ""
    private var password = ""
    private var requireSCRAM = false
    private var sasl: SASLNegotiation?
    private var authenticatedWithSCRAM = false
    /// One TCP/TLS attempt of a connect; a failed candidate is abandoned without ending the connect.
    private var attempt = UUID()
    private var abandonedError: Error?
    /// Set on the first stream features inside TLS: from then on a failure ends the connect instead of moving on.
    private var committed = false
    /// A candidate must reach TLS stream features within this; the whole login within `loginTimeout` of its start.
    static let candidateTimeout: Duration = .seconds(10)
    static let loginTimeout: Duration = .seconds(20)
    /// No DNS query or further candidate starts after this; a candidate's own time is cut to what is left.
    static let connectTimeout: Duration = .seconds(30)
    static let discoveryTimeout: Duration = .seconds(5)
    private var bindID = ""
    private var boundJID = ""
    /// Requested on every fresh bind, so a new session replaces this installation's previous one instead of
    /// joining it as a second resource. The owner persists one per installation and account (`configureResource`).
    private var resource = XMPPClient.makeResource()
    /// A bind the server refused (for example a resource conflict) is retried once with a server-assigned resource.
    private var bindRetried = false
    private var availability = XMPPAvailability.active
    /// What the server holds for this session: nil until initial presence; on a resume, what the snapshot recorded.
    private var announced: XMPPAvailability?
    /// Counts emitted events, so the reader can tell whether a stanza produced any.
    private var emittedEvents: UInt64 = 0
    private struct IQRequest {
        let scope: IQReplyScope
        let continuation: CheckedContinuation<XMLNode, Error>
        let timeout: Task<Void, Never>
    }
    private var iqRequests: [String: IQRequest] = [:]
    private var archiveQuery: ArchiveQuery?
    /// Pending roster fetch IQ ids; their results are emitted in stream order, before any later push.
    private var rosterFetchIDs: Set<String> = []
    /// RFC 6121 §2.1.6: pushes go only to resources that requested the roster in this session.
    private var rosterRequested = false
    /// Whether an XEP-0012 query to our full JID is answered. Survives reconnects; the owner sets it.
    private var sharesLastActivity = false
    /// The current session continued an earlier one (XEP-0198 resume): no initial presence was sent, so the server
    /// sent no probe answers and presence seen on the earlier stream still holds.
    public private(set) var sessionResumed = false
    var groupRooms: [String: GroupRoomState] = [:]
    /// In-flight membership validations by room and cache use, so concurrent refreshes of one room share one read.
    var roomRefreshes: [GroupRoomRefreshKey: GroupRoomRefresh] = [:]
    private var streamManagement: StreamManagement?
    private var resumeSnapshot: XMPPStreamManagementSnapshot?
    private var smOffered = false
    private var csiOffered = false
    private let writeGate = XMPPAsyncGate()
    private var handshake: CheckedContinuation<Void, Error>?
    private let queue = DispatchQueue(label: "xmpp.transport")
    private enum Phase { case idle, features, authentication, authenticatedFeatures, binding, enablingSM, resumingSM, online }

    /// A DER CA certificate is exclusively for the explicit local lab. System trust is the default.
    public init(labCertificateAuthority: Data? = nil) {
        self.labCertificateAuthority = labCertificateAuthority
        let pair = AsyncStream<XMPPEvent>.makeStream(bufferingPolicy: .bufferingOldest(XMPPClient.eventBufferLimit))
        events = pair.stream
        continuation = pair.continuation
    }

    /// A fixed endpoint; the default is the lab's direct TLS on 5223.
    @discardableResult
    public func connect(host: String, port: UInt16 = 5223, security: XMPPTransportSecurity = .directTLS, domain: String,
                        username: String, password: String, requireSCRAM: Bool = false) async throws -> XMPPConnectedSession {
        try await connect(route: .fixed(XMPPEndpoint(host: host, port: port, security: security)), domain: domain,
                          username: username, password: password, requireSCRAM: requireSCRAM)
    }

    /// Tries the route's candidates in order. A candidate that cannot be reached, fails TLS or refuses STARTTLS is
    /// skipped; the error is reported only after the last one. Once a candidate delivers stream features inside TLS the
    /// connect is committed to it: authentication and binding failures end it. `requireSCRAM` refuses PLAIN.
    @discardableResult
    public func connect(route: XMPPRoute, domain: String, username: String, password: String,
                        requireSCRAM: Bool = false) async throws -> XMPPConnectedSession {
        guard connection == nil, phase == .idle else { throw XMPPClientError.alreadyConnected }
        let validRoute = switch route {
        case .fixed(let endpoint): !endpoint.host.isEmpty && endpoint.port > 0
        case .discover(let preferred): preferred.map { !$0.host.isEmpty && $0.port > 0 } ?? true
        }
        guard validRoute, !domain.isEmpty, !username.isEmpty, !password.isEmpty,
              !username.contains("\0"), !password.contains("\0"), !domain.contains(where: { $0.isWhitespace }) else { throw XMPPClientError.invalidConfiguration }
        groupRooms.removeAll(); rosterFetchIDs.removeAll(); rosterRequested = false
        self.domain = domain; self.username = username; self.password = password; self.requireSCRAM = requireSCRAM
        authenticatedWithSCRAM = false
        phase = .features; generation = UUID()
        let token = generation
        do { resumeSnapshot = try await streamManagement?.restore(accountID: username + "@" + domain) }
        catch { if generation == token { phase = .idle; self.password = "" }; throw error }
        guard generation == token else { throw XMPPClientError.connectionClosed }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try emit(.state(.connecting))
                var candidates: [XMPPEndpoint]
                var discovered: Bool
                switch route {
                case .fixed(let endpoint): candidates = [endpoint]; discovered = true
                case .discover(let preferred): candidates = preferred.map { [$0] } ?? []; discovered = false
                }
                var tried = Set<XMPPEndpoint>()
                var failure: Error?
                let giveUp = ContinuousClock.now + Self.connectTimeout
                while true {
                    let remaining = giveUp - .now
                    guard remaining > .zero else { failure = failure ?? XMPPClientError.timedOut; break }
                    if candidates.isEmpty {
                        guard !discovered else { break }
                        discovered = true
                        let resolved = await EndpointDiscovery.resolve(domain: domain, timeout: min(Self.discoveryTimeout, remaining))
                        // Cancellation cuts the queries short; never dial what they left behind.
                        try Task.checkCancellation()
                        guard generation == token else { throw XMPPClientError.connectionClosed }
                        if resolved.isEmpty { failure = XMPPClientError.serviceNotOffered }
                        candidates = resolved.filter { !tried.contains($0) }
                        continue
                    }
                    let endpoint = candidates.removeFirst()
                    tried.insert(endpoint)
                    do {
                        try await connect(to: endpoint, token: token, within: min(Self.candidateTimeout, remaining))
                        return XMPPConnectedSession(endpoint: endpoint, authenticatedWithSCRAM: authenticatedWithSCRAM)
                    } catch let skipped as CandidateFailure {
                        guard generation == token else { throw XMPPClientError.connectionClosed }
                        // A refused STARTTLS says more than a later unreachable fallback.
                        if (failure as? XMPPClientError) != .encryptionUnavailable { failure = skipped.error }
                    }
                }
                throw failure ?? XMPPClientError.connectionClosed
            } onCancel: {
                Task { await self.cancel(token) }
            }
        } catch {
            if generation == token { finish(Self.safeDescription(error, otherwise: "TLS connection failed"), error: error) }
            throw error
        }
    }

    /// One candidate, from TCP to online. A failure before commitment throws `CandidateFailure`.
    private func connect(to endpoint: XMPPEndpoint, token: UUID, within candidateTimeout: Duration) async throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port), port.rawValue > 0 else { throw CandidateFailure(error: XMPPClientError.invalidConfiguration) }
        framer = XMLStreamFramer(); phase = .features; committed = false; abandonedError = nil
        let attemptID = UUID()
        attempt = attemptID
        let conn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port,
                                using: XMPPTransport.parameters(for: endpoint.security, domain: domain,
                                                                labCertificateAuthority: labCertificateAuthority, queue: queue))
        connection = conn
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: candidateTimeout) } catch { return }
            guard await self?.candidateDeadline(token, attempt: attemptID) == true else { return }
            do { try await Task.sleep(for: Self.loginTimeout - candidateTimeout) } catch { return }
            await self?.timeout(token)
        }
        do {
            try await Self.start(conn, queue: queue)
            guard generation == token, attempt == attemptID else { throw XMPPClientError.connectionClosed }
            try await write(streamOpening())
        } catch {
            guard generation == token else { throw XMPPClientError.connectionClosed }
            abandonAttempt(attemptID, error: Self.transportError(error))
            throw CandidateFailure(error: abandonedError ?? error)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard generation == token, attempt == attemptID else {
                continuation.resume(throwing: generation == token ? CandidateFailure(error: abandonedError ?? XMPPClientError.connectionClosed)
                                                                  : XMPPClientError.connectionClosed)
                return
            }
            handshake = continuation
            reader = Task { [weak self] in await self?.readLoop(conn, token: token, attempt: attemptID) }
        }
    }

    /// Returns whether the attempt is still logging in (committed); an uncommitted one is abandoned.
    private func candidateDeadline(_ token: UUID, attempt attemptID: UUID) -> Bool {
        guard generation == token, attempt == attemptID else { return false }
        if committed { return true }
        abandonAttempt(attemptID, error: XMPPClientError.timedOut)
        return false
    }

    /// Drops one uncommitted candidate without ending the connect or emitting a disconnect.
    private func abandonAttempt(_ attemptID: UUID, error: Error) {
        guard attempt == attemptID, !committed else { return }
        attempt = UUID(); abandonedError = error
        deadline?.cancel(); deadline = nil
        connection?.cancel(); connection = nil
        reader?.cancel()
        handshake?.resume(throwing: CandidateFailure(error: error)); handshake = nil
    }

    public func disconnect() {
        finish(nil)
    }

    /// External lifecycle boundary: cancel the connection and join its current reader before
    /// releasing a shared database lease. Never call this from the reader/event parser itself.
    /// Application event consumers and senders must also be cancelled and joined by their owner.
    public func disconnectAndWait() async {
        let previousReader = reader
        // XEP-0198 recommends a last `<a/>` before a graceful close. Without it the server still counts what we
        // handled since its last `<r/>` as unacknowledged, and Prosody's mod_cloud_notify pushes for that queue
        // when the session starts hibernating. Bounded: a stuck write ends the connection instead.
        if phase == .online, smOffered, streamManagement != nil {
            // One round trip first: what the server sent before its answer (our own presence reflected, a room's
            // join answer) has then been read and, where it needs nothing durable, counted.
            _ = try? await requestIQ(type: "get", to: nil, payload: "<ping xmlns='urn:xmpp:ping'/>", timeout: Self.farewellRoundTripLimit)
            try? await withFarewellDeadline { try await self.writeAcknowledgement(detaching: true) }
        }
        finish(nil)
        await previousReader?.value
        // Best effort, after the socket is gone so a held journal gate never delays the cancel: the
        // next connection (app or extension) resumes with the highest durable h. A lagging counter
        // only causes redelivery of stanzas whose dispositions are already saved.
        _ = try? await streamManagement?.flushHandled()
    }

    /// Completion means only that the local socket accepted the write, not server or peer delivery.
    /// Retrying an uncertain write must preserve the same caller-supplied ID.
    @discardableResult public func sendMessage(to: String, body: String, id: String = UUID().uuidString, reply: XMPPReply? = nil) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.messageXML(to: to, body: body, id: id, reply: reply))
        return id
    }

    /// Unencrypted XEP-0444, the only form legacy-OMEMO peers such as Conversations send or accept.
    @discardableResult public func sendReaction(to: String, targetID: String, reactions: [String], id: String = UUID().uuidString) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.reactionXML(to: to, targetID: targetID, reactions: reactions, id: id))
        return id
    }

    /// Unencrypted XEP-0424 for legacy-OMEMO peers; the reference cannot ride inside their ciphertext.
    @discardableResult public func sendRetraction(to: String, targetID: String, id: String = UUID().uuidString) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.retractionXML(to: to, targetID: targetID, id: id))
        return id
    }

    public static func retractionXML(to: String, targetID: String, id: String) throws -> String {
        guard MessageContent.validAddress(to), MessageContent.validIdentifier(id) else { throw XMPPClientError.invalidConfiguration }
        let content = try MessageContent(body: "", retraction: targetID).xml()
        return "<message to='\(xmlEscaped(to))' type='chat' id='\(xmlEscaped(id))'>\(content)<store xmlns='urn:xmpp:hints'/></message>"
    }

    /// Unencrypted receipt/marker for legacy peers; modern peers get the same element inside SCE.
    @discardableResult public func sendReceipt(to: String, targetID: String, kind: MessageContent.Receipt.Kind, id: String = UUID().uuidString) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.receiptXML(to: to, targetID: targetID, kind: kind, id: id))
        return id
    }

    public static func receiptXML(to: String, targetID: String, kind: MessageContent.Receipt.Kind, id: String) throws -> String {
        guard MessageContent.validAddress(to), MessageContent.validIdentifier(id) else { throw XMPPClientError.invalidConfiguration }
        let content = try MessageContent(body: "", receipt: .init(targetID: targetID, kind: kind)).xml()
        return "<message to='\(xmlEscaped(to))' type='chat' id='\(xmlEscaped(id))'>\(content)<store xmlns='urn:xmpp:hints'/></message>"
    }

    public static func reactionXML(to: String, targetID: String, reactions: [String], id: String) throws -> String {
        guard MessageContent.validAddress(to), MessageContent.validIdentifier(id) else { throw XMPPClientError.invalidConfiguration }
        let content = try MessageContent(body: "", reaction: .init(targetID: targetID, reactions: reactions)).xml()
        // Same shape Conversations emits: the complete set, a store hint, no body.
        return "<message to='\(xmlEscaped(to))' type='chat' id='\(xmlEscaped(id))'>\(content)<store xmlns='urn:xmpp:hints'/></message>"
    }

    /// Why a message cannot be sent, so the caller can say which part is wrong.
    public enum MessageProblem: Sendable, Equatable {
        /// The recipient, the message ID or the reply's target is not a valid address or identifier.
        case invalidAddressing
        case emptyBody, bodyTooLong, bodyUnsupportedCharacters
        case emptyQuote, quoteTooLong, quoteUnsupportedCharacters
        /// Each part fits, but the quote and the text together are over the stanza limit.
        case combinedTooLong
    }

    /// Pure preflight for durable enqueueing; does not require a connected session. Nil when the message can be sent.
    public static func messageProblem(to: String, body: String, id: String, reply: XMPPReply? = nil) -> MessageProblem? {
        guard MessageContent.validAddress(to), MessageContent.validIdentifier(id) else { return .invalidAddressing }
        guard !body.isEmpty else { return .emptyBody }
        guard body.utf8.count <= 65_536 else { return .bodyTooLong }
        guard MessageContent.validXMLText(body) else { return .bodyUnsupportedCharacters }
        if let reply {
            guard reply.id.map(MessageContent.validIdentifier) ?? true, MessageContent.validAddress(reply.to) else { return .invalidAddressing }
            guard !reply.body.isEmpty else { return .emptyQuote }
            guard reply.body.utf8.count <= 16_384 else { return .quoteTooLong }
            guard MessageContent.validXMLText(reply.body) else { return .quoteUnsupportedCharacters }
            guard replyFallback(reply.body).utf8.count + body.utf8.count <= 65_536 else { return .combinedTooLong }
        }
        return nil
    }

    public static func validateMessage(to: String, body: String, id: String, reply: XMPPReply? = nil) throws {
        if messageProblem(to: to, body: body, id: id, reply: reply) != nil { throw XMPPClientError.invalidConfiguration }
    }

    static func messageXML(to: String, body: String, id: String, reply: XMPPReply? = nil, requestReceipt: Bool = false, markable: Bool = false) throws -> String {
        try validateMessage(to: to, body: body, id: id, reply: reply)
        let content = try MessageContent(body: body, reply: reply.map { .init(id: $0.id, to: $0.to, quote: replyFallback($0.body)) },
                                         requestsReceipt: requestReceipt, markable: markable, originID: id).xml()
        return "<message to='\(xmlEscaped(to))' type='chat' id='\(xmlEscaped(id))'>\(content)</message>"
    }

    private static func replyFallback(_ body: String) -> String {
        // XML normalizes literal CR/CRLF to LF; normalize before counting fallback offsets.
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n"
    }

    /// Payload of an unencrypted direct stanza. Ambiguous extensions are dropped, never fatal.
    private static func plainContent(_ node: XMLNode) -> (from: String, content: MessageContent)? {
        guard node.name == "message", node.namespace == "jabber:client",
              node.attributes["type"] == nil || node.attributes["type"] == "chat" || node.attributes["type"] == "normal",
              !OMEMOWire.hasEncryptedContent(node), !Carbons.containsWrapper(node),
              let from = node.attributes["from"], !from.isEmpty,
              let content = try? MessageContent.decode(node, strict: false) else { return nil }
        return (from, content)
    }

    static func parsedMessage(_ node: XMLNode, provenance: XMPPMessageProvenance = .direct) -> XMPPMessage? {
        guard let (from, content) = plainContent(node), !content.text.isEmpty else { return nil }
        return XMPPMessage(id: node.attributes["id"] ?? UUID().uuidString, from: from, to: node.attributes["to"],
                           body: content.text, originID: content.originID, type: node.attributes["type"], provenance: provenance)
    }

    static func parsedRetraction(_ node: XMLNode, provenance: XMPPMessageProvenance = .direct) -> XMPPRetraction? {
        guard let (from, content) = plainContent(node), let target = content.retraction else { return nil }
        return XMPPRetraction(id: node.attributes["id"].flatMap { MessageContent.validIdentifier($0) ? $0 : nil } ?? UUID().uuidString, from: from,
                              to: node.attributes["to"], targetID: target, provenance: provenance)
    }

    static func parsedReceipt(_ node: XMLNode, provenance: XMPPMessageProvenance = .direct) -> XMPPReceipt? {
        guard let (from, content) = plainContent(node), let receipt = content.receipt else { return nil }
        return XMPPReceipt(id: node.attributes["id"].flatMap { MessageContent.validIdentifier($0) ? $0 : nil } ?? UUID().uuidString, from: from,
                           to: node.attributes["to"], targetID: receipt.targetID, kind: receipt.kind, provenance: provenance)
    }

    static func parsedReaction(_ node: XMLNode, provenance: XMPPMessageProvenance = .direct) -> XMPPReaction? {
        guard let (from, content) = plainContent(node), let reaction = content.reaction else { return nil }
        return XMPPReaction(id: node.attributes["id"].flatMap { MessageContent.validIdentifier($0) ? $0 : nil } ?? UUID().uuidString, from: from,
                            to: node.attributes["to"], targetID: reaction.targetID, reactions: reaction.reactions, provenance: provenance)
    }

    /// Our own resources and our own room nickname are dropped; a group state needs a room we are in. A delayed copy
    /// (offline storage, room history) is stale, and a room's private messages are not the room typing.
    static func parsedChatState(_ node: XMLNode, account: String, rooms: [String: GroupRoomState]) -> XMPPChatState? {
        guard let state = XMPPChatState.state(of: node), let from = node.attributes["from"],
              let bare = OMEMOWire.bareJID(from), bare != account,
              node.children("delay", namespace: "urn:xmpp:delay").isEmpty else { return nil }
        let ridesOnMessage = !node.children("body", namespace: "jabber:client").isEmpty || OMEMOWire.hasEncryptedContent(node)
        switch node.attributes["type"] {
        case "groupchat":
            let nickname = String(from.dropFirst(bare.count + 1))
            guard let room = rooms[bare], from.hasPrefix(bare + "/"), !nickname.isEmpty, nickname != room.nickname else { return nil }
            let real = room.occupants[from]
            guard real != account else { return nil }
            return XMPPChatState(chat: bare, participant: real ?? nickname, state: state, ridesOnMessage: ridesOnMessage)
        case nil, "chat":
            guard rooms[bare] == nil else { return nil }
            return XMPPChatState(chat: bare, state: state, ridesOnMessage: ridesOnMessage)
        default: return nil
        }
    }

    /// A hint, not a message: nothing is stored or retried. Groups need a joined room.
    public func sendChatState(_ state: XMPPChatState.State, to: String, groupchat: Bool = false) async throws {
        guard phase == .online else { throw XMPPClientError.notConnected }
        if groupchat, groupRooms[to]?.joined != true { throw XMPPGroupError.notJoined }
        try await write(XMPPChatState.xml(state, to: to, id: UUID().uuidString, groupchat: groupchat))
    }

    private func readLoop(_ conn: NWConnection, token: UUID, attempt attemptID: UUID) async {
        do {
            while generation == token && attempt == attemptID && !Task.isCancelled {
                let data = try await Self.receive(conn)
                guard generation == token, attempt == attemptID else { return }
                inboundActivity &+= 1
                for frame in try framer.feed(data) {
                    guard generation == token, attempt == attemptID else { return }
                    switch frame {
                    case .opened: break
                    case .closed: throw XMPPClientError.connectionClosed
                    case .element(let node): try await handle(node, token: token)
                    }
                }
            }
        } catch {
            guard generation == token, attempt == attemptID else { return }
            if committed { finish(Self.safeDescription(error), error: error) } else { abandonAttempt(attemptID, error: error) }
        }
    }

    private func handle(_ node: XMLNode, token: UUID) async throws {
        if node.name == "error", node.namespace == "http://etherx.jabber.org/streams" { throw XMPPClientError.unexpectedProtocol }
        switch phase {
        case .features:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw XMPPClientError.unexpectedProtocol }
            committed = true
            let mechanisms = node.child("mechanisms", namespace: SASLNegotiation.namespace)?.children
                .filter { $0.name == "mechanism" && $0.namespace == SASLNegotiation.namespace }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
            let negotiation = try SASLNegotiation(offered: Set(mechanisms), username: username, password: password, requireSCRAM: requireSCRAM)
            password = ""
            sasl = negotiation
            phase = .authentication
            try emit(.state(.authenticating))
            try await write("<auth xmlns='\(SASLNegotiation.namespace)' mechanism='\(negotiation.mechanism.rawValue)'>\(SASLNegotiation.encode(negotiation.initialResponse))</auth>")
        case .authentication:
            guard node.namespace == SASLNegotiation.namespace, var negotiation = sasl else { throw XMPPClientError.unexpectedProtocol }
            switch node.name {
            case "challenge":
                let response = try negotiation.respond(to: SASLNegotiation.decode(node.text))
                sasl = negotiation
                try await write("<response xmlns='\(SASLNegotiation.namespace)'>\(response.base64EncodedString())</response>")
            case "success":
                try negotiation.complete(SASLNegotiation.decode(node.text))
                sasl = nil
                authenticatedWithSCRAM = negotiation.usesSCRAM
                phase = .authenticatedFeatures
                framer = XMLStreamFramer()
                try await write(streamOpening())
            case "failure": throw SASLNegotiation.error(forFailure: node)
            default: throw XMPPClientError.unexpectedProtocol
            }
        case .authenticatedFeatures:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams",
                  node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil else { throw XMPPClientError.bindingFailed }
            smOffered = node.child("sm", namespace: "urn:xmpp:sm:3") != nil
            csiOffered = node.child("csi", namespace: PushNotifications.clientStateNamespace) != nil
            if smOffered, let snapshot = resumeSnapshot, let id = snapshot.streamID {
                phase = .resumingSM
                try await write("<resume xmlns='urn:xmpp:sm:3' previd='\(xmlEscaped(id))' h='\(UInt32(truncatingIfNeeded: snapshot.inboundHandled))'/>")
            } else { try await startBinding(resource: resource) }
        case .binding:
            if node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
               node.attributes["type"] == "error", !bindRetried {
                // RFC 6120 §7.7.2: a conflict or refused resource. Let the server pick one rather than fail the session.
                bindRetried = true
                try await startBinding(resource: nil)
                return
            }
            guard node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
                  node.attributes["type"] == "result",
                  let jid = node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.child("jid", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.text, !jid.isEmpty else { throw XMPPClientError.bindingFailed }
            // The server picks the resource and the canonical spelling, never another account (RFC 6120 §7.7).
            guard let bound = JID(jid), bound.localpart != nil, bound.resourcepart != nil,
                  bound.bare == JID.normalizedBare(username + "@" + domain) else { throw XMPPIdentityError.boundAccountMismatch }
            boundJID = bound.full
            if smOffered, streamManagement != nil {
                phase = .enablingSM
                // No `max`: the server's default applies (Prosody ignores the attribute; others cap it anyway).
                try await write("<enable xmlns='urn:xmpp:sm:3' resume='true'/>")
            } else { try await becomeOnline(token: token) }
        case .enablingSM:
            // The resource is stable, so the server may route to it (or replay a replaced session's queue) before
            // `<enabled/>`. Such stanzas are not counted by the server and are dropped here; archives cover them.
            if node.namespace == "jabber:client", ["message", "presence", "iq"].contains(node.name) { return }
            guard node.namespace == "urn:xmpp:sm:3", node.name == "enabled" else { throw XMPPClientError.unexpectedProtocol }
            let resumable = ["true", "1"].contains(node.attributes["resume"] ?? "false")
            let id = node.attributes["id"]
            guard !resumable || id.map(validArchiveID) == true else { throw XMPPClientError.unexpectedProtocol }
            let timeout = node.attributes["max"].flatMap(Self.smCount).map { min($0, StreamManagement.maxResumeTimeout) }
            try await streamManagement?.enable(accountID: username + "@" + domain, fullJID: boundJID,
                                               streamID: resumable ? id : nil, resumeTimeoutSeconds: resumable ? timeout : nil)
            try await becomeOnline(token: token)
        case .resumingSM:
            guard node.namespace == "urn:xmpp:sm:3" else { throw XMPPClientError.unexpectedProtocol }
            if node.name == "failed" {
                // A failed resume never triggers blind retransmission; MAM reconciles uncertain sends.
                resumeSnapshot = nil
                try await startBinding(resource: resource)
            } else {
                guard node.name == "resumed", let snapshot = resumeSnapshot,
                      node.attributes["previd"] == snapshot.streamID,
                      let h = Self.smCount(node.attributes["h"]), let streamManagement else { throw XMPPClientError.unexpectedProtocol }
                boundJID = JID.normalized(snapshot.fullJID) ?? snapshot.fullJID
                let replay = try await streamManagement.acknowledge(h, resumed: true)
                try emit(.streamAcknowledged)
                guard try await streamManagement.permitsReplay() else { throw XMPPStreamManagementError.invalidState }
                // IQs are never replayed: their continuations failed on disconnect and setup re-runs.
                for entry in replay {
                    guard entry.kind != .iq, let xml = entry.xml else { continue }
                    try await rawWrite(xml, expectedGeneration: token)
                }
                try await becomeOnline(token: token, resumed: true)
            }
        case .online:
            // Parse addresses once: everything below compares `from`/`to` (also forwarded ones) in normal form.
            let node = JID.normalizingAddresses(node)
            if node.namespace == "urn:xmpp:sm:3" {
                guard let streamManagement else { throw XMPPClientError.unexpectedProtocol }
                if node.name == "r" {
                    try await writeAcknowledgement()
                } else if node.name == "a", let h = Self.smCount(node.attributes["h"]) {
                    _ = try await streamManagement.acknowledge(h)
                    try emit(.streamAcknowledged)
                } else { throw XMPPClientError.unexpectedProtocol }
                return
            }
            let inbound = ["message", "iq", "presence"].contains(node.name) && node.namespace == "jabber:client" ? try await streamManagement?.receive() : nil
            if ArchiveQuery.containsWrapper(node) {
                if var query = archiveQuery, node.child("result", namespace: ArchiveQuery.namespace)?.attributes["queryid"] == query.queryID {
                    try query.receive(node)
                    if let inbound { query.handledTokens.append(inbound) }
                    archiveQuery = query
                } else if let inbound { try await streamManagement?.handled(inbound) }
                return
            }
            let rosterFetch = node.attributes["id"].map(rosterFetchIDs.contains) ?? false
            if routeIQ(node) {
                if rosterFetch, node.attributes["type"] == "result", let items = try? PresenceWire.rosterResult(node) {
                    try emit(.rosterItems(items, replacesAll: true))
                }
                if let inbound { try await streamManagement?.handled(inbound) }
                return
            }
            if node.name == "presence", node.namespace == "jabber:client",
               let occupant = node.attributes["from"], let room = OMEMOWire.bareJID(occupant), var state = groupRooms[room] {
                guard let account = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
                GroupChatWire.applyPresence(node, room: room, account: account, state: &state)
                groupRooms[room] = state
                try emit(.groupPresence(room: room))
            } else if node.name == "presence", node.namespace == "jabber:client", let account = OMEMOWire.bareJID(boundJID),
                      let event = PresenceWire.event(node, accountBareJID: account, accountFullJID: boundJID, rooms: Set(groupRooms.keys)) {
                try emit(event)
            }
            let emittedBefore = emittedEvents
            if node.name == "message", node.namespace == "jabber:client" {
                if Carbons.containsWrapper(node) {
                    // Malformed or foreign wrappers are discarded as a whole; their outer body
                    // must not become a plaintext fallback or their inner sender become trusted.
                    guard let ownBare = OMEMOWire.bareJID(boundJID),
                          let (forwarded, provenance) = try? Carbons.unwrap(node, accountBareJID: ownBare, accountFullJID: boundJID) else {
                        if let inbound { try await streamManagement?.handled(inbound) }; return
                    }
                    try emitMessage(forwarded, provenance: provenance)
                } else { try emitMessage(node, provenance: .direct) }
            } else if node.name == "iq", node.namespace == "jabber:client",
                      ["get", "set"].contains(node.attributes["type"] ?? ""), let id = node.attributes["id"] {
                if rosterRequested, let account = OMEMOWire.bareJID(boundJID),
                   let item = PresenceWire.rosterPush(node, accountBareJID: account) {
                    let to = node.attributes["from"].map { " to='\(xmlEscaped($0))'" } ?? ""
                    try await write("<iq type='result' id='\(xmlEscaped(id))'\(to)/>")
                    try emit(.rosterItems([item], replacesAll: false))
                } else if let response = PresenceWire.inlineResponse(node, accountFullJID: boundJID, sharesLastActivity: sharesLastActivity) {
                    // disco#info, XEP-0199 ping and XEP-0012; other requests are rejected explicitly.
                    try await write(response)
                }
            }
            if let inbound {
                // A message that produced events is handled once the consumer made them durable. One that produced
                // none (a room subject, a message from an unknown room) owes nothing: it counts at once, so a final
                // `<a/>` can cover it; contiguity still keeps h below any earlier stanza the consumer holds.
                if node.name == "message", emittedEvents != emittedBefore { try emit(.streamManagementBarrier(inbound)) }
                else { try await streamManagement?.handled(inbound) }
            }
        case .idle: throw XMPPClientError.unexpectedProtocol
        }
    }

    public func configureStreamManagement(persistence: any XMPPStreamManagementPersistence) throws {
        guard connection == nil, phase == .idle else { throw XMPPClientError.alreadyConnected }
        streamManagement = StreamManagement(persistence)
    }

    /// The resource every fresh bind requests. Without one a client keeps the random one it was created with.
    public func configureResource(_ resource: String) throws {
        guard connection == nil, phase == .idle else { throw XMPPClientError.alreadyConnected }
        guard Self.validResource(resource) else { throw XMPPClientError.invalidConfiguration }
        self.resource = resource
    }

    /// `haus-` and 16 random hex digits: names the client, nothing about the user or the device.
    public static func makeResource() -> String {
        "haus-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    public static func validResource(_ resource: String) -> Bool {
        (1...64).contains(resource.utf8.count) && resource.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// Before connecting: what the session announces once online (fresh or resumed). Online: announces it now if it
    /// changed, bounded like a farewell, since the caller is on its way to the background.
    public func setAvailability(_ availability: XMPPAvailability) async throws {
        // Whole seconds, as the wire carries it: the same moment computed by two processes compares equal.
        if case .away(let since?) = availability {
            self.availability = .away(since: Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down)))
        } else { self.availability = availability }
        guard phase == .online else { return }
        try await withFarewellDeadline { try await self.announceAvailability(initial: false) }
    }

    public func acknowledgeInbound(_ token: XMPPInboundToken) async throws {
        try await streamManagement?.handled(token)
    }

    /// Acknowledges a page's tokens together after every result and its cursor are durable.
    public func acknowledgeInbound(_ tokens: [XMPPInboundToken]) async throws {
        try await streamManagement?.handled(tokens)
    }

    public func requestAcknowledgement() async throws {
        guard phase == .online, streamManagement != nil, smOffered else { throw XMPPClientError.notConnected }
        try await write("<r xmlns='urn:xmpp:sm:3'/>")
    }

    /// Caller must persist every result and its archive position before acknowledging handledTokens.
    /// Only one bounded own-account query can be active; no arbitrary archive sender is trusted.
    public func fetchArchivePage(_ bound: XMPPArchiveBound, limit: Int = 100, room: String? = nil) async throws -> XMPPArchivePage {
        guard phase == .online, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        guard archiveQuery == nil, (1...200).contains(limit), bound.cursor.map(validArchiveID) ?? true else { throw XMPPClientError.invalidConfiguration }
        // Later pages of a room reuse the validation its walk just did; sends never do (`refreshGroupRoom(_:)`).
        if let room { _ = try await refreshGroupRoom(room, reusingValidation: true) }
        guard phase == .online, OMEMOWire.bareJID(boundJID) == ownBare, archiveQuery == nil else { throw XMPPClientError.connectionClosed }
        let queryID = UUID().uuidString
        archiveQuery = ArchiveQuery(queryID: queryID, accountBareJID: ownBare, accountFullJID: boundJID, limit: limit)
        archiveQuery?.room = room
        archiveQuery?.knownRooms = Set(groupRooms.filter { !$0.value.members.isEmpty }.keys)
        defer { archiveQuery = nil }
        let payload = ArchiveQuery.payload(queryID: queryID, limit: limit, bound: bound)
        do {
            let response = try await requestIQ(type: "set", to: room ?? ownBare, payload: payload, timeout: Self.archiveQueryTimeout)
            guard let query = archiveQuery else { throw XMPPClientError.connectionClosed }
            return try query.finish(response)
        } catch {
            // A discarded partial page must not leave a permanent inbound acknowledgement gap.
            // Its unchanged durable cursor will refetch the page after reconnecting.
            if !(archiveQuery?.handledTokens.isEmpty ?? true) {
                finish("Archive synchronization interrupted", error: error)
                if error is CancellationError { throw error }
                // A room policy error after a partial page is no longer skippable:
                // abandoning its unhandled tokens has terminated the transport.
                throw XMPPClientError.connectionClosed
            }
            throw error
        }
    }

    /// False once the stream has ended. A query that failed with `timedOut` while this is still true hit its own
    /// deadline; after a lost connection (liveness probe) every pending query fails with that same error.
    public var isOnline: Bool { phase == .online }

    private static func smCount(_ value: String?) -> UInt32? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(value)
    }

    /// nil asks the server to assign a resource.
    private func startBinding(resource: String?) async throws {
        phase = .binding; bindID = UUID().uuidString
        try emit(.state(.binding))
        let requested = resource.map { "<resource>\(xmlEscaped($0))</resource>" } ?? ""
        try await write("<iq type='set' id='\(bindID)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\(requested)</bind></iq>")
    }

    private func becomeOnline(token: UUID, resumed: Bool = false) async throws {
        announced = resumed ? resumeSnapshot?.availability : nil
        try await announceAvailability(initial: !resumed)
        guard generation == token else { throw XMPPClientError.connectionClosed }
        sessionResumed = resumed
        phase = .online; deadline?.cancel(); deadline = nil
        liveness = Task { [weak self] in await self?.livenessLoop(token: token) }
        try emit(.state(.online(jid: boundJID)))
        handshake?.resume(); handshake = nil
    }

    /// A fresh session always sends initial presence. Otherwise presence goes out only when it differs from what the
    /// server holds: a resumed session keeps the presence an earlier process announced, and repeating it would reach
    /// every contact and push their hibernating sessions, whose extensions would answer in kind. CSI is a nonza that
    /// goes nowhere else, so it is always restated. Presence goes before CSI `<inactive/>`, which would otherwise let
    /// the server hold it back.
    private func announceAvailability(initial: Bool) async throws {
        let presence = initial || announced != availability
        switch availability {
        case .active:
            if !initial, csiOffered { try await write(PushNotifications.clientStateXML(active: true)) }
            if presence { try await write(Self.presenceXML(.active)) }
        case .away:
            if presence { try await write(Self.presenceXML(availability)) }
            if csiOffered { try await write(PushNotifications.clientStateXML(active: false)) }
        }
        announced = availability
        if presence { try await streamManagement?.recordAvailability(availability) }
    }

    static func presenceXML(_ availability: XMPPAvailability) -> String {
        guard case .away(let since?) = availability else { return "<presence>\(EntityCapabilities.presenceElement)</presence>" }
        let stamp = since.formatted(.iso8601)
        return "<presence>\(EntityCapabilities.presenceElement)<idle xmlns='\(PresenceWire.idleNamespace)' since='\(stamp)'/></presence>"
    }

    /// Persists the handled count and writes it as `<a/>` under the write gate, so two acknowledgements can never
    /// reach the server out of order. The advertised h is always the persisted value; a failed commit ends the stream.
    private func writeAcknowledgement(detaching: Bool = false) async throws {
        guard let streamManagement else { throw XMPPClientError.unexpectedProtocol }
        let token = generation
        await writeGate.enter()
        do {
            guard token == generation else { throw XMPPClientError.connectionClosed }
            let h = detaching ? try await streamManagement.detach() : try await streamManagement.flushHandled()
            try await rawWrite("<a xmlns='urn:xmpp:sm:3' h='\(h)'/>", expectedGeneration: token)
            await writeGate.leave()
        } catch { await writeGate.leave(); throw error }
    }

    /// Ends this connection if `work` has not finished within `farewellWriteLimit`; cancelling the socket also
    /// completes a write it was still holding.
    private func withFarewellDeadline(_ work: () async throws -> Void) async throws {
        let token = generation
        let watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.farewellWriteLimit)) != nil else { return }
            await self?.cancel(token)
        }
        defer { watchdog.cancel() }
        try await work()
    }

    /// The socket can die without an error (NAT timeout, network change). After a silent
    /// interval, ask the server for proof of life; any inbound bytes count as the answer.
    private func livenessLoop(token: UUID) async {
        while generation == token, phase == .online {
            let seen = inboundActivity
            guard (try? await Task.sleep(for: Self.silenceInterval)) != nil, generation == token, phase == .online else { return }
            if inboundActivity != seen { continue }
            do {
                if smOffered, streamManagement != nil { try await write("<r xmlns='urn:xmpp:sm:3'/>") }
                else { Task { [weak self] in _ = try? await self?.requestIQ(type: "get", to: nil, payload: "<ping xmlns='urn:xmpp:ping'/>") } }
            } catch { return }
            let atProbe = inboundActivity
            guard (try? await Task.sleep(for: Self.probeTimeout)) != nil, generation == token else { return }
            if inboundActivity == atProbe { finish("Connection lost", error: XMPPClientError.timedOut); return }
        }
    }

    func groupAccount() throws -> String {
        guard phase == .online, let account = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        return account
    }
    func groupWrite(_ xml: String, snapshot: XMPPGroupRoomSnapshot? = nil) async throws {
        _ = try groupAccount()
        try await write(xml, groupSnapshot: snapshot)
    }

    private func emitMessage(_ node: XMLNode, provenance: XMPPMessageProvenance) throws {
        if provenance == .direct, let account = OMEMOWire.bareJID(boundJID),
           let state = Self.parsedChatState(node, account: account, rooms: groupRooms) { try emit(.chatState(state)) }
        if node.attributes["type"] == "groupchat" {
            if provenance == .direct, let room = node.attributes["from"].flatMap(OMEMOWire.bareJID),
               let state = groupRooms[room], let account = OMEMOWire.bareJID(boundJID), OMEMOWire.hasEncryptedContent(node) {
                do { try emit(.encryptedGroupMessage(GroupChatWire.message(node, account: account, room: room, state: state))) }
                catch { try emit(.encryptionFailure(from: room, id: node.attributes["id"])) }
            }
            return
        }
        if OMEMOWire.hasEncryptedContent(node) {
            do {
                var message = try OMEMOWire.parseMessage(node, provenance: provenance)
                // XEP-0359: the id our own server gave this message when it archived it; XEP-0490 names messages by it.
                message.archiveStanzaID = OMEMOWire.bareJID(boundJID).flatMap { DisplayedSync.ownStanzaID(node, accountBareJID: $0) }
                try emit(.encryptedMessage(message))
            }
            catch { try emit(.encryptionFailure(from: node.attributes["from"] ?? "", id: node.attributes["id"])) }
        } else if provenance == .direct, let account = OMEMOWire.bareJID(boundJID), let items = DisplayedSync.event(node, accountBareJID: account) {
            if !items.isEmpty { try emit(.displayedSync(items)) }
        } else if provenance == .direct, let update = Self.deviceUpdate(node) {
            try emit(.omemoDevices(owner: update.owner, profile: update.profile, devices: update.devices))
        } else if let retraction = Self.parsedRetraction(node, provenance: provenance) {
            try emit(.retraction(retraction))
        } else if provenance == .direct, let update = Self.avatarUpdate(node) {
            try emit(.avatarMetadata(owner: update.owner, metadata: update.metadata))
        } else if let reaction = Self.parsedReaction(node, provenance: provenance) {
            try emit(.reaction(reaction))
        } else if let receipt = Self.parsedReceipt(node, provenance: provenance) {
            try emit(.receipt(receipt))
        } else if let message = Self.parsedMessage(node, provenance: provenance) {
            try emit(.message(message))
        }
    }

    /// Enable on each new session. Carbons synchronize live resources, not offline archives.
    public func setCarbonsEnabled(_ enabled: Bool = true) async throws {
        _ = try await requestIQ(type: "set", to: nil, payload: "<\(enabled ? "enable" : "disable") xmlns='urn:xmpp:carbons:2'/>")
    }

    /// `replaces` is the legacy-OMEMO correction reference, which has to travel outside the ciphertext.
    @discardableResult public func sendEncryptedMessage(to: String, envelope: XMPPOMEMOEnvelope, id: String, requestReceipt: Bool = false, markable: Bool = false, replaces: String? = nil) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.encryptedMessageXML(to: to, envelope: envelope, id: id, requestReceipt: requestReceipt, markable: markable, replaces: replaces))
        return id
    }

    public var supportsClientStateIndication: Bool { phase == .online && csiOffered }

    /// CSI is a hint, independent of presence. It is not a guarantee of suspended traffic or push.
    /// New and resumed streams default to active; the caller must indicate its current lifecycle state.
    public func setClientActive(_ active: Bool) async throws {
        guard phase == .online else { throw XMPPClientError.notConnected }
        guard csiOffered else { throw XMPPNotificationError.clientStateUnavailable }
        try await write(PushNotifications.clientStateXML(active: active))
    }

    public func supportsPushNotifications() async throws -> Bool {
        guard let ownBare = OMEMOWire.bareJID(boundJID), phase == .online else { throw XMPPClientError.notConnected }
        return try await discoveryFeatures(for: ownBare).contains(PushNotifications.namespace)
    }

    /// Confirms registration only after the authenticated account server returns an IQ result.
    /// Provisioning the gateway/APNs registration is a separate application operation.
    public func enablePush(_ configuration: XMPPPushConfiguration) async throws {
        guard let ownBare = OMEMOWire.bareJID(boundJID), phase == .online else { throw XMPPClientError.notConnected }
        let token = generation
        guard try await supportsPushNotifications() else { throw XMPPNotificationError.pushUnavailable }
        guard generation == token else { throw XMPPClientError.connectionClosed }
        _ = try await requestIQ(type: "set", to: ownBare, payload: PushNotifications.enableXML(configuration))
    }

    /// Node is mandatory here so disabling this installation cannot revoke another device's node.
    public func disablePush(serviceJID: String, node: String) async throws {
        let payload = try PushNotifications.disableXML(serviceJID: serviceJID, node: node)
        guard let ownBare = OMEMOWire.bareJID(boundJID), phase == .online else { throw XMPPClientError.notConnected }
        let token = generation
        guard try await supportsPushNotifications() else { throw XMPPNotificationError.pushUnavailable }
        guard generation == token else { throw XMPPClientError.connectionClosed }
        _ = try await requestIQ(type: "set", to: ownBare, payload: payload)
    }

    /// RFC 6121 §2.1.3. The result is also emitted as `.rosterItems(_, replacesAll: true)` in stream order,
    /// ahead of any push that follows it; consumers should track the roster from events, not this return value.
    /// Later pushes from the server are answered and emitted until the session ends.
    @discardableResult public func fetchRoster() async throws -> [XMPPRosterItem] {
        guard phase == .online, OMEMOWire.bareJID(boundJID) != nil else { throw XMPPClientError.notConnected }
        rosterRequested = true
        let id = UUID().uuidString
        rosterFetchIDs.insert(id)
        defer { rosterFetchIDs.remove(id) }
        let response = try await requestIQ(type: "get", to: nil, payload: "<query xmlns='\(PresenceWire.rosterNamespace)'/>", id: id)
        return try PresenceWire.rosterResult(response)
    }

    /// `<presence to='bare' type='…'/>`: ask for, grant, withdraw or refuse a presence subscription.
    public func sendSubscription(_ kind: XMPPSubscriptionRequest, to bare: String) async throws {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(PresenceWire.subscriptionXML(kind, to: bare))
    }

    /// XEP-0012 seconds since the contact's last session ended, as its server reports it.
    /// Only the queried bare address may answer. `forbidden` means we hold no subscription.
    public func lastActivity(of bare: String) async throws -> Int {
        guard phase == .online else { throw XMPPClientError.notConnected }
        guard OMEMOWire.bareJID(bare) == bare else { throw XMPPClientError.invalidConfiguration }
        let response = try await requestIQ(type: "get", to: bare, payload: "<query xmlns='\(PresenceWire.lastActivityNamespace)'/>")
        return try PresenceWire.lastActivitySeconds(response)
    }

    /// Decides the inline XEP-0012 answer to a query addressed to our full JID: `seconds='0'` when on,
    /// `service-unavailable` when off (the default).
    public func setSharesLastActivity(_ on: Bool) {
        sharesLastActivity = on
    }

    /// The raw disco#info query node: features plus any data forms (XEP-0128) the entity publishes.
    func discoveryInfo(for jid: String? = nil) async throws -> XMLNode {
        let response = try await requestIQ(type: "get", to: jid, payload: "<query xmlns='http://jabber.org/protocol/disco#info'/>")
        return try OMEMOWire.singleton(response, "query", "http://jabber.org/protocol/disco#info")
    }

    public func discoveryFeatures(for jid: String? = nil) async throws -> Set<String> {
        let query = try await discoveryInfo(for: jid)
        let features = query.children.filter { $0.name == "feature" && $0.namespace == query.namespace }
        guard features.count <= 1_024, features.allSatisfy({ $0.attributes["var"]?.isEmpty == false }) else { throw XMPPIQError.malformedResponse }
        return Set(features.compactMap { $0.attributes["var"] })
    }

    public func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        guard OMEMOWire.bareJID(jid) == jid else { throw XMPPClientError.invalidConfiguration }
        do {
            let response = try await requestIQ(type: "get", to: jid, payload: "<pubsub xmlns='\(OMEMOWire.pubsub)'><items node='\(profile.devicesNode)' max_items='1'/></pubsub>")
            return try Self.logged(response, "devices \(profile.rawValue) of \(jid)") { try Self.decodeDeviceList(response, profile: profile) }
        } catch XMPPIQError.stanza(condition: "item-not-found") { return [] }
    }

    /// A node that exists but holds no item is an empty list, the same as a missing node.
    static func decodeDeviceList(_ response: XMLNode, profile: XMPPOMEMOProfile) throws -> [UInt32] {
        let items = try pubsubItems(response, node: profile.devicesNode)
        if items.children.isEmpty { return [] }
        guard items.children.count == 1 else { throw XMPPIQError.malformedResponse }
        let item = try OMEMOWire.singleton(items, "item", OMEMOWire.pubsub)
        guard item.attributes["id"] == "current", item.children.count == 1 else { throw XMPPIQError.malformedResponse }
        return try OMEMOWire.parseDevices(item.children[0], profile: profile)
    }

    public func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        guard OMEMOWire.bareJID(jid) == jid, OMEMOWire.validID(deviceID) else { throw XMPPClientError.invalidConfiguration }
        let node = profile.bundlesNode(deviceID: deviceID)
        let selection = profile == .modern ? "<item id='\(deviceID)'/>" : ""
        let response = try await requestIQ(type: "get", to: jid, payload: "<pubsub xmlns='\(OMEMOWire.pubsub)'><items node='\(node)' max_items='1'>\(selection)</items></pubsub>")
        return try Self.logged(response, "bundle \(deviceID) of \(jid)") { try Self.decodeBundle(response, deviceID: deviceID, profile: profile) }
    }

    /// An existing bundle node with no item behaves like a missing one, so the caller can skip that device.
    static func decodeBundle(_ response: XMLNode, deviceID: UInt32, profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle {
        let node = profile.bundlesNode(deviceID: deviceID)
        let items = try pubsubItems(response, node: node)
        if items.children.isEmpty { throw XMPPIQError.stanza(condition: "item-not-found") }
        guard items.children.count == 1 else { throw XMPPIQError.malformedResponse }
        let item = try OMEMOWire.singleton(items, "item", OMEMOWire.pubsub)
        guard item.children.count == 1, profile == .legacy || item.attributes["id"] == String(deviceID) else { throw XMPPIQError.malformedResponse }
        return try OMEMOWire.parseBundle(item.children[0], deviceID: deviceID, profile: profile)
    }

    /// Records the element outline (names and attributes, never text) of a public PEP response that failed to decode.
    private static func logged<T>(_ response: XMLNode, _ what: String, _ decode: () throws -> T) throws -> T {
        do { return try decode() }
        catch XMPPIQError.malformedResponse {
            #if canImport(os)
            Logger(subsystem: "haus.xmpp.ios", category: "xmpp").error("Malformed \(what, privacy: .public): \(outline(response), privacy: .public)")
            #endif
            throw XMPPIQError.malformedResponse
        }
    }

    static func outline(_ node: XMLNode, depth: Int = 0) -> String {
        guard depth < 6 else { return "…" }
        let attributes = node.attributes.keys.sorted().map { "\($0)=\(node.attributes[$0]!.prefix(24))" }.joined(separator: " ")
        let children = node.children.prefix(12).map { outline($0, depth: depth + 1) }.joined(separator: ",")
        return "\(node.name)" + (attributes.isEmpty ? "" : "{\(attributes)}") + (node.children.isEmpty ? "" : "[\(children)]")
    }

    /// XEP-0490: every chat's displayed state from our own PEP node. A missing node is no state. `timeout` bounds the
    /// query for a caller with a budget (the notification extension).
    public func fetchDisplayedSync(timeout: Duration = XMPPClient.iqTimeout) async throws -> [XMPPDisplayedItem] {
        guard phase == .online, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        do {
            let response = try await requestIQ(type: "get", to: ownBare, payload: DisplayedSync.fetchXML, timeout: timeout)
            return try Self.loggedPrivately(response, "displayed sync") { try DisplayedSync.items(fromResult: response) }
        } catch XMPPIQError.stanza(condition: "item-not-found") { return [] }
    }

    /// For a private node (XEP-0490 item ids are contact and room JIDs): a decoding failure logs only element names and
    /// child counts, never an attribute value or text, so nothing identifying reaches the unified log.
    private static func loggedPrivately<T>(_ response: XMLNode, _ what: String, _ decode: () throws -> T) throws -> T {
        do { return try decode() }
        catch XMPPIQError.malformedResponse {
            #if canImport(os)
            Logger(subsystem: "haus.xmpp.ios", category: "xmpp").error("Malformed \(what, privacy: .public): \(shape(response), privacy: .public)")
            #endif
            throw XMPPIQError.malformedResponse
        }
    }

    /// Element names and child counts only, 4 levels deep and 4 children wide.
    static func shape(_ node: XMLNode, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        let children = node.children.prefix(4).map { shape($0, depth: depth + 1) }.joined(separator: ",")
        return node.name + (node.children.isEmpty ? "" : "#\(node.children.count)[\(children)]")
    }

    /// XEP-0490: publish one chat's displayed state with the node options the XEP requires. A node that exists with
    /// other options is reconfigured once, then the publish is repeated.
    public func publishDisplayedSync(_ item: XMPPDisplayedItem) async throws {
        guard phase == .online else { throw XMPPClientError.notConnected }
        let payload = try DisplayedSync.publishXML(item)
        do { _ = try await requestIQ(type: "set", to: nil, payload: payload) }
        catch XMPPIQError.stanza(condition: "conflict") {
            _ = try await requestIQ(type: "set", to: nil, payload: DisplayedSync.configureXML())
            _ = try await requestIQ(type: "set", to: nil, payload: payload)
        }
    }

    public func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws {
        try await publishPEP(node: profile.devicesNode, itemID: "current", item: OMEMOWire.devicesXML(devices, profile: profile), multipleItems: false)
    }

    public func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws {
        try await publishPEP(node: bundle.profile.bundlesNode(deviceID: bundle.deviceID),
                             itemID: bundle.profile == .modern ? String(bundle.deviceID) : "current",
                             item: OMEMOWire.bundleXML(bundle), multipleItems: bundle.profile == .modern)
    }

    private func publishPEP(node: String, itemID: String, item: String, multipleItems: Bool) async throws {
        let fields = "<field var='pubsub#access_model'><value>open</value></field>" + (multipleItems ? "<field var='pubsub#max_items'><value>max</value></field>" : "")
        let options = "<publish-options><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>\(fields)</x></publish-options>"
        let payload = "<pubsub xmlns='\(OMEMOWire.pubsub)'><publish node='\(node)'><item id='\(itemID)'>\(item)</item></publish>\(options)</pubsub>"
        do { _ = try await requestIQ(type: "set", to: nil, payload: payload) }
        catch XMPPIQError.stanza(condition: "conflict") {
            // Existing PEP nodes may have default access/max-items settings incompatible with OMEMO.
            let configure = "<pubsub xmlns='http://jabber.org/protocol/pubsub#owner'><configure node='\(node)'><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#node_config</value></field>\(fields)</x></configure></pubsub>"
            _ = try await requestIQ(type: "set", to: nil, payload: configure)
            _ = try await requestIQ(type: "set", to: nil, payload: payload)
        }
    }

    private static func pubsubItems(_ response: XMLNode, node: String) throws -> XMLNode {
        let pubsub = try OMEMOWire.singleton(response, "pubsub", OMEMOWire.pubsub)
        let items = try OMEMOWire.singleton(pubsub, "items", OMEMOWire.pubsub)
        guard items.attributes["node"] == node else { throw XMPPIQError.malformedResponse }
        return items
    }

    private static func deviceUpdate(_ message: XMLNode) -> (owner: String, profile: XMPPOMEMOProfile, devices: [UInt32])? {
        guard message.name == "message", message.namespace == "jabber:client", let owner = message.attributes["from"],
              OMEMOWire.bareJID(owner) == owner,
              let event = try? OMEMOWire.singleton(message, "event", OMEMOWire.eventNamespace),
              let items = try? OMEMOWire.singleton(event, "items", OMEMOWire.eventNamespace),
              let profile = XMPPOMEMOProfile.allCases.first(where: { $0.devicesNode == items.attributes["node"] }),
              items.children.count == 1, let item = try? OMEMOWire.singleton(items, "item", OMEMOWire.eventNamespace),
              item.attributes["id"] == "current", item.children.count == 1,
              let devices = try? OMEMOWire.parseDevices(item.children[0], profile: profile) else { return nil }
        return (owner, profile, devices)
    }

    /// XEP-0084 metadata; nil when the contact publishes no avatar. `item-not-found` and a server
    /// without PEP both throw so the caller can fall back to the vCard photo.
    public func fetchAvatarMetadata(for jid: String) async throws -> XMPPAvatarMetadata? {
        guard OMEMOWire.bareJID(jid) == jid else { throw XMPPClientError.invalidConfiguration }
        let response = try await requestIQ(type: "get", to: jid, payload: "<pubsub xmlns='\(OMEMOWire.pubsub)'><items node='\(AvatarWire.metadataNode)' max_items='1'/></pubsub>")
        return try Self.logged(response, "avatar metadata of \(jid)") { try Self.decodeAvatarMetadata(response) }
    }

    static func decodeAvatarMetadata(_ response: XMLNode) throws -> XMPPAvatarMetadata? {
        let items = try pubsubItems(response, node: AvatarWire.metadataNode)
        if items.children.isEmpty { return nil }
        guard items.children.count == 1 else { throw XMPPIQError.malformedResponse }
        let item = try OMEMOWire.singleton(items, "item", OMEMOWire.pubsub)
        guard item.children.count == 1 else { throw XMPPIQError.malformedResponse }
        return try AvatarWire.parseMetadata(item.children[0])
    }

    /// The bytes behind a metadata id, verified against it before they are returned.
    public func fetchAvatarData(for jid: String, id: String) async throws -> Data {
        guard OMEMOWire.bareJID(jid) == jid, AvatarWire.validHash(id) else { throw XMPPClientError.invalidConfiguration }
        let response = try await requestIQ(type: "get", to: jid, payload: "<pubsub xmlns='\(OMEMOWire.pubsub)'><items node='\(AvatarWire.dataNode)'><item id='\(id)'/></items></pubsub>")
        return try Self.logged(response, "avatar data of \(jid)") { try Self.decodeAvatarData(response, id: id) }
    }

    static func decodeAvatarData(_ response: XMLNode, id: String) throws -> Data {
        let items = try pubsubItems(response, node: AvatarWire.dataNode)
        guard items.children.count == 1 else { throw XMPPIQError.stanza(condition: "item-not-found") }
        let item = try OMEMOWire.singleton(items, "item", OMEMOWire.pubsub)
        guard item.attributes["id"]?.lowercased() == id.lowercased(), item.children.count == 1 else { throw XMPPIQError.malformedResponse }
        let data = try AvatarWire.parseData(item.children[0])
        guard AvatarWire.hash(data) == id.lowercased() else { throw XMPPIQError.malformedResponse }
        return data
    }

    /// XEP-0153 fallback for contacts without PEP: the vCard photo, keyed by its own SHA-1.
    public func fetchVCardPhoto(for jid: String) async throws -> (id: String, type: String, data: Data)? {
        guard OMEMOWire.bareJID(jid) == jid else { throw XMPPClientError.invalidConfiguration }
        let response = try await requestIQ(type: "get", to: jid, payload: "<vCard xmlns='\(AvatarWire.vcardNamespace)'/>")
        return try Self.logged(response, "vCard photo of \(jid)") {
            let vcard = try OMEMOWire.singleton(response, "vCard", AvatarWire.vcardNamespace)
            guard let photo = try AvatarWire.parseVCardPhoto(vcard) else { return nil }
            return (AvatarWire.hash(photo.data), photo.type, photo.data)
        }
    }

    static func avatarUpdate(_ message: XMLNode) -> (owner: String, metadata: XMPPAvatarMetadata?)? {
        guard message.name == "message", message.namespace == "jabber:client", let owner = message.attributes["from"],
              OMEMOWire.bareJID(owner) == owner,
              let event = try? OMEMOWire.singleton(message, "event", OMEMOWire.eventNamespace),
              let items = try? OMEMOWire.singleton(event, "items", OMEMOWire.eventNamespace),
              items.attributes["node"] == AvatarWire.metadataNode, items.children.count == 1,
              let item = try? OMEMOWire.singleton(items, "item", OMEMOWire.eventNamespace), item.children.count == 1 else { return nil }
        // An empty <metadata/> is a valid "avatar removed" event, so the optional result is kept as is.
        do { return (owner, try AvatarWire.parseMetadata(item.children[0])) } catch { return nil }
    }

    func requestIQ(type: String, to: String?, payload: String, id: String = UUID().uuidString, timeout: Duration = XMPPClient.iqTimeout) async throws -> XMLNode {
        guard phase == .online, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        guard iqRequests.count < 64 else { throw XMPPIQError.requestLimit }
        if let to {
            guard !to.isEmpty, to.utf8.count <= 3_071, !to.contains(where: { $0.isWhitespace }),
                  MessageContent.validXMLText(to) else { throw XMPPClientError.invalidConfiguration }
        }
        let token = generation
        let scope = IQReplyScope(recipient: to, accountBareJID: ownBare, accountFullJID: boundJID, serverDomain: domain)
        let replyDeadline = timeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: replyDeadline) } catch { return }
                    await self?.failIQ(id, error: XMPPClientError.timedOut)
                }
                iqRequests[id] = IQRequest(scope: scope, continuation: continuation, timeout: timeout)
                let destination = to.map { " to='\(xmlEscaped($0))'" } ?? ""
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.writeIQIfPending("<iq type='\(type)' id='\(id)'\(destination)>\(payload)</iq>", id: id, token: token) }
                    catch { await self.failIQ(id, error: error) }
                }
            }
        } onCancel: { Task { await self.failIQ(id, error: CancellationError()) } }
    }

    private func writeIQIfPending(_ xml: String, id: String, token: UUID) async throws {
        guard generation == token, iqRequests[id] != nil else { throw CancellationError() }
        try await write(xml)
    }

    private func routeIQ(_ node: XMLNode) -> Bool {
        guard let id = node.attributes["id"], let request = iqRequests[id], request.scope.accepts(node) else { return false }
        iqRequests.removeValue(forKey: id); rosterFetchIDs.remove(id)
        request.timeout.cancel()
        do { request.continuation.resume(returning: try IQReplyScope.result(node)) }
        catch { request.continuation.resume(throwing: error) }
        return true
    }

    private func failIQ(_ id: String, error: Error) {
        rosterFetchIDs.remove(id)
        guard let request = iqRequests.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func streamOpening() -> String { "<stream:stream to='\(xmlEscaped(domain))' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>" }
    private func emit(_ event: XMPPEvent) throws {
        emittedEvents &+= 1
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped: throw XMPPClientError.eventConsumerTooSlow
        // Online, a finished stream means the owner stopped consuming on its way to `disconnectAndWait`, possibly
        // before it: the connection stays for the farewell. A message's barrier then never counts it as handled.
        case .terminated: if phase != .online { throw XMPPClientError.eventConsumerTooSlow }
        @unknown default: throw XMPPClientError.eventConsumerTooSlow
        }
    }
    private func cancel(_ token: UUID) { if generation == token { finish(nil) } }
    private func timeout(_ token: UUID) { if generation == token && phase != .online { finish("Connection timed out", error: XMPPClientError.timedOut) } }
    private func finish(_ reason: String?, error: Error = XMPPClientError.connectionClosed) {
        generation = UUID()
        groupRooms.removeAll(); rosterFetchIDs.removeAll(); rosterRequested = false
        // Their reads are failed below; a stale refresh must never be joined by the next connection.
        for refresh in roomRefreshes.values { refresh.task.cancel() }
        roomRefreshes.removeAll()
        let pending = iqRequests; iqRequests.removeAll()
        for request in pending.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }
        boundJID = ""
        handshake?.resume(throwing: error); handshake = nil
        connection?.cancel(); connection = nil
        // Keep the task handle until the next connection so a later lifecycle join still
        // sees work cancelled by an earlier error/disconnect (including an archive abort).
        reader?.cancel()
        deadline?.cancel(); deadline = nil
        liveness?.cancel(); liveness = nil
        password = ""; sasl = nil; phase = .idle; csiOffered = false; bindRetried = false
        if case .dropped = continuation.yield(.state(.disconnected(reason))) { continuation.finish() }
    }
    private func write(_ xml: String, groupSnapshot: XMPPGroupRoomSnapshot? = nil) async throws {
        let token = generation
        await writeGate.enter()
        do {
            guard token == generation else { throw XMPPClientError.connectionClosed }
            try validateGroupWrite(groupSnapshot)
            if xml.hasPrefix("<message") || xml.hasPrefix("<iq") || xml.hasPrefix("<presence") {
                try await streamManagement?.record(xml)
            }
            guard generation == token else { throw XMPPClientError.connectionClosed }
            try validateGroupWrite(groupSnapshot)
            try await rawWrite(xml, expectedGeneration: token)
            await writeGate.leave()
        } catch { await writeGate.leave(); throw error }
    }

    private func rawWrite(_ xml: String, expectedGeneration: UUID) async throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw XMPPClientError.connectionClosed }
        guard let connection else { throw XMPPClientError.notConnected }
        let token = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(xml.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        // A cancelled/replaced connection must not report a successful send to the outbox.
        guard generation == token else { throw XMPPClientError.connectionClosed }
        try Task.checkCancellation()
    }
    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? XMPPClientError.connectionClosed) }
            }
        }
    }
    private static func start(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = ConnectionStart(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.finish(nil)
                case .failed(let error): result.finish(error)
                // Waiting is recoverable (for example the first local-network permission
                // prompt). Keep the attempt alive until ready, cancellation or our deadline.
                // A refused port, a failed TLS handshake or a missing name will not recover: move to the next candidate.
                case .waiting(let error): if definitive(error) { result.finish(error) }
                case .cancelled: result.finish(XMPPClientError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private static func definitive(_ error: NWError) -> Bool {
        switch error {
        case .posix(.ECONNREFUSED), .tls: true
        case .dns(let code): code == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) || code == DNSServiceErrorType(kDNSServiceErr_NoSuchName)
        default: error == XMPPTransport.startTLSRefused || error == .posix(.EBADMSG)
        }
    }
    private static func transportError(_ error: Error) -> Error {
        (error as? NWError) == XMPPTransport.startTLSRefused ? XMPPClientError.encryptionUnavailable : error
    }
    private static func safeDescription(_ error: Error, otherwise: String = "Connection ended") -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "Authentication failed"
        case XMPPClientError.authenticationUnavailable: "Server offers no supported authentication mechanism"
        case XMPPClientError.authenticationRetryable: "Server could not authenticate now"
        case XMPPClientError.authenticationDowngrade: "Server no longer offers SCRAM"
        case XMPPClientError.encryptionUnavailable: "Server did not offer TLS"
        case XMPPClientError.serviceNotOffered: "Domain offers no XMPP client service"
        case XMPPClientError.bindingFailed: "Resource binding failed"
        case XMPPClientError.eventConsumerTooSlow: "Event consumer could not keep up"
        case is XMLStreamError: "Invalid or oversized server XML"
        default: otherwise
        }
    }
}

/// A candidate endpoint failed before the connect committed to it; the next one is tried.
private struct CandidateFailure: Error { let error: Error }

/// NWConnection callbacks are serialized on their queue; the lock also protects cancellation delivery.
private final class ConnectionStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let result = continuation; continuation = nil; lock.unlock()
        if let error { result?.resume(throwing: error) } else { result?.resume() }
    }
}
