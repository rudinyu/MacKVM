import Foundation
import MacKVMNativeDDC
import MacKVMCore

struct NativeDDCServiceError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Swift-owned façade around the small native IOKit bridge. The C layer keeps
/// all IOKit/CoreDisplay objects private and returns only bounded display
/// names and stable selectors to the app.
enum NativeDDCService {
    static func discover() throws -> [DDCDisplay] {
        var error = [CChar](repeating: 0, count: 512)
        guard let list = MacKVMNativeDDCCreateList(&error, error.count) else {
            throw NativeDDCServiceError(message: errorMessage(error))
        }
        defer { MacKVMNativeDDCReleaseList(list) }

        let count = min(
            MacKVMNativeDDCListCount(list),
            32
        )
        var displays: [DDCDisplay] = []
        displays.reserveCapacity(count)
        for index in 0..<count {
            guard let namePointer = MacKVMNativeDDCListNameAt(list, index),
                  let identifierPointer = MacKVMNativeDDCListIdentifierAt(
                      list,
                      index
                  ) else {
                continue
            }
            let name = String(cString: namePointer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = String(cString: identifierPointer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            displays.append(
                DDCDisplay(
                    index: index + 1,
                    name: name.isEmpty ? "External display" : name,
                    stableIdentifier: identifier,
                    vendorID: MacKVMNativeDDCListVendorIDAt(list, index),
                    productID: MacKVMNativeDDCListProductIDAt(list, index)
                )
            )
        }
        if displays.isEmpty {
            throw NativeDDCServiceError(message: errorMessage(error))
        }
        return displays
    }

    static func switchInput(
        displaySelector: String,
        input: MonitorInputSource,
        vendorID: UInt32? = nil,
        productID: UInt32? = nil
    ) throws {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !selector.isEmpty else {
            throw NativeDDCServiceError(message: "No DDC display is selected")
        }
        var error = [CChar](repeating: 0, count: 512)
        let succeeded = selector.withCString { selectorPointer in
            MacKVMNativeDDCSwitchInput(
                selectorPointer,
                MonitorInputMapping.rawValue(
                    for: input,
                    vendorID: vendorID,
                    productID: productID
                ),
                &error,
                error.count
            )
        }
        guard succeeded != 0 else {
            throw NativeDDCServiceError(message: errorMessage(error))
        }
    }

    private static func errorMessage(_ buffer: [CChar]) -> String {
        let message = buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
        return message.isEmpty
            ? "Native DDC/CI operation failed"
            : String(message.prefix(600))
    }
}
