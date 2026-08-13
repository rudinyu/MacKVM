@import CoreFoundation;
@import CoreGraphics;
@import Foundation;
@import IOKit;

#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>

#include <mach/error.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MacKVMNativeDDC.h"

// IOAVService is a private CoreDisplay type. Its ABI is a CFTypeRef and the
// symbols are exported by CoreDisplay on Apple Silicon, but no public header
// is shipped in the SDK.
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(
    CFAllocatorRef allocator,
    io_service_t service
);
extern IOReturn IOAVServiceWriteI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    const void *inputBuffer,
    uint32_t inputBufferSize
);

// CoreDisplay exposes the display-location dictionary used to associate a
// CGDirectDisplayID with its Apple Silicon DCP service.
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(
    CGDirectDisplayID display
);

enum {
    kMacKVMNativeDDCMaxDisplays = 32,
    kMacKVMNativeDDCNameCapacity = 256,
    kMacKVMNativeDDCIdentifierCapacity = 256,
    kMacKVMNativeDDCStandardChipAddress = 0x37,
    kMacKVMNativeDDCMCDP29xxChipAddress = 0xB7,
    kMacKVMNativeDDCInputVCP = 0x60,
    kMacKVMNativeDDCAddressByte = 0x51,
    kMacKVMNativeDDCWriteAddress = 0x6E
};

typedef enum {
    kMacKVMNativeDDCTransportIntel = 0,
    kMacKVMNativeDDCTransportAppleSilicon = 1
} MacKVMNativeDDCTransport;

typedef struct {
    CGDirectDisplayID displayID;
    io_service_t framebuffer;
    IOAVServiceRef avService;
    uint32_t chipAddress;
    MacKVMNativeDDCTransport transport;
    char name[kMacKVMNativeDDCNameCapacity];
    char identifier[kMacKVMNativeDDCIdentifierCapacity];
} MacKVMNativeDDCDisplay;

struct MacKVMNativeDDCList {
    size_t count;
    MacKVMNativeDDCDisplay displays[kMacKVMNativeDDCMaxDisplays];
};

static void clearError(char *buffer, size_t capacity) {
    if (buffer != NULL && capacity > 0) {
        buffer[0] = '\0';
    }
}

static void setError(char *buffer, size_t capacity, const char *format, ...) {
    if (buffer == NULL || capacity == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, capacity, format, arguments);
    va_end(arguments);
    buffer[capacity - 1] = '\0';
}

static void setIOReturnError(
    char *buffer,
    size_t capacity,
    const char *operation,
    IOReturn result
) {
    const char *description = mach_error_string(result);
    if (description != NULL) {
        setError(buffer, capacity, "%s failed: %s (0x%08x)", operation,
                 description, result);
    } else {
        setError(buffer, capacity, "%s failed (0x%08x)", operation, result);
    }
}

static void copyCString(
    char *destination,
    size_t capacity,
    const char *source,
    const char *fallback
) {
    if (capacity == 0) {
        return;
    }
    const char *value = source != NULL && source[0] != '\0' ? source : fallback;
    if (value == NULL) {
        value = "";
    }
    snprintf(destination, capacity, "%s", value);
    destination[capacity - 1] = '\0';
}

static void copyCFString(
    char *destination,
    size_t capacity,
    CFStringRef value,
    const char *fallback
) {
    if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetCString(value, destination, capacity, kCFStringEncodingUTF8)) {
        destination[capacity - 1] = '\0';
        return;
    }
    copyCString(destination, capacity, NULL, fallback);
}

static CFStringRef displayProductName(CFDictionaryRef info) {
    if (info == NULL || CFGetTypeID(info) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    CFTypeRef product = CFDictionaryGetValue(info, CFSTR("DisplayProductName"));
    if (product == NULL || CFGetTypeID(product) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    CFStringRef name = (CFStringRef)CFDictionaryGetValue(
        (CFDictionaryRef)product,
        CFSTR("en_US")
    );
    if (name == NULL) {
        CFIndex count = CFDictionaryGetCount((CFDictionaryRef)product);
        if (count > 0) {
            const void **values = calloc((size_t)count, sizeof(*values));
            if (values != NULL) {
                CFDictionaryGetKeysAndValues(
                    (CFDictionaryRef)product,
                    NULL,
                    values
                );
                name = (CFStringRef)values[0];
                free(values);
            }
        }
    }
    return name != NULL && CFGetTypeID(name) == CFStringGetTypeID() ? name : NULL;
}

static void copyDisplayName(
    char *destination,
    size_t capacity,
    io_service_t framebuffer,
    CGDirectDisplayID displayID
) {
    CFDictionaryRef info = NULL;
    if (framebuffer != MACH_PORT_NULL) {
        info = IODisplayCreateInfoDictionary(
            framebuffer,
            kIODisplayOnlyPreferredName
        );
    }
    CFStringRef productName = displayProductName(info);
    if (productName != NULL) {
        copyCFString(destination, capacity, productName, NULL);
    } else {
        char fallback[64];
        snprintf(
            fallback,
            sizeof(fallback),
            "External display %u",
            (unsigned int)displayID
        );
        copyCString(destination, capacity, NULL, fallback);
    }
    if (info != NULL) {
        CFRelease(info);
    }
}

static bool displayInfoMatches(
    io_service_t framebuffer,
    CGDirectDisplayID displayID
) {
    if (framebuffer == MACH_PORT_NULL) {
        return false;
    }
    CFDictionaryRef info = IODisplayCreateInfoDictionary(
        framebuffer,
        kIODisplayOnlyPreferredName
    );
    if (info == NULL) {
        return false;
    }
    CFNumberRef vendorNumber = (CFNumberRef)CFDictionaryGetValue(
        info,
        CFSTR("DisplayVendorID")
    );
    CFNumberRef productNumber = (CFNumberRef)CFDictionaryGetValue(
        info,
        CFSTR("DisplayProductID")
    );
    CFNumberRef serialNumber = (CFNumberRef)CFDictionaryGetValue(
        info,
        CFSTR("DisplaySerialNumber")
    );
    int32_t vendor = 0;
    int32_t product = 0;
    int32_t serial = 0;
    bool valid = vendorNumber != NULL
        && productNumber != NULL
        && CFGetTypeID(vendorNumber) == CFNumberGetTypeID()
        && CFGetTypeID(productNumber) == CFNumberGetTypeID()
        && CFNumberGetValue(vendorNumber, kCFNumberSInt32Type, &vendor)
        && CFNumberGetValue(productNumber, kCFNumberSInt32Type, &product);
    if (valid && serialNumber != NULL
        && CFGetTypeID(serialNumber) == CFNumberGetTypeID()) {
        CFNumberGetValue(serialNumber, kCFNumberSInt32Type, &serial);
    }
    bool matches = valid
        && (uint32_t)vendor == CGDisplayVendorNumber(displayID)
        && (uint32_t)product == CGDisplayModelNumber(displayID)
        && (uint32_t)serial == CGDisplaySerialNumber(displayID);
    if (matches) {
        // Vendor/product/serial is not sufficient for cloned panels: many
        // displays report a zero serial, and identical panels can expose the
        // same EDID. IODisplayLocation includes the framebuffer unit after
        // the last '@' (for example, ...@1,...). Use it when available so
        // each CGDirectDisplayID is paired with its own framebuffer.
        CFTypeRef location = CFDictionaryGetValue(
            info,
            CFSTR("IODisplayLocation")
        );
        if (location != NULL
            && CFGetTypeID(location) == CFStringGetTypeID()) {
            char locationBuffer[256] = { 0 };
            if (CFStringGetCString(
                (CFStringRef)location,
                locationBuffer,
                sizeof(locationBuffer),
                kCFStringEncodingUTF8
            )) {
                const char *at = strrchr(locationBuffer, '@');
                if (at != NULL && at[1] != '\0') {
                    char *end = NULL;
                    unsigned long unit = strtoul(at + 1, &end, 10);
                    if (end != at + 1 && unit <= UINT32_MAX) {
                        matches = (uint32_t)unit == CGDisplayUnitNumber(displayID);
                    }
                }
            }
        }
    }
    CFRelease(info);
    return matches;
}

static void makeIdentifier(
    char *destination,
    size_t capacity,
    CGDirectDisplayID displayID,
    io_service_t framebuffer
) {
    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t model = CGDisplayModelNumber(displayID);
    uint32_t serial = CGDisplaySerialNumber(displayID);
    // A zero serial is common. Prefer an EDID fingerprint so the selector
    // survives display reconnects and reboots. Without EDID bytes there is no
    // genuinely persistent discriminator, so leave this display unselectable.
    if (serial == 0) {
        uint64_t fingerprint = 0;
        CFDictionaryRef info = NULL;
        if (framebuffer != MACH_PORT_NULL) {
            info = IODisplayCreateInfoDictionary(framebuffer, 0);
        }
        CFTypeRef edid = info == NULL
            ? NULL
            : CFDictionaryGetValue(info, CFSTR(kIODisplayEDIDKey));
        bool hasEDID = edid != NULL
            && CFGetTypeID(edid) == CFDataGetTypeID()
            && CFDataGetLength((CFDataRef)edid) > 0;
        if (hasEDID) {
            const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)edid);
            CFIndex length = CFDataGetLength((CFDataRef)edid);
            fingerprint = UINT64_C(1469598103934665603);
            for (CFIndex index = 0; index < length; index += 1) {
                fingerprint ^= bytes[index];
                fingerprint *= UINT64_C(1099511628211);
            }
        }
        if (info != NULL) {
            CFRelease(info);
        }
        if (hasEDID) {
            snprintf(destination, capacity, "native-ddc:%u:%u:edid-%016llx",
                     vendor, model, (unsigned long long)fingerprint);
        } else {
            destination[0] = '\0';
        }
    } else {
        snprintf(destination, capacity, "native-ddc:%u:%u:%u",
                 vendor, model, serial);
    }
    destination[capacity - 1] = '\0';
}

static bool isExternalDisplay(CGDirectDisplayID displayID) {
    return !CGDisplayIsBuiltin(displayID);
}

#if defined(__arm64__)

static bool cfStringEquals(CFTypeRef value, CFStringRef expected) {
    return value != NULL
        && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringCompare((CFStringRef)value, expected, 0) == kCFCompareEqualTo;
}

static bool isMCDP29xxProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent)
        != KERN_SUCCESS) {
        return false;
    }
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        parent,
        CFSTR("EPICProviderClass"),
        kCFAllocatorDefault,
        0
    );
    bool result = cfStringEquals(value, CFSTR("AppleDCPMCDP29XX"));
    if (value != NULL) {
        CFRelease(value);
    }
    IOObjectRelease(parent);
    return result;
}

static bool isExternalProxy(io_service_t proxy) {
    CFTypeRef value = IORegistryEntrySearchCFProperty(
        proxy,
        kIOServicePlane,
        CFSTR("Location"),
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
    bool result = cfStringEquals(value, CFSTR("External"));
    if (value != NULL) {
        CFRelease(value);
    }
    return result;
}

static IOAVServiceRef avServiceForDisplay(
    CGDirectDisplayID displayID,
    uint32_t *chipAddress
) {
    if (chipAddress != NULL) {
        *chipAddress = kMacKVMNativeDDCStandardChipAddress;
    }
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (info == NULL) {
        return NULL;
    }
    CFTypeRef locationValue = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    // The private dictionary is allowed to change shape; fail closed when the
    // location is missing or is not a string rather than guessing a service.
    if (locationValue == NULL
        || CFGetTypeID(locationValue) != CFStringGetTypeID()) {
        CFRelease(info);
        return NULL;
    }
    io_registry_entry_t adapter = IORegistryEntryCopyFromPath(
        kIOMainPortDefault,
        (CFStringRef)locationValue
    );
    CFRelease(info);
    if (adapter == MACH_PORT_NULL) {
        return NULL;
    }

    // The location entry identifies the framebuffer selected by CoreDisplay.
    // Enumerate only that entry's descendants.  A root-wide iterator cannot
    // reliably associate a DCPAVServiceProxy with its framebuffer because
    // IOKit traversal order is not a display-topology boundary; on a setup
    // with multiple external monitors it could otherwise select another
    // monitor's proxy and route DDC writes to the wrong display.
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t iteratorResult = IORegistryEntryCreateIterator(
        adapter,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        &iterator
    );
    if (iteratorResult != KERN_SUCCESS) {
        IOObjectRelease(adapter);
        return NULL;
    }

    IOAVServiceRef result = NULL;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        io_name_t name = { 0 };
        IORegistryEntryGetName(service, name);
        if (strcmp(name, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(service);
            continue;
        }
        if (!isExternalProxy(service)) {
            IOObjectRelease(service);
            continue;
        }
        result = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
        if (result != NULL && chipAddress != NULL && isMCDP29xxProxy(service)) {
            *chipAddress = kMacKVMNativeDDCMCDP29xxChipAddress;
        }
        IOObjectRelease(service);
        if (result != NULL) {
            break;
        }
    }
    IOObjectRelease(iterator);
    IOObjectRelease(adapter);
    return result;
}

#endif

static io_service_t framebufferForDisplay(CGDirectDisplayID displayID) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOFramebuffer");
    if (matching == NULL) {
        return MACH_PORT_NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    ) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (displayInfoMatches(service, displayID)) {
            IOObjectRelease(iterator);
            return service;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return MACH_PORT_NULL;
}

static bool addDisplay(
    struct MacKVMNativeDDCList *list,
    CGDirectDisplayID displayID,
    io_service_t framebuffer,
    IOAVServiceRef avService,
    MacKVMNativeDDCTransport transport,
    uint32_t chipAddress
) {
    if (list == NULL || list->count >= kMacKVMNativeDDCMaxDisplays) {
        return false;
    }
    MacKVMNativeDDCDisplay *display = &list->displays[list->count];
    memset(display, 0, sizeof(*display));
    display->displayID = displayID;
    display->framebuffer = framebuffer;
    display->avService = avService;
    display->transport = transport;
    display->chipAddress = chipAddress;
    copyDisplayName(display->name, sizeof(display->name), framebuffer, displayID);
    makeIdentifier(
        display->identifier,
        sizeof(display->identifier),
        displayID,
        framebuffer
    );
    list->count += 1;
    return true;
}

static void removeAmbiguousIdentifiers(
    struct MacKVMNativeDDCList *list
) {
    if (list == NULL) {
        return;
    }
    // Identical panels can expose the same vendor/model/EDID tuple while
    // reporting no serial number. There is no stable software discriminator
    // for those physical outputs, so hide every duplicate selector instead of
    // silently routing a request to whichever display happens to be first.
    bool duplicateFlags[kMacKVMNativeDDCMaxDisplays] = { false };
    for (size_t first = 0; first < list->count; first += 1) {
        if (list->displays[first].identifier[0] == '\0') {
            continue;
        }
        for (size_t second = first + 1; second < list->count; second += 1) {
            if (list->displays[second].identifier[0] == '\0') {
                continue;
            }
            if (strcmp(
                list->displays[first].identifier,
                list->displays[second].identifier
            ) == 0) {
                duplicateFlags[first] = true;
                duplicateFlags[second] = true;
            }
        }
    }
    for (size_t index = 0; index < list->count; index += 1) {
        if (duplicateFlags[index]) {
            list->displays[index].identifier[0] = '\0';
        }
    }
}

#if !defined(__arm64__)

static bool intelDisplayHasDDC(io_service_t framebuffer) {
    if (framebuffer == MACH_PORT_NULL) {
        return false;
    }
    IOItemCount count = 0;
    return IOFBGetI2CInterfaceCount(framebuffer, &count) == kIOReturnSuccess
        && count > 0;
}

#endif

static bool identifierMatches(
    const char *identifier,
    const char *candidate
) {
    return identifier != NULL && candidate != NULL
        && strnlen(identifier, kMacKVMNativeDDCIdentifierCapacity)
            < kMacKVMNativeDDCIdentifierCapacity
        && strcmp(identifier, candidate) == 0;
}

MacKVMNativeDDCListRef MacKVMNativeDDCCreateList(
    char *errorBuffer,
    size_t errorCapacity
) {
    clearError(errorBuffer, errorCapacity);
    struct MacKVMNativeDDCList *list = calloc(1, sizeof(*list));
    if (list == NULL) {
        setError(errorBuffer, errorCapacity, "Unable to allocate display list");
        return NULL;
    }

    CGDirectDisplayID displayIDs[kMacKVMNativeDDCMaxDisplays] = { 0 };
    CGDisplayCount displayCount = 0;
    CGError displayResult = CGGetOnlineDisplayList(
        kMacKVMNativeDDCMaxDisplays,
        displayIDs,
        &displayCount
    );
    if (displayResult != kCGErrorSuccess) {
        setError(errorBuffer, errorCapacity,
                 "Could not enumerate displays (CoreGraphics error %d)",
                 (int)displayResult);
        free(list);
        return NULL;
    }

    // With a non-NULL output buffer, CoreGraphics stores at most
    // kMacKVMNativeDDCMaxDisplays entries but may still report the total
    // number of online displays. Never index beyond the fixed array when a
    // host has more online displays than this native bridge retains.
    CGDisplayCount storedDisplayCount = displayCount;
    if (storedDisplayCount > kMacKVMNativeDDCMaxDisplays) {
        storedDisplayCount = kMacKVMNativeDDCMaxDisplays;
    }

    for (CGDisplayCount index = 0;
         index < storedDisplayCount && list->count < kMacKVMNativeDDCMaxDisplays;
         index += 1) {
        CGDirectDisplayID displayID = displayIDs[index];
        if (!isExternalDisplay(displayID)) {
            continue;
        }
#if defined(__arm64__)
        uint32_t chipAddress = kMacKVMNativeDDCStandardChipAddress;
        IOAVServiceRef avService = avServiceForDisplay(displayID, &chipAddress);
        if (avService != NULL) {
            io_service_t framebuffer = framebufferForDisplay(displayID);
            if (!addDisplay(
                list,
                displayID,
                framebuffer,
                avService,
                kMacKVMNativeDDCTransportAppleSilicon,
                chipAddress
            )) {
                if (framebuffer != MACH_PORT_NULL) {
                    IOObjectRelease(framebuffer);
                }
                CFRelease(avService);
            }
        }
#else
        io_service_t framebuffer = framebufferForDisplay(displayID);
        if (intelDisplayHasDDC(framebuffer)) {
            if (!addDisplay(
                list,
                displayID,
                framebuffer,
                NULL,
                kMacKVMNativeDDCTransportIntel,
                kMacKVMNativeDDCStandardChipAddress
            ) && framebuffer != MACH_PORT_NULL) {
                IOObjectRelease(framebuffer);
            }
        } else if (framebuffer != MACH_PORT_NULL) {
            IOObjectRelease(framebuffer);
        }
#endif
    }
    removeAmbiguousIdentifiers(list);
    bool hasUsableDisplay = false;
    for (size_t index = 0; index < list->count; index += 1) {
        if (list->displays[index].identifier[0] != '\0') {
            hasUsableDisplay = true;
            break;
        }
    }
    if (!hasUsableDisplay && errorBuffer != NULL && errorCapacity > 0) {
        setError(errorBuffer, errorCapacity,
                 "No external display with a unique native DDC/CI identity was found");
    }
    return list;
}

size_t MacKVMNativeDDCListCount(MacKVMNativeDDCListRef list) {
    return list == NULL ? 0 : list->count;
}

const char *MacKVMNativeDDCListNameAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return NULL;
    }
    return list->displays[index].name;
}

const char *MacKVMNativeDDCListIdentifierAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return NULL;
    }
    return list->displays[index].identifier;
}

void MacKVMNativeDDCReleaseList(MacKVMNativeDDCListRef list) {
    if (list == NULL) {
        return;
    }
    for (size_t index = 0; index < list->count; index += 1) {
        MacKVMNativeDDCDisplay *display = &list->displays[index];
        if (display->avService != NULL) {
            CFRelease(display->avService);
            display->avService = NULL;
        }
        if (display->framebuffer != MACH_PORT_NULL) {
            IOObjectRelease(display->framebuffer);
            display->framebuffer = MACH_PORT_NULL;
        }
    }
    free(list);
}

static bool validInputValue(uint32_t value) {
    switch (value) {
        case 15:
        case 16:
        case 17:
        case 18:
        case 27:
            return true;
        default:
            return false;
    }
}

static void makeInputPacket(uint32_t inputValue, uint8_t packet[7]) {
    packet[0] = 0x51;
    packet[1] = 0x84;
    packet[2] = 0x03;
    packet[3] = kMacKVMNativeDDCInputVCP;
    packet[4] = 0x00;
    packet[5] = (uint8_t)inputValue;
    uint8_t checksum = kMacKVMNativeDDCWriteAddress;
    for (size_t index = 0; index < 6; index += 1) {
        checksum ^= packet[index];
    }
    packet[6] = checksum;
}

#if defined(__arm64__)

static IOReturn writeAppleSilicon(
    const MacKVMNativeDDCDisplay *display,
    const uint8_t packet[7]
) {
    IOReturn result = kIOReturnError;
    for (int attempt = 0; attempt < 3; attempt += 1) {
        usleep(10000);
        result = IOAVServiceWriteI2C(
            display->avService,
            display->chipAddress,
            kMacKVMNativeDDCAddressByte,
            packet + 1,
            6
        );
        if (result == kIOReturnSuccess) {
            return result;
        }
    }
    return result;
}

#else

static IOReturn writeIntel(
    const MacKVMNativeDDCDisplay *display,
    const uint8_t packet[7]
) {
    if (display->framebuffer == MACH_PORT_NULL) {
        return kIOReturnNoDevice;
    }
    IOItemCount busCount = 0;
    IOReturn result = IOFBGetI2CInterfaceCount(
        display->framebuffer,
        &busCount
    );
    if (result != kIOReturnSuccess || busCount == 0) {
        return result == kIOReturnSuccess ? kIOReturnNoDevice : result;
    }
    result = kIOReturnNoDevice;
    for (IOItemCount bus = 0; bus < busCount; bus += 1) {
        io_service_t interface = MACH_PORT_NULL;
        if (IOFBCopyI2CInterfaceForBus(
            display->framebuffer,
            bus,
            &interface
        ) != kIOReturnSuccess) {
            continue;
        }
        IOI2CConnectRef connection = NULL;
        IOReturn openResult = IOI2CInterfaceOpen(interface, kNilOptions, &connection);
        IOObjectRelease(interface);
        if (openResult != kIOReturnSuccess || connection == NULL) {
            result = openResult;
            continue;
        }

        IOI2CRequest request;
        memset(&request, 0, sizeof(request));
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.replyTransactionType = kIOI2CNoTransactionType;
        request.sendAddress = kMacKVMNativeDDCWriteAddress;
        request.sendBuffer = (vm_address_t)packet;
        request.sendBytes = 7;
        request.result = kIOReturnError;

        IOReturn sendResult = IOI2CSendRequest(
            connection,
            kNilOptions,
            &request
        );
        result = sendResult == kIOReturnSuccess ? request.result : sendResult;
        IOI2CInterfaceClose(connection, kNilOptions);
        if (result == kIOReturnSuccess) {
            return result;
        }
    }
    return result;
}

#endif

int MacKVMNativeDDCSwitchInput(
    const char *displayIdentifier,
    uint32_t inputValue,
    char *errorBuffer,
    size_t errorCapacity
) {
    clearError(errorBuffer, errorCapacity);
    if (!validInputValue(inputValue)) {
        setError(errorBuffer, errorCapacity,
                 "Unsupported monitor input value %u", (unsigned int)inputValue);
        return 0;
    }
    if (displayIdentifier == NULL
        || strnlen(displayIdentifier, kMacKVMNativeDDCIdentifierCapacity)
            >= kMacKVMNativeDDCIdentifierCapacity) {
        setError(errorBuffer, errorCapacity, "Invalid display selector");
        return 0;
    }

    char discoveryError[256];
    MacKVMNativeDDCListRef list = MacKVMNativeDDCCreateList(
        discoveryError,
        sizeof(discoveryError)
    );
    if (list == NULL) {
        setError(errorBuffer, errorCapacity, "%s",
                 discoveryError[0] == '\0' ? "Display discovery failed" : discoveryError);
        return 0;
    }
    MacKVMNativeDDCDisplay *selected = NULL;
    for (size_t index = 0; index < list->count; index += 1) {
        if (identifierMatches(displayIdentifier, list->displays[index].identifier)) {
            selected = &list->displays[index];
            break;
        }
    }
    if (selected == NULL) {
        setError(errorBuffer, errorCapacity,
                 "The selected display is no longer available");
        MacKVMNativeDDCReleaseList(list);
        return 0;
    }

    uint8_t packet[7];
    makeInputPacket(inputValue, packet);
    IOReturn result;
#if defined(__arm64__)
    result = writeAppleSilicon(selected, packet);
#else
    result = writeIntel(selected, packet);
#endif
    if (result != kIOReturnSuccess) {
        setIOReturnError(errorBuffer, errorCapacity, "DDC/CI input switch", result);
        MacKVMNativeDDCReleaseList(list);
        return 0;
    }
    MacKVMNativeDDCReleaseList(list);
    return 1;
}
