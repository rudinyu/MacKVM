#ifndef MACKVM_NATIVE_DDC_H
#define MACKVM_NATIVE_DDC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacKVMNativeDDCList *MacKVMNativeDDCListRef;

typedef enum {
    MacKVMNativeDDCTransportIntel = 0,
    MacKVMNativeDDCTransportAppleSilicon = 1
} MacKVMNativeDDCTransport;

typedef struct {
    uint16_t currentValue;
    uint16_t maximumValue;
    uint8_t valueType;
} MacKVMNativeDDCVCPValue;

/**
 * Enumerates connected external displays with a native DDC/CI transport.
 *
 * The returned list owns all IOKit objects used by the entries and must be
 * released with MacKVMNativeDDCReleaseList. The optional error buffer is
 * always NUL terminated when its capacity is non-zero.
 */
MacKVMNativeDDCListRef MacKVMNativeDDCCreateList(
    char *errorBuffer,
    size_t errorCapacity
);

size_t MacKVMNativeDDCListCount(MacKVMNativeDDCListRef list);
const char *MacKVMNativeDDCListNameAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
const char *MacKVMNativeDDCListIdentifierAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
MacKVMNativeDDCTransport MacKVMNativeDDCListTransportAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
uint32_t MacKVMNativeDDCListVendorIDAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
uint32_t MacKVMNativeDDCListProductIDAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
uint32_t MacKVMNativeDDCListSerialNumberAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
size_t MacKVMNativeDDCListEDIDLengthAt(
    MacKVMNativeDDCListRef list,
    size_t index
);
size_t MacKVMNativeDDCCopyEDIDAt(
    MacKVMNativeDDCListRef list,
    size_t index,
    uint8_t *destination,
    size_t destinationCapacity
);

void MacKVMNativeDDCReleaseList(MacKVMNativeDDCListRef list);

/**
 * Sets VCP 0x60 on the display identified by a value returned from the list.
 * After a successful write, the native transport is retained in a bounded
 * selector-keyed cache. If changing the monitor input temporarily removes
 * the display from CoreGraphics, a later write can use that retained route.
 * Only the input values supported by MacKVM are accepted.
 * The optional error buffer is always NUL terminated when its capacity is
 * non-zero.
 */
int MacKVMNativeDDCSwitchInput(
    const char *displayIdentifier,
    uint32_t inputValue,
    char *errorBuffer,
    size_t errorCapacity
);

/**
 * Reads one VCP feature from the selected display. This is intended for
 * diagnostics and read-only verification; the returned value is bounded by
 * the DDC/CI reply packet size.
 */
int MacKVMNativeDDCReadVCP(
    const char *displayIdentifier,
    uint8_t vcpCode,
    MacKVMNativeDDCVCPValue *value,
    char *errorBuffer,
    size_t errorCapacity
);

/**
 * Writes the input-source VCP 0x60 value for an explicitly selected display.
 * The app uses MacKVMNativeDDCSwitchInput for its allow-listed input values;
 * this lower-level operation exists for the opt-in diagnostic scanner only.
 * Other VCP features are intentionally read-only through this API.
 */
int MacKVMNativeDDCWriteVCP(
    const char *displayIdentifier,
    uint8_t vcpCode,
    uint16_t value,
    char *errorBuffer,
    size_t errorCapacity
);

#ifdef __cplusplus
}
#endif

#endif
