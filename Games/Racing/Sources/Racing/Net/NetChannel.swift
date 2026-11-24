import DatagramCore
import Foundation
import QuartzCore

/// Sequenced packets over an unreliable link, after Quake 2's netchan: every packet carries
/// its sequence and the last sequence received, and one block of reliable messages rides
/// along until the other side acknowledges it. Unreliable data (snapshots, car states) is
/// sent once and simply superseded. Stale and duplicate packets are dropped, so payloads
/// arrive in order with gaps.
///
/// Header: u32 sequence | reliable bit, u32 acknowledged sequence | reliable-ack bit.
/// Payload: the reliable block (when this packet carries it), then unreliable messages,
/// all framed by `MsgWriter.message`. Not thread-safe: owned by one queue.
final class NetChannel {
    /// Kept under typical MTUs so no fragmentation is ever needed.
    static let maxDatagram = 1200
    /// Room left for a full snapshot (8 cars) next to the reliable block.
    static let maxReliable = 800

    let link: DatagramLink
    private(set) var outgoingSequence: UInt32 = 1
    private(set) var incomingSequence: UInt32 = 0
    private(set) var incomingAcknowledged: UInt32 = 0
    private(set) var droppedPackets = 0
    private(set) var bytesSent = 0
    private(set) var lastReceived = CACurrentMediaTime()

    private var reliableSequence = false            // toggles for each new reliable block
    private var lastReliableSequence: UInt32 = 0    // outgoing sequence after the block was last sent
    private var incomingReliableAcknowledged = false
    private var incomingReliableSequence = false
    private var reliable = Data()                   // in flight
    private var pending: [Data] = []                // queued behind it

    init(link: DatagramLink) { self.link = link }

    var hasPendingReliable: Bool { !reliable.isEmpty || !pending.isEmpty }
    /// Seconds since the other side was last heard from.
    var idle: Double { CACurrentMediaTime() - lastReceived }

    /// `message` must be one or more whole framed messages, each under `maxReliable`.
    func queueReliable(_ message: Data) {
        guard !message.isEmpty else { return }
        assert(message.count <= Self.maxReliable, "reliable message too large")
        pending.append(message)
    }

    func transmit(_ unreliable: Data = Data()) {
        // Resend the block if the other side acknowledged a packet sent after it without
        // flipping its reliable bit: the block was lost.
        var sendReliable = incomingAcknowledged > lastReliableSequence && incomingReliableAcknowledged != reliableSequence
        if reliable.isEmpty, !pending.isEmpty {
            while let next = pending.first, reliable.isEmpty || reliable.count + next.count <= Self.maxReliable {
                reliable.append(next)
                pending.removeFirst()
            }
            reliableSequence.toggle()
            sendReliable = true
        }

        let sequence = outgoingSequence
        outgoingSequence &+= 1
        var w = MsgWriter()
        w.u32(DatagramSequenceWord(sequence, sendReliable, false))
        w.u32(DatagramSequenceWord(incomingSequence, incomingReliableSequence, false))
        if sendReliable {
            w.bytes(reliable)
            lastReliableSequence = outgoingSequence
        }
        // Unreliable data is the first thing to give way: the next tick supersedes it.
        if w.count + unreliable.count <= Self.maxDatagram { w.bytes(unreliable) }
        assert(w.count <= Self.maxDatagram)
        bytesSent += w.count
        link.send(w.data)
    }

    /// The payload, or nil for a stale, duplicate or malformed packet.
    func process(_ packet: Data) -> Data? {
        var r = MsgReader(packet)
        let w1 = r.u32(), w2 = r.u32()
        guard !r.overflow, w1 != DatagramOutOfBandMarker() else { return nil }
        let header = DatagramDecodeHeader(w1, w2)
        let sequence = header.sequence
        guard sequence > incomingSequence else { return nil }

        droppedPackets += Int(sequence - incomingSequence - 1)
        if header.reliableAcknowledged == reliableSequence { reliable.removeAll(keepingCapacity: true) }   // our block arrived
        incomingSequence = sequence
        incomingAcknowledged = header.acknowledged
        incomingReliableAcknowledged = header.reliableAcknowledged
        if header.reliable { incomingReliableSequence.toggle() }
        lastReceived = CACurrentMediaTime()
        return r.rest()
    }

    // MARK: - Connectionless packets

    /// 0xFFFFFFFF then the body: server-info queries that need no channel.
    static func outOfBand(_ body: Data) -> Data {
        var w = MsgWriter()
        w.u32(DatagramOutOfBandMarker())
        w.bytes(body)
        return w.data
    }

    static func outOfBandBody(_ packet: Data) -> Data? {
        var r = MsgReader(packet)
        return r.u32() == DatagramOutOfBandMarker() && !r.overflow ? r.rest() : nil
    }
}
