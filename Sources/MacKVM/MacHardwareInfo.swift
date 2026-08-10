import Darwin
import Foundation
import MacKVMCore

enum MacHardwareInfo {
    static let fallbackModel = PeerMetadataValidation.unknownModel

    static var currentModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 1 else {
            return fallbackModel
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return fallbackModel
        }
        return PeerMetadataValidation.validatedModel(
            String(cString: buffer)
        )
    }
}
