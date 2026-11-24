import Foundation
import Network

/// One end of a datagram path to a single peer: a UDP flow or the in-process loopback.
/// Unreliable and unordered; `NetChannel` adds the rest.
protocol DatagramLink: AnyObject {
    func send(_ packet: Data)
    func close()
}

/// Two in-memory ends that hand packets to the other side's queue, like Quake's loopback:
/// the host's own client is encoded and decoded exactly like a guest's, it just never
/// leaves the process.
final class LoopbackLink: DatagramLink, @unchecked Sendable {
    private weak var other: LoopbackLink?
    private let queue: DispatchQueue
    /// Set once before traffic starts, cleared on `queue` by `close()`.
    private var receive: ((Data) -> Void)?

    private init(queue: DispatchQueue) { self.queue = queue }

    /// `a` delivers what it receives on `aQueue`, `b` on `bQueue`. Each end must be kept
    /// alive by its owner; the ends only hold each other weakly.
    static func pair(_ aQueue: DispatchQueue, _ bQueue: DispatchQueue) -> (a: LoopbackLink, b: LoopbackLink) {
        let a = LoopbackLink(queue: aQueue), b = LoopbackLink(queue: bQueue)
        a.other = b
        b.other = a
        return (a, b)
    }

    func onReceive(_ handler: @escaping (Data) -> Void) { receive = handler }

    func send(_ packet: Data) {
        guard let other else { return }
        other.queue.async { other.receive?(packet) }
    }

    func close() { queue.async { self.receive = nil } }
}

/// A Network.framework UDP flow: a guest's connection to the host, or one the host's
/// listener created for a guest.
final class UDPLink: DatagramLink, @unchecked Sendable {
    let connection: NWConnection
    private var queue: DispatchQueue?

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue, receive: @escaping (Data) -> Void, failed: ((String) -> Void)? = nil) {
        self.queue = queue
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { failed?(error.debugDescription) }
        }
        connection.start(queue: queue)
        Self.receive(on: connection, queue: queue, receive)
    }

    func send(_ packet: Data) {
        connection.send(content: packet, completion: .idempotent)
    }

    /// Cancels a moment later so a parting disconnect message still goes out.
    func close() {
        let connection = connection
        (queue ?? .global()).asyncAfter(deadline: .now() + 0.25) { connection.cancel() }
    }

    private static func receive(on connection: NWConnection, queue: DispatchQueue, _ handler: @escaping (Data) -> Void) {
        connection.receiveMessage { [weak connection] data, _, _, error in
            if let data, !data.isEmpty { handler(data) }
            guard let connection else { return }
            switch connection.state {
            case .cancelled, .failed: return
            default: break
            }
            // An ICMP "port unreachable" surfaces here while the host is still starting:
            // back off rather than spin, and keep listening.
            if error != nil {
                queue.asyncAfter(deadline: .now() + 0.1) { receive(on: connection, queue: queue, handler) }
            } else {
                receive(on: connection, queue: queue, handler)
            }
        }
    }
}
