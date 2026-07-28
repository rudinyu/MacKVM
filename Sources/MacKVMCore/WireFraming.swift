import Foundation

enum LengthPrefixedFrameError: Error, Equatable {
    case invalidLength
}

enum LengthPrefixedFrameCodec {
    static let maximumPayloadLength = 1_048_576
    private static let headerLength = 4

    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty,
              payload.count <= maximumPayloadLength else {
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
        from buffer: inout Data
    ) throws -> [Data] {
        var payloads: [Data] = []
        while buffer.count >= headerLength {
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
}

enum CanonicalJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
