import Foundation
import Network
import os

// A loopback relay in front of the lab server: each chunk leaves one delay after it came, in order. A flight is a run
// of chunks one way; the other side's chunk starts the next only if late enough to answer the flight's first chunk, so
// a crossing push joins it. A round trip is a client flight answered by a server flight.
final class SyncBenchProxy: Sendable {
    struct Counts: Sendable, Equatable, Codable {
        var clientFlights = 0, serverFlights = 0, roundTrips = 0, clientBytes = 0, serverBytes = 0

        static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(clientFlights: lhs.clientFlights - rhs.clientFlights, serverFlights: lhs.serverFlights - rhs.serverFlights,
                   roundTrips: lhs.roundTrips - rhs.roundTrips, clientBytes: lhs.clientBytes - rhs.clientBytes,
                   serverBytes: lhs.serverBytes - rhs.serverBytes)
        }
    }

    private enum Direction { case fromClient, fromServer }

    private struct Tally {
        var counts = Counts()
        var last: Direction?
        var flightStarted: ContinuousClock.Instant?
        // When each round trip completed and each connection came, for points known only by their time.
        var roundTripTimes: [ContinuousClock.Instant] = []
        var connectionTimes: [ContinuousClock.Instant] = []
    }

    private let tally = OSAllocatedUnfairLock(initialState: Tally())
    private let listener: NWListener
    private let target: NWEndpoint.Port
    private let delay: DispatchTimeInterval
    // The earliest an answer to a chunk can reach the relay, with a margin for scheduling.
    private let answerAfter: Duration
    let port: UInt16

    private init(listener: NWListener, port: UInt16, target: NWEndpoint.Port, oneWayMilliseconds: Int) {
        self.listener = listener; self.port = port; self.target = target
        delay = .milliseconds(oneWayMilliseconds)
        answerAfter = .milliseconds(oneWayMilliseconds) * 0.9
    }

    static func start(oneWayMilliseconds: Int, target: UInt16) async throws -> SyncBenchProxy {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "syncbench.listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, any Error>? = switch state {
                case .ready: listener.port.map { .success($0.rawValue) } ?? .failure(NWError.posix(.EADDRNOTAVAIL))
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let value, resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                continuation.resume(with: value)
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        guard let targetPort = NWEndpoint.Port(rawValue: target) else { throw NWError.posix(.EINVAL) }
        let proxy = SyncBenchProxy(listener: listener, port: port, target: targetPort, oneWayMilliseconds: oneWayMilliseconds)
        listener.newConnectionHandler = { [proxy] inbound in proxy.relay(inbound) }
        return proxy
    }

    var counts: Counts { tally.withLock { $0.counts } }

    func firstConnection(after instant: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        tally.withLock { state in state.connectionTimes.first { $0 >= instant } }
    }

    // Counted from the relay's start.
    func roundTrips(through instant: ContinuousClock.Instant) -> Int {
        tally.withLock { state in state.roundTripTimes.reduce(0) { $0 + ($1 <= instant ? 1 : 0) } }
    }

    func stop() { listener.cancel() }

    private func relay(_ inbound: NWConnection) {
        let now = SyncBenchClock.now()
        tally.withLock { $0.connectionTimes.append(now) }
        let outbound = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
        let queue = DispatchQueue(label: "syncbench.connection")
        let toServer = DispatchQueue(label: "syncbench.to-server"), toClient = DispatchQueue(label: "syncbench.to-client")
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound, direction: .fromClient, on: toServer)
        pump(from: outbound, to: inbound, direction: .fromServer, on: toClient)
    }

    // Chunks of one direction share a serial queue and are due in arrival order, so they leave in order.
    private func pump(from source: NWConnection, to sink: NWConnection, direction: Direction, on queue: DispatchQueue) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                record(direction, bytes: data.count)
                // swiftlint:disable:next no_wall_clock_in_tests - the relay delays real traffic by real time
                queue.asyncAfter(deadline: .now() + delay) { sink.send(content: data, completion: .contentProcessed { _ in }) }
            }
            guard !isComplete, error == nil else {
                // swiftlint:disable:next no_wall_clock_in_tests - the relay delays real traffic by real time
                queue.asyncAfter(deadline: .now() + delay) { sink.cancel(); source.cancel() }
                return
            }
            pump(from: source, to: sink, direction: direction, on: queue)
        }
    }

    private func record(_ direction: Direction, bytes: Int) {
        let now = SyncBenchClock.now()
        tally.withLock { state in
            let answers = state.flightStarted.map { now - $0 >= answerAfter } ?? true
            if state.last != direction, answers {
                switch direction {
                case .fromClient: state.counts.clientFlights += 1
                case .fromServer:
                    state.counts.serverFlights += 1
                    if state.last == .fromClient {
                        state.counts.roundTrips += 1
                        state.roundTripTimes.append(now)
                    }
                }
                state.last = direction
                state.flightStarted = now
            }
            switch direction {
            case .fromClient: state.counts.clientBytes += bytes
            case .fromServer: state.counts.serverBytes += bytes
            }
        }
    }
}
