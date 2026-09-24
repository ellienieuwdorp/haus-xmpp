import Foundation
#if canImport(os)
import os
#endif
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
    /// Consume previous events durably before acknowledging this token.
    case streamManagementBarrier(XMPPInboundToken)
    case streamAcknowledged
}

public enum XMPPClientError: Error, Sendable {
    case invalidConfiguration, alreadyConnected, notConnected, authenticationUnavailable
    case authenticationFailed, bindingFailed, unexpectedProtocol, connectionClosed, timedOut, eventConsumerTooSlow
}

/// Direct-TLS transport with OMEMO PEP, durable stream management and bounded archive recovery.
/// DNS SRV, STARTTLS and modern SASL mechanisms are still separate work.
/// PLAIN is permitted only inside validated TLS. Never use this API as an encryption fallback.
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
    private var generation = UUID()
    private var phase: Phase = .idle
    private var framer = XMLStreamFramer()
    private(set) var domain = ""
    private var username = ""
    private var password = ""
    private var bindID = ""
    private var boundJID = ""
    private struct IQRequest {
        let scope: IQReplyScope
        let continuation: CheckedContinuation<XMLNode, Error>
        let timeout: Task<Void, Never>
    }
    private var iqRequests: [String: IQRequest] = [:]
    private var archiveQuery: ArchiveQuery?
    var groupRooms: [String: GroupRoomState] = [:]
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
        let pair = AsyncStream<XMPPEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream
        continuation = pair.continuation
    }

    public func connect(host: String, port: UInt16 = 5223, domain: String, username: String, password: String) async throws {
        guard connection == nil, phase == .idle else { throw XMPPClientError.alreadyConnected }
        guard !host.isEmpty, !domain.isEmpty, !username.isEmpty, !password.isEmpty,
              !username.contains("\0"), !password.contains("\0"), !domain.contains(where: { $0.isWhitespace }),
              let endpointPort = NWEndpoint.Port(rawValue: port) else { throw XMPPClientError.invalidConfiguration }
        groupRooms.removeAll()
        self.domain = domain; self.username = username; self.password = password
        phase = .features; generation = UUID()
        let token = generation
        do { resumeSnapshot = try await streamManagement?.restore(accountID: username + "@" + domain) }
        catch { if generation == token { phase = .idle; self.password = "" }; throw error }
        guard generation == token else { throw XMPPClientError.connectionClosed }
        framer = XMLStreamFramer()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, domain)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let certificateData = labCertificateAuthority
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            // XMPP service identity is the account domain, not an SRV/IP transport endpoint.
            guard SecTrustSetPolicies(trustRef, SecPolicyCreateSSL(true, domain as CFString)) == errSecSuccess else { complete(false); return }
            if let certificateData {
                guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
                      SecTrustSetAnchorCertificates(trustRef, [certificate] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trustRef, true) == errSecSuccess else { complete(false); return }
            }
            complete(SecTrustEvaluateWithError(trustRef, nil))
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 30; tcp.keepaliveInterval = 10; tcp.keepaliveCount = 3
        let conn = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: tls, tcp: tcp))
        connection = conn
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await self?.timeout(token)
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try emit(.state(.connecting))
                try await Self.start(conn, queue: queue)
                guard generation == token, connection != nil else { throw XMPPClientError.connectionClosed }
                try await write(streamOpening())
                guard generation == token, connection != nil else { throw XMPPClientError.connectionClosed }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    handshake = continuation
                    reader = Task { [weak self] in await self?.readLoop(conn, token: token) }
                }
            } onCancel: {
                Task { await self.cancel(token) }
            }
        } catch {
            if generation == token { finish("TLS connection failed") }
            throw error
        }
    }

    public func disconnect() {
        finish(nil)
    }

    /// External lifecycle boundary: cancel the connection and join its current reader before
    /// releasing a shared database lease. Never call this from the reader/event parser itself.
    /// Application event consumers and senders must also be cancelled and joined by their owner.
    public func disconnectAndWait() async {
        let previousReader = reader
        finish(nil)
        await previousReader?.value
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

    /// Pure preflight for durable enqueueing; does not require a connected session.
    public static func validateMessage(to: String, body: String, id: String, reply: XMPPReply? = nil) throws {
        guard MessageContent.validAddress(to), !body.isEmpty, body.utf8.count <= 65_536,
              MessageContent.validIdentifier(id), MessageContent.validXMLText(body) else { throw XMPPClientError.invalidConfiguration }
        if let reply {
            guard reply.id.map(MessageContent.validIdentifier) ?? true, MessageContent.validAddress(reply.to),
                  !reply.body.isEmpty, reply.body.utf8.count <= 16_384, MessageContent.validXMLText(reply.body),
                  replyFallback(reply.body).utf8.count + body.utf8.count <= 65_536 else { throw XMPPClientError.invalidConfiguration }
        }
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

    private func readLoop(_ conn: NWConnection, token: UUID) async {
        do {
            while generation == token && !Task.isCancelled {
                let data = try await Self.receive(conn)
                guard generation == token else { return }
                inboundActivity &+= 1
                for frame in try framer.feed(data) {
                    guard generation == token else { return }
                    switch frame {
                    case .opened: break
                    case .closed: throw XMPPClientError.connectionClosed
                    case .element(let node): try await handle(node, token: token)
                    }
                }
            }
        } catch {
            if generation == token { finish(Self.safeDescription(error), error: error) }
        }
    }

    private func handle(_ node: XMLNode, token: UUID) async throws {
        if node.name == "error", node.namespace == "http://etherx.jabber.org/streams" { throw XMPPClientError.unexpectedProtocol }
        switch phase {
        case .features:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw XMPPClientError.unexpectedProtocol }
            let mechanisms = node.child("mechanisms", namespace: "urn:ietf:params:xml:ns:xmpp-sasl")
            guard mechanisms?.children.contains(where: { $0.name == "mechanism" && $0.namespace == "urn:ietf:params:xml:ns:xmpp-sasl" && $0.text == "PLAIN" }) == true else { throw XMPPClientError.authenticationUnavailable }
            phase = .authentication
            try emit(.state(.authenticating))
            let payload = Data(("\0" + username + "\0" + password).utf8).base64EncodedString()
            password = ""
            try await write("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>\(payload)</auth>")
        case .authentication:
            guard node.namespace == "urn:ietf:params:xml:ns:xmpp-sasl", node.name == "success" else { throw XMPPClientError.authenticationFailed }
            phase = .authenticatedFeatures
            framer = XMLStreamFramer()
            try await write(streamOpening())
        case .authenticatedFeatures:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams",
                  node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil else { throw XMPPClientError.bindingFailed }
            smOffered = node.child("sm", namespace: "urn:xmpp:sm:3") != nil
            csiOffered = node.child("csi", namespace: PushNotifications.clientStateNamespace) != nil
            if smOffered, let snapshot = resumeSnapshot, let id = snapshot.streamID {
                phase = .resumingSM
                try await write("<resume xmlns='urn:xmpp:sm:3' previd='\(xmlEscaped(id))' h='\(UInt32(truncatingIfNeeded: snapshot.inboundHandled))'/>")
            } else { try await startBinding() }
        case .binding:
            guard node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
                  node.attributes["type"] == "result",
                  let jid = node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.child("jid", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.text, !jid.isEmpty else { throw XMPPClientError.bindingFailed }
            boundJID = jid
            if smOffered, streamManagement != nil {
                phase = .enablingSM
                try await write("<enable xmlns='urn:xmpp:sm:3' resume='true' max='300'/>")
            } else { try await becomeOnline(token: token) }
        case .enablingSM:
            guard node.namespace == "urn:xmpp:sm:3", node.name == "enabled" else { throw XMPPClientError.unexpectedProtocol }
            let resumable = ["true", "1"].contains(node.attributes["resume"] ?? "false")
            let id = node.attributes["id"]
            guard !resumable || id.map(validArchiveID) == true else { throw XMPPClientError.unexpectedProtocol }
            let maxSeconds = node.attributes["max"].flatMap(UInt32.init) ?? 300
            try await streamManagement?.enable(accountID: username + "@" + domain, fullJID: boundJID,
                                               streamID: resumable ? id : nil, expiresAt: Date().addingTimeInterval(Double(min(maxSeconds, 300))),
                                               resumeTimeoutSeconds: min(maxSeconds, 300))
            try await becomeOnline(token: token)
        case .resumingSM:
            guard node.namespace == "urn:xmpp:sm:3" else { throw XMPPClientError.unexpectedProtocol }
            if node.name == "failed" {
                // A failed resume never triggers blind retransmission; MAM reconciles uncertain sends.
                resumeSnapshot = nil
                try await startBinding()
            } else {
                guard node.name == "resumed", let snapshot = resumeSnapshot,
                      node.attributes["previd"] == snapshot.streamID,
                      let h = Self.smCount(node.attributes["h"]), let streamManagement else { throw XMPPClientError.unexpectedProtocol }
                boundJID = snapshot.fullJID
                let replay = try await streamManagement.acknowledge(h, resumed: true)
                try emit(.streamAcknowledged)
                guard try await streamManagement.permitsReplay() else { throw XMPPStreamManagementError.invalidState }
                for entry in replay { try await rawWrite(entry.xml, expectedGeneration: token) }
                try await becomeOnline(token: token, presence: false)
            }
        case .online:
            if node.namespace == "urn:xmpp:sm:3" {
                guard let streamManagement else { throw XMPPClientError.unexpectedProtocol }
                if node.name == "r" {
                    let h = await streamManagement.handledCount()
                    try await write("<a xmlns='urn:xmpp:sm:3' h='\(h)'/>")
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
            if routeIQ(node) {
                if let inbound { try await streamManagement?.handled(inbound) }
                return
            }
            if node.name == "presence", node.namespace == "jabber:client",
               let occupant = node.attributes["from"], let room = OMEMOWire.bareJID(occupant), var state = groupRooms[room] {
                guard let account = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
                GroupChatWire.applyPresence(node, room: room, account: account, state: &state)
                groupRooms[room] = state
                try emit(.groupPresence(room: room))
            }
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
                let to = node.attributes["from"].map { " to='\(xmlEscaped($0))'" } ?? ""
                // Respond to XEP-0199 pings; reject other unsupported requests explicitly.
                if node.attributes["type"] == "get", node.children.count == 1,
                   let query = node.child("query", namespace: "http://jabber.org/protocol/disco#info") {
                    try await write("<iq type='result' id='\(xmlEscaped(id))'\(to)>\(EntityCapabilities.discoInfoQuery(node: query.attributes["node"]))</iq>")
                } else if node.child("ping", namespace: "urn:xmpp:ping") != nil {
                    try await write("<iq type='result' id='\(xmlEscaped(id))'\(to)/>")
                } else {
                    try await write("<iq type='error' id='\(xmlEscaped(id))'\(to)><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
                }
            }
            if let inbound {
                if node.name == "message" { try emit(.streamManagementBarrier(inbound)) }
                else { try await streamManagement?.handled(inbound) }
            }
        case .idle: throw XMPPClientError.unexpectedProtocol
        }
    }

    public func configureStreamManagement(persistence: any XMPPStreamManagementPersistence) throws {
        guard connection == nil, phase == .idle else { throw XMPPClientError.alreadyConnected }
        streamManagement = StreamManagement(persistence)
    }

    public func acknowledgeInbound(_ token: XMPPInboundToken) async throws {
        try await streamManagement?.handled(token)
    }

    public func requestAcknowledgement() async throws {
        guard phase == .online, streamManagement != nil, smOffered else { throw XMPPClientError.notConnected }
        try await write("<r xmlns='urn:xmpp:sm:3'/>")
    }

    /// Caller must persist every result and its archive position before acknowledging handledTokens.
    /// Only one bounded own-account query can be active; no arbitrary archive sender is trusted.
    public func fetchArchivePage(after: String? = nil, limit: Int = 100, room: String? = nil) async throws -> XMPPArchivePage {
        guard phase == .online, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        guard archiveQuery == nil, (1...200).contains(limit), after.map(validArchiveID) ?? true else { throw XMPPClientError.invalidConfiguration }
        if let room { _ = try await refreshGroupRoom(room) }
        guard phase == .online, OMEMOWire.bareJID(boundJID) == ownBare, archiveQuery == nil else { throw XMPPClientError.connectionClosed }
        let queryID = UUID().uuidString
        archiveQuery = ArchiveQuery(queryID: queryID, accountBareJID: ownBare, accountFullJID: boundJID, limit: limit)
        archiveQuery?.room = room
        archiveQuery?.knownRooms = Set(groupRooms.filter { !$0.value.members.isEmpty }.keys)
        defer { archiveQuery = nil }
        let afterXML = after.map { "<after>\(xmlEscaped($0))</after>" } ?? ""
        let payload = "<query xmlns='urn:xmpp:mam:2' queryid='\(queryID)'><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>urn:xmpp:mam:2</value></field></x><set xmlns='http://jabber.org/protocol/rsm'><max>\(limit)</max>\(afterXML)</set></query>"
        do {
            let response = try await requestIQ(type: "set", to: room ?? ownBare, payload: payload)
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

    private static func smCount(_ value: String?) -> UInt32? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(value)
    }

    private func startBinding() async throws {
        phase = .binding; bindID = UUID().uuidString
        try emit(.state(.binding))
        try await write("<iq type='set' id='\(bindID)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>ios-lab-\(UUID().uuidString.prefix(8))</resource></bind></iq>")
    }

    private func becomeOnline(token: UUID, presence: Bool = true) async throws {
        if presence { try await write("<presence>\(EntityCapabilities.presenceElement)</presence>") }
        guard generation == token else { throw XMPPClientError.connectionClosed }
        phase = .online; deadline?.cancel(); deadline = nil
        liveness = Task { [weak self] in await self?.livenessLoop(token: token) }
        try emit(.state(.online(jid: boundJID)))
        handshake?.resume(); handshake = nil
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
            do { try emit(.encryptedMessage(OMEMOWire.parseMessage(node, provenance: provenance))) }
            catch { try emit(.encryptionFailure(from: node.attributes["from"] ?? "", id: node.attributes["id"])) }
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

    func requestIQ(type: String, to: String?, payload: String) async throws -> XMLNode {
        guard phase == .online, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        guard iqRequests.count < 64 else { throw XMPPIQError.requestLimit }
        if let to {
            guard !to.isEmpty, to.utf8.count <= 3_071, !to.contains(where: { $0.isWhitespace }),
                  MessageContent.validXMLText(to) else { throw XMPPClientError.invalidConfiguration }
        }
        let id = UUID().uuidString
        let token = generation
        let scope = IQReplyScope(recipient: to, accountBareJID: ownBare, accountFullJID: boundJID, serverDomain: domain)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
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
        iqRequests.removeValue(forKey: id)
        request.timeout.cancel()
        do { request.continuation.resume(returning: try IQReplyScope.result(node)) }
        catch { request.continuation.resume(throwing: error) }
        return true
    }

    private func failIQ(_ id: String, error: Error) {
        guard let request = iqRequests.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func streamOpening() -> String { "<stream:stream to='\(xmlEscaped(domain))' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>" }
    private func emit(_ event: XMPPEvent) throws {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: throw XMPPClientError.eventConsumerTooSlow
        @unknown default: throw XMPPClientError.eventConsumerTooSlow
        }
    }
    private func cancel(_ token: UUID) { if generation == token { finish(nil) } }
    private func timeout(_ token: UUID) { if generation == token && phase != .online { finish("Connection timed out", error: XMPPClientError.timedOut) } }
    private func finish(_ reason: String?, error: Error = XMPPClientError.connectionClosed) {
        generation = UUID()
        groupRooms.removeAll()
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
        password = ""; phase = .idle; csiOffered = false
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
                case .waiting: break
                case .cancelled: result.finish(XMPPClientError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private static func safeDescription(_ error: Error) -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "Authentication failed"
        case XMPPClientError.authenticationUnavailable: "Server does not offer the laboratory authentication mechanism"
        case XMPPClientError.bindingFailed: "Resource binding failed"
        case XMPPClientError.eventConsumerTooSlow: "Event consumer could not keep up"
        case is XMLStreamError: "Invalid or oversized server XML"
        default: "Connection ended"
        }
    }
}

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
