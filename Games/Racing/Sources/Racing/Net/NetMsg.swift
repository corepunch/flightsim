import Foundation
import simd

/// Little-endian packet writer. Strings and blobs carry a length prefix, and every
/// message is framed (`message(_:_:)`) so a reader can skip types it doesn't know.
struct MsgWriter {
    private(set) var data = Data()

    init() { data.reserveCapacity(256) }

    var count: Int { data.count }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { int(v) }
    mutating func u32(_ v: UInt32) { int(v) }
    mutating func u64(_ v: UInt64) { int(v) }
    mutating func i8(_ v: Int8) { u8(UInt8(bitPattern: v)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func vec3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }

    /// u8 length + UTF-8, cut on a character boundary so it never decodes as garbage.
    mutating func string(_ s: String, maxBytes: Int = 255) {
        var s = Substring(s)
        while s.utf8.count > min(maxBytes, 255) { s = s.dropLast() }
        u8(UInt8(s.utf8.count))
        data.append(contentsOf: s.utf8)
    }

    /// u16 length + bytes.
    mutating func blob(_ d: Data) {
        let d = d.prefix(Int(UInt16.max))
        u16(UInt16(d.count))
        data.append(d)
    }

    mutating func bytes(_ d: Data) { data.append(d) }

    /// u8 type, u16 body length, body.
    mutating func message(_ type: UInt8, _ body: (inout MsgWriter) -> Void = { _ in }) {
        var b = MsgWriter()
        body(&b)
        u8(type)
        u16(UInt16(min(b.count, Int(UInt16.max))))
        data.append(b.data)
    }

    private mutating func int<T: FixedWidthInteger & UnsignedInteger>(_ v: T) {
        for i in 0..<MemoryLayout<T>.size { data.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
}

/// Reads what `MsgWriter` wrote. Reading past the end returns zeros and sets `overflow`,
/// so a truncated or hostile packet can't crash the parser: check `overflow` once at the end.
struct MsgReader {
    private let data: Data
    private var pos: Int
    private(set) var overflow = false

    init(_ data: Data) {
        self.data = data
        pos = data.startIndex
    }

    var remaining: Int { max(0, data.endIndex - pos) }

    mutating func u8() -> UInt8 {
        guard remaining >= 1 else { return fail(0) }
        defer { pos += 1 }
        return data[pos]
    }
    mutating func u16() -> UInt16 { int() }
    mutating func u32() -> UInt32 { int() }
    mutating func u64() -> UInt64 { int() }
    mutating func i8() -> Int8 { Int8(bitPattern: u8()) }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func f64() -> Double { Double(bitPattern: u64()) }
    mutating func vec3() -> SIMD3<Float> { SIMD3(f32(), f32(), f32()) }
    mutating func bool() -> Bool { u8() != 0 }

    mutating func string() -> String {
        String(decoding: bytes(Int(u8())), as: UTF8.self)
    }

    mutating func blob() -> Data { bytes(Int(u16())) }

    mutating func bytes(_ n: Int) -> Data {
        guard n >= 0, remaining >= n else { return fail(Data()) }
        defer { pos += n }
        return Data(data[pos..<pos + n])
    }

    mutating func rest() -> Data { bytes(remaining) }

    /// Next framed message, or nil at the end (or on a truncated frame).
    mutating func message() -> (type: UInt8, body: MsgReader)? {
        guard remaining >= 3 else { return nil }
        let type = u8()
        let body = bytes(Int(u16()))
        return overflow ? nil : (type, MsgReader(body))
    }

    private mutating func int<T: FixedWidthInteger & UnsignedInteger>() -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { return fail(0) }
        var v: T = 0
        for i in 0..<n { v |= T(data[pos + i]) << (8 * i) }
        pos += n
        return v
    }

    private mutating func fail<T>(_ value: T) -> T {
        overflow = true
        pos = data.endIndex
        return value
    }
}
