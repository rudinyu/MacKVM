#ifndef MACKVM_NATIVE_DDC_H
#define MACKVM_NATIVE_DDC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacKVMNativeDDCList *MacKVMNativeDDCListRef;

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

void MacKVMNativeDDCReleaseList(MacKVMNativeDDCListRef list);

/**
 * Sets VCP 0x60 on the display identified by a value returned from the list.
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

#ifdef __cplusplus
}
#endif

#endif
