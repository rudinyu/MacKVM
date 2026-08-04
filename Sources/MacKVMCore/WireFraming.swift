import Foundation

enum LengthPrefixedFrameError: Error, Equatable {
    case invalidLength
}

enum LengthPrefixedFrameCodec {
    static let defaultMaximumPayloadLength = 1_048_576
    static let maximumSecurePayloadLength = 64 * 1024
    private static let headerLength = 4

    static func encode(
        _ payload: Data,
        maximumPayloadLength: Int = defaultMaximumPayloadLength
    ) throws -> Data {
        guard !payload.isEmpty,
              payload.count <= maximumPayloadLength,
              maximumPayloadLength > 0 else {
            throw LengthPrefixedFrameError.invalidLength
        }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        frame.append(payload)
        return frame
    }

    static func decodeAvailablePayloads(
        from buffer: inout Data,
        maximumPayloadLength: Int = defaultMaximumPayloadLength,
        maximumFrameCount: Int? = nil
    ) throws -> [Data] {
        guard maximumPayloadLength > 0 else {
            throw LengthPrefixedFrameError.invalidLength
        }
        if let maximumFrameCount, maximumFrameCount <= 0 {
            throw LengthPrefixedFrameError.invalidLength
        }
        var payloads: [Data] = []
        while buffer.count >= headerLength {
            if let maximumFrameCount,
               payloads.count >= maximumFrameCount {
                break
            }
            let length = buffer.prefix(headerLength).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard length > 0, length <= maximumPayloadLength else {
                throw LengthPrefixedFrameError.invalidLength
            }
            let frameLength = headerLength + length
            guard buffer.count >= frameLength else { break }
            payloads.append(
                buffer.subdata(in: headerLength..<frameLength)
            )
            buffer.removeSubrange(0..<frameLength)
        }
        return payloads
    }

    static func hasCompleteFrame(
        in buffer: Data,
        maximumPayloadLength: Int
    ) -> Bool {
        guard buffer.count >= headerLength,
              maximumPayloadLength > 0 else {
            return false
        }
        let length = buffer.prefix(headerLength).reduce(0) {
            ($0 << 8) | Int($1)
        }
        return length > 0
            && length <= maximumPayloadLength
            && buffer.count >= headerLength + length
    }
}

enum CanonicalJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
