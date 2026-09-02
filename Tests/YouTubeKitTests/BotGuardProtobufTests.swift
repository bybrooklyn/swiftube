import Foundation
import Testing
@testable import YouTubeCore

// The hand-rolled protobuf reader under BotGuardClient's challenge parsing.
// The existing BotGuardClientTests drive the whole pipeline through JS; this
// covers the byte-level reader on its own, where a truncated or unexpected
// wire type used to be untested.

@Suite("BotGuard protobuf reader")
struct BotGuardProtobufTests {

    @Test("varint: one byte, two bytes, truncated, overlong")
    func varint() {
        #expect(BotGuardClient.readVarint(from: [0x05], at: 0)! == (5, 1))
        #expect(BotGuardClient.readVarint(from: [0xAC, 0x02], at: 0)! == (300, 2))
        #expect(BotGuardClient.readVarint(from: [0x00, 0x01], at: 1)! == (1, 2))
        #expect(BotGuardClient.readVarint(from: [0x80], at: 0) == nil)
        #expect(BotGuardClient.readVarint(from: [UInt8](repeating: 0xFF, count: 10), at: 0) == nil)
    }

    @Test("proto fields: length-delimited captured, other wire types skipped")
    func fields() {
        let bytes: [UInt8] = [
            0x08, 0x96, 0x01,                                   // 1: varint 150 — skipped
            0x12, 0x03, 0x61, 0x62, 0x63,                       // 2: "abc"
            0x1D, 0x01, 0x02, 0x03, 0x04,                       // 3: fixed32 — skipped
            0x21, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // 4: fixed64 — skipped
            0x2A, 0x02, 0x68, 0x69,                             // 5: "hi"
        ]
        let fields = BotGuardClient.readProtoFields(Data(bytes))
        #expect(fields.count == 2)
        #expect(fields[2].map { String(decoding: $0, as: UTF8.self) } == "abc")
        #expect(fields[5].map { String(decoding: $0, as: UTF8.self) } == "hi")
    }

    @Test("proto fields: a truncated length-delimited field ends parsing without a partial value")
    func truncated() {
        let fields = BotGuardClient.readProtoFields(Data([0x12, 0x05, 0x61]))
        #expect(fields.isEmpty)
    }

    @Test("proto fields: a proto2 group is skipped as a unit")
    func group() {
        let bytes: [UInt8] = [
            0x33,             // 6: start group
            0x08, 0x01,       //   1: varint
            0x12, 0x01, 0x78, //   2: "x" — inside the group, must not be captured
            0x34,             // 6: end group
            0x3A, 0x01, 0x7A, // 7: "z"
        ]
        let fields = BotGuardClient.readProtoFields(Data(bytes))
        #expect(fields.keys.sorted() == [7])
        #expect(fields[7].map { String(decoding: $0, as: UTF8.self) } == "z")
    }
}
