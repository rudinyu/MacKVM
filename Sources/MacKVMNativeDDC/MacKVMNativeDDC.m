@import CoreFoundation;
@import CoreGraphics;
@import Foundation;
@import IOKit;

#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>

#include <mach/error.h>
#include <mach/mach.h>
#include <pthread.h>
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
extern IOReturn IOAVServiceReadI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    void *outputBuffer,
    uint32_t outputBufferSize
);
extern IOReturn IOAVServiceCopyEDID(
    IOAVServiceRef service,
    CFDataRef *edidData
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

typedef struct {
    CGDirectDisplayID displayID;
    io_service_t framebuffer;
    IOAVServiceRef avService;
    CFDataRef edid;
    uint32_t chipAddress;
    MacKVMNativeDDCTransport transport;
    uint32_t vendorID;
    uint32_t productID;
    uint32_t serialNumber;
    char name[kMacKVMNativeDDCNameCapacity];
    char identifier[kMacKVMNativeDDCIdentifierCapacity];
} MacKVMNativeDDCDisplay;

struct MacKVMNativeDDCList {
    size_t count;
    MacKVMNativeDDCDisplay displays[kMacKVMNativeDDCMaxDisplays];
};

// A monitor can disappear from CoreGraphics while it is showing the other
// input. Keep the already-resolved native transport alive so a return-to-local
// write does not have to rediscover the display through CGGetOnlineDisplayList.
// The cache is bounded and keyed by the stable selector returned to Swift.
typedef struct {
    bool valid;
    char identifier[kMacKVMNativeDDCIdentifierCapacity];
    io_service_t framebuffer;
    IOAVServiceRef avService;
    uint32_t chipAddress;
    MacKVMNativeDDCTransport transport;
} MacKVMNativeDDCRouteCacheEntry;

static pthread_mutex_t routeCacheLock = PTHREAD_MUTEX_INITIALIZER;
static MacKVMNativeDDCRouteCacheEntry routeCache[
    kMacKVMNativeDDCMaxDisplays
];

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

static void releaseRouteCacheEntry(
    MacKVMNativeDDCRouteCacheEntry *entry
) {
    if (entry == NULL) {
        return;
    }
    if (entry->avService != NULL) {
        CFRelease(entry->avService);
        entry->avService = NULL;
    }
    if (entry->framebuffer != MACH_PORT_NULL) {
        IOObjectRelease(entry->framebuffer);
        entry->framebuffer = MACH_PORT_NULL;
    }
    entry->valid = false;
    entry->identifier[0] = '\0';
    entry->chipAddress = 0;
    entry->transport = MacKVMNativeDDCTransportIntel;
}

static size_t routeCacheIndexForIdentifier(const char *identifier) {
    if (identifier == NULL || identifier[0] == '\0') {
        return kMacKVMNativeDDCMaxDisplays;
    }
    for (size_t index = 0; index < kMacKVMNativeDDCMaxDisplays; index += 1) {
        if (routeCache[index].valid
            && strcmp(routeCache[index].identifier, identifier) == 0) {
            return index;
        }
    }
    return kMacKVMNativeDDCMaxDisplays;
}

static void cacheDisplayRoute(const MacKVMNativeDDCDisplay *display) {
    if (display == NULL || display->identifier[0] == '\0') {
        return;
    }

    pthread_mutex_lock(&routeCacheLock);
    size_t index = routeCacheIndexForIdentifier(display->identifier);
    if (index == kMacKVMNativeDDCMaxDisplays) {
        for (size_t candidate = 0;
             candidate < kMacKVMNativeDDCMaxDisplays;
             candidate += 1) {
            if (!routeCache[candidate].valid) {
                index = candidate;
                break;
            }
        }
    }
    // The cache is deliberately bounded. If every slot is occupied, replace
    // the oldest slot deterministically; callers still have the live list for
    // the current write, and future calls can repopulate this route.
    if (index == kMacKVMNativeDDCMaxDisplays) {
        index = 0;
    }
    releaseRouteCacheEntry(&routeCache[index]);

    MacKVMNativeDDCRouteCacheEntry *entry = &routeCache[index];
    entry->valid = true;
    copyCString(
        entry->identifier,
        sizeof(entry->identifier),
        display->identifier,
        ""
    );
    entry->chipAddress = display->chipAddress;
    entry->transport = display->transport;
    if (display->framebuffer != MACH_PORT_NULL
        && IOObjectRetain(display->framebuffer) == KERN_SUCCESS) {
        entry->framebuffer = display->framebuffer;
    }
    if (display->avService != NULL) {
        entry->avService = CFRetain(display->avService);
    }
    if (entry->framebuffer == MACH_PORT_NULL && entry->avService == NULL) {
        releaseRouteCacheEntry(entry);
    }
    pthread_mutex_unlock(&routeCacheLock);
}

static bool copyCachedRoute(
    const char *identifier,
    MacKVMNativeDDCDisplay *destination
) {
    if (destination == NULL || identifier == NULL || identifier[0] == '\0') {
        return false;
    }
    memset(destination, 0, sizeof(*destination));

    pthread_mutex_lock(&routeCacheLock);
    size_t index = routeCacheIndexForIdentifier(identifier);
    if (index == kMacKVMNativeDDCMaxDisplays) {
        pthread_mutex_unlock(&routeCacheLock);
        return false;
    }
    MacKVMNativeDDCRouteCacheEntry *entry = &routeCache[index];
    destination->chipAddress = entry->chipAddress;
    destination->transport = entry->transport;
    copyCString(
        destination->identifier,
        sizeof(destination->identifier),
        entry->identifier,
        ""
    );
    if (entry->framebuffer != MACH_PORT_NULL
        && IOObjectRetain(entry->framebuffer) == KERN_SUCCESS) {
        destination->framebuffer = entry->framebuffer;
    }
    if (entry->avService != NULL) {
        destination->avService = CFRetain(entry->avService);
    }
    bool copied = destination->framebuffer != MACH_PORT_NULL
        || destination->avService != NULL;
    pthread_mutex_unlock(&routeCacheLock);
    if (!copied) {
        if (destination->framebuffer != MACH_PORT_NULL) {
            IOObjectRelease(destination->framebuffer);
        }
        if (destination->avService != NULL) {
            CFRelease(destination->avService);
        }
        memset(destination, 0, sizeof(*destination));
    }
    return copied;
}

static void releaseRouteSnapshot(MacKVMNativeDDCDisplay *display) {
    if (display == NULL) {
        return;
    }
    if (display->avService != NULL) {
        CFRelease(display->avService);
        display->avService = NULL;
    }
    if (display->framebuffer != MACH_PORT_NULL) {
        IOObjectRelease(display->framebuffer);
        display->framebuffer = MACH_PORT_NULL;
    }
}

static void clearCachedRoute(const char *identifier) {
    if (identifier == NULL || identifier[0] == '\0') {
        return;
    }
    pthread_mutex_lock(&routeCacheLock);
    size_t index = routeCacheIndexForIdentifier(identifier);
    if (index != kMacKVMNativeDDCMaxDisplays) {
        releaseRouteCacheEntry(&routeCache[index]);
    }
    pthread_mutex_unlock(&routeCacheLock);
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

// IODisplayConnect entries are the metadata siblings of the Apple Silicon
// DCPAVServiceProxy.  They do not always carry the same registry location as
// the IOFramebuffer/CoreDisplay entry, so keep a second, deliberately looser
// identity check for the service-discovery fallback below.  A serialised
// display still has to match its serial; a zero-serial display is accepted
// only when the caller can prove there is a single matching entry.
static bool displayIdentityMatches(
    io_service_t displayService,
    CGDirectDisplayID displayID
) {
    if (displayService == MACH_PORT_NULL) {
        return false;
    }
    CFDictionaryRef info = IODisplayCreateInfoDictionary(
        displayService,
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
    uint32_t targetSerial = CGDisplaySerialNumber(displayID);
    bool matches = valid
        && (uint32_t)vendor == CGDisplayVendorNumber(displayID)
        && (uint32_t)product == CGDisplayModelNumber(displayID)
        && (targetSerial == 0 || (uint32_t)serial == targetSerial);
    CFRelease(info);
    return matches;
}

static void makeIdentifier(
    char *destination,
    size_t capacity,
    CGDirectDisplayID displayID,
    io_service_t framebuffer,
    CFDataRef displayEDID
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
        CFTypeRef framebufferEDID = info == NULL
            ? NULL
            : CFDictionaryGetValue(info, CFSTR(kIODisplayEDIDKey));
        CFDataRef edid = displayEDID != NULL
            ? displayEDID
            : (framebufferEDID != NULL
                && CFGetTypeID(framebufferEDID) == CFDataGetTypeID()
                ? (CFDataRef)framebufferEDID
                : NULL);
        bool hasEDID = edid != NULL && CFDataGetLength(edid) > 0;
        if (hasEDID) {
            const UInt8 *bytes = CFDataGetBytePtr(edid);
            CFIndex length = CFDataGetLength(edid);
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

static CFDataRef copyAVServiceEDID(IOAVServiceRef service) {
    if (service == NULL) {
        return NULL;
    }
    CFDataRef edid = NULL;
    IOReturn result = IOAVServiceCopyEDID(service, &edid);
    if (result == kIOReturnSuccess
        && edid != NULL
        && CFGetTypeID(edid) == CFDataGetTypeID()
        && CFDataGetLength(edid) > 0) {
        return edid;
    }
    if (edid != NULL) {
        CFRelease(edid);
    }
    return NULL;
}

static bool edidMatchesDisplay(
    CFDataRef edid,
    CGDirectDisplayID displayID
) {
    if (edid == NULL || CFGetTypeID(edid) != CFDataGetTypeID()) {
        return false;
    }
    CFIndex length = CFDataGetLength(edid);
    if (length < 16) {
        return false;
    }
    const UInt8 *bytes = CFDataGetBytePtr(edid);
    uint32_t vendor = ((uint32_t)bytes[8] << 8) | bytes[9];
    uint32_t product = (uint32_t)bytes[10]
        | ((uint32_t)bytes[11] << 8);
    uint32_t serial = (uint32_t)bytes[12]
        | ((uint32_t)bytes[13] << 8)
        | ((uint32_t)bytes[14] << 16)
        | ((uint32_t)bytes[15] << 24);
    uint32_t targetSerial = CGDisplaySerialNumber(displayID);
    return vendor == CGDisplayVendorNumber(displayID)
        && product == CGDisplayModelNumber(displayID)
        && (targetSerial == 0 || serial == targetSerial);
}

static IOAVServiceRef avServiceForGlobalProxy(
    CGDirectDisplayID displayID,
    uint32_t *chipAddress,
    io_service_t *matchedServiceOut,
    CFDataRef *edidOut
) {
    if (chipAddress != NULL) {
        *chipAddress = kMacKVMNativeDDCStandardChipAddress;
    }
    if (matchedServiceOut != NULL) {
        *matchedServiceOut = MACH_PORT_NULL;
    }
    if (edidOut != NULL) {
        *edidOut = NULL;
    }

    CFMutableDictionaryRef matching = IOServiceMatching(
        "DCPAVServiceProxy"
    );
    if (matching == NULL) {
        return NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    ) != KERN_SUCCESS) {
        return NULL;
    }

    IOAVServiceRef selectedAVService = NULL;
    io_service_t selectedService = MACH_PORT_NULL;
    CFDataRef selectedEDID = NULL;
    bool ambiguous = false;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (!isExternalProxy(service)) {
            IOObjectRelease(service);
            continue;
        }
        IOAVServiceRef avService = IOAVServiceCreateWithService(
            kCFAllocatorDefault,
            service
        );
        CFDataRef edid = copyAVServiceEDID(avService);
        if (avService != NULL && edidMatchesDisplay(edid, displayID)) {
            if (selectedAVService == NULL) {
                selectedAVService = avService;
                selectedService = service;
                selectedEDID = edid;
                avService = NULL;
                edid = NULL;
            } else {
                ambiguous = true;
            }
        }
        if (edid != NULL) {
            CFRelease(edid);
        }
        if (avService != NULL) {
            CFRelease(avService);
        }
        if (service != selectedService) {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);

    if (ambiguous || selectedAVService == NULL || selectedEDID == NULL) {
        if (selectedEDID != NULL) {
            CFRelease(selectedEDID);
        }
        if (selectedAVService != NULL) {
            CFRelease(selectedAVService);
        }
        if (selectedService != MACH_PORT_NULL) {
            IOObjectRelease(selectedService);
        }
        return NULL;
    }

    if (chipAddress != NULL && isMCDP29xxProxy(selectedService)) {
        *chipAddress = kMacKVMNativeDDCMCDP29xxChipAddress;
    }
    if (matchedServiceOut != NULL) {
        *matchedServiceOut = selectedService;
    } else {
        IOObjectRelease(selectedService);
    }
    if (edidOut != NULL) {
        *edidOut = selectedEDID;
    } else {
        CFRelease(selectedEDID);
    }
    return selectedAVService;
}

static IOAVServiceRef avServiceForDisplayConnect(
    CGDirectDisplayID displayID,
    uint32_t *chipAddress,
    io_service_t *matchedServiceOut
) {
    if (chipAddress != NULL) {
        *chipAddress = kMacKVMNativeDDCStandardChipAddress;
    }
    if (matchedServiceOut != NULL) {
        *matchedServiceOut = MACH_PORT_NULL;
    }

    CFMutableDictionaryRef matching = IOServiceMatching("IODisplayConnect");
    if (matching == NULL) {
        return NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    ) != KERN_SUCCESS) {
        return NULL;
    }

    // Prefer the complete location-aware match. If the registry omits that
    // location on Apple Silicon, retain at most one identity-only candidate;
    // two identical zero-serial panels are intentionally rejected rather than
    // routing DDC to an arbitrary monitor.
    io_service_t identityOnlyMatch = MACH_PORT_NULL;
    bool identityOnlyAmbiguous = false;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (displayInfoMatches(service, displayID)) {
            IOAVServiceRef result = IOAVServiceCreateWithService(
                kCFAllocatorDefault,
                service
            );
            if (result != NULL) {
                if (chipAddress != NULL && isMCDP29xxProxy(service)) {
                    *chipAddress = kMacKVMNativeDDCMCDP29xxChipAddress;
                }
                if (matchedServiceOut != NULL) {
                    *matchedServiceOut = service;
                } else {
                    IOObjectRelease(service);
                }
                if (identityOnlyMatch != MACH_PORT_NULL) {
                    IOObjectRelease(identityOnlyMatch);
                }
                IOObjectRelease(iterator);
                return result;
            }
            IOObjectRelease(service);
            continue;
        }

        if (displayIdentityMatches(service, displayID)) {
            if (identityOnlyMatch == MACH_PORT_NULL && !identityOnlyAmbiguous) {
                identityOnlyMatch = service;
            } else {
                identityOnlyAmbiguous = true;
                IOObjectRelease(service);
            }
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);

    if (identityOnlyMatch == MACH_PORT_NULL || identityOnlyAmbiguous) {
        if (identityOnlyMatch != MACH_PORT_NULL) {
            IOObjectRelease(identityOnlyMatch);
        }
        return NULL;
    }

    IOAVServiceRef result = IOAVServiceCreateWithService(
        kCFAllocatorDefault,
        identityOnlyMatch
    );
    if (result == NULL) {
        IOObjectRelease(identityOnlyMatch);
        return NULL;
    }
    if (chipAddress != NULL && isMCDP29xxProxy(identityOnlyMatch)) {
        *chipAddress = kMacKVMNativeDDCMCDP29xxChipAddress;
    }
    if (matchedServiceOut != NULL) {
        *matchedServiceOut = identityOnlyMatch;
    } else {
        IOObjectRelease(identityOnlyMatch);
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
    CFDataRef displayEDID,
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
    display->edid = displayEDID == NULL ? NULL : CFRetain(displayEDID);
    display->transport = transport;
    display->chipAddress = chipAddress;
    display->vendorID = CGDisplayVendorNumber(displayID);
    display->productID = CGDisplayModelNumber(displayID);
    display->serialNumber = CGDisplaySerialNumber(displayID);
    if (display->edid == NULL && framebuffer != MACH_PORT_NULL) {
        CFDictionaryRef info = IODisplayCreateInfoDictionary(
            framebuffer,
            kIODisplayOnlyPreferredName
        );
        if (info != NULL) {
            CFTypeRef framebufferEDID = CFDictionaryGetValue(
                info,
                CFSTR(kIODisplayEDIDKey)
            );
            if (framebufferEDID != NULL
                && CFGetTypeID(framebufferEDID) == CFDataGetTypeID()) {
                display->edid = CFRetain((CFDataRef)framebufferEDID);
            }
            CFRelease(info);
        }
    }
    copyDisplayName(display->name, sizeof(display->name), framebuffer, displayID);
    makeIdentifier(
        display->identifier,
        sizeof(display->identifier),
        displayID,
        framebuffer,
        displayEDID
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
        io_service_t framebuffer = framebufferForDisplay(displayID);
        uint32_t chipAddress = kMacKVMNativeDDCStandardChipAddress;
        IOAVServiceRef avService = avServiceForDisplay(displayID, &chipAddress);
        io_service_t matchedDisplayService = MACH_PORT_NULL;
        CFDataRef displayEDID = copyAVServiceEDID(avService);
        if (avService == NULL) {
            avService = avServiceForGlobalProxy(
                displayID,
                &chipAddress,
                &matchedDisplayService,
                &displayEDID
            );
        }
        if (avService == NULL) {
            avService = avServiceForDisplayConnect(
                displayID,
                &chipAddress,
                &matchedDisplayService
            );
            if (avService != NULL) {
                displayEDID = copyAVServiceEDID(avService);
            }
        }
        if (avService != NULL) {
            if (framebuffer == MACH_PORT_NULL
                && matchedDisplayService != MACH_PORT_NULL) {
                framebuffer = matchedDisplayService;
                matchedDisplayService = MACH_PORT_NULL;
            }
            if (!addDisplay(
                list,
                displayID,
                framebuffer,
                avService,
                displayEDID,
                MacKVMNativeDDCTransportAppleSilicon,
                chipAddress
            )) {
                if (framebuffer != MACH_PORT_NULL) {
                    IOObjectRelease(framebuffer);
                }
                CFRelease(avService);
            }
        }
        if (matchedDisplayService != MACH_PORT_NULL) {
            IOObjectRelease(matchedDisplayService);
        }
        if (avService == NULL && framebuffer != MACH_PORT_NULL) {
            IOObjectRelease(framebuffer);
        }
        if (displayEDID != NULL) {
            CFRelease(displayEDID);
        }
#else
        io_service_t framebuffer = framebufferForDisplay(displayID);
        if (intelDisplayHasDDC(framebuffer)) {
            if (!addDisplay(
                list,
                displayID,
                framebuffer,
                NULL,
                NULL,
                MacKVMNativeDDCTransportIntel,
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

MacKVMNativeDDCTransport MacKVMNativeDDCListTransportAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return MacKVMNativeDDCTransportIntel;
    }
    return list->displays[index].transport;
}

uint32_t MacKVMNativeDDCListVendorIDAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return 0;
    }
    return list->displays[index].vendorID;
}

uint32_t MacKVMNativeDDCListProductIDAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return 0;
    }
    return list->displays[index].productID;
}

uint32_t MacKVMNativeDDCListSerialNumberAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count) {
        return 0;
    }
    return list->displays[index].serialNumber;
}

size_t MacKVMNativeDDCListEDIDLengthAt(
    MacKVMNativeDDCListRef list,
    size_t index
) {
    if (list == NULL || index >= list->count
        || list->displays[index].edid == NULL
        || CFGetTypeID(list->displays[index].edid) != CFDataGetTypeID()) {
        return 0;
    }
    CFIndex length = CFDataGetLength(list->displays[index].edid);
    return length > 0 ? (size_t)length : 0;
}

size_t MacKVMNativeDDCCopyEDIDAt(
    MacKVMNativeDDCListRef list,
    size_t index,
    uint8_t *destination,
    size_t destinationCapacity
) {
    size_t length = MacKVMNativeDDCListEDIDLengthAt(list, index);
    if (length == 0 || destination == NULL || destinationCapacity == 0) {
        return length;
    }
    size_t copied = length < destinationCapacity ? length : destinationCapacity;
    CFDataGetBytes(
        list->displays[index].edid,
        CFRangeMake(0, (CFIndex)copied),
        destination
    );
    return copied;
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
        if (display->edid != NULL) {
            CFRelease(display->edid);
            display->edid = NULL;
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
        case 19:
        case 27:
            return true;
        default:
            return false;
    }
}

static void makeVCPWritePacket(
    uint8_t vcpCode,
    uint16_t value,
    uint8_t packet[7]
) {
    packet[0] = 0x51;
    packet[1] = 0x84;
    packet[2] = 0x03;
    packet[3] = vcpCode;
    packet[4] = (uint8_t)(value >> 8);
    packet[5] = (uint8_t)(value & 0xff);
    uint8_t checksum = kMacKVMNativeDDCWriteAddress;
    for (size_t index = 0; index < 6; index += 1) {
        checksum ^= packet[index];
    }
    packet[6] = checksum;
}

static void makeInputPacket(uint32_t inputValue, uint8_t packet[7]) {
    makeVCPWritePacket(
        kMacKVMNativeDDCInputVCP,
        (uint16_t)inputValue,
        packet
    );
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

static IOReturn readAppleSilicon(
    const MacKVMNativeDDCDisplay *display,
    uint8_t vcpCode,
    uint8_t response[12]
) {
    if (display == NULL || display->avService == NULL || response == NULL) {
        return kIOReturnBadArgument;
    }
    uint8_t query[4] = { 0x82, 0x01, vcpCode, 0x00 };
    // IOAVService receives the DDC payload without the I2C data-address byte.
    // Get-VCP reads therefore use the source/write address (0x6E) as the
    // checksum seed; the data address is supplied separately to the I2C call.
    query[3] = kMacKVMNativeDDCWriteAddress
        ^ query[0] ^ query[1] ^ query[2];
    IOReturn result = kIOReturnError;
    for (int attempt = 0; attempt < 3; attempt += 1) {
        usleep(10000);
        result = IOAVServiceWriteI2C(
            display->avService,
            display->chipAddress,
            kMacKVMNativeDDCAddressByte,
            query,
            sizeof(query)
        );
        if (result != kIOReturnSuccess) {
            continue;
        }
        usleep(50000);
        memset(response, 0, 12);
        result = IOAVServiceReadI2C(
            display->avService,
            display->chipAddress,
            // IOAVServiceReadI2C starts at the reply payload offset. The
            // 0x51 DDC data-address byte is already part of the transaction
            // setup/checksum and must not be used as a 0x51-byte reply offset.
            0,
            response,
            12
        );
        if (result == kIOReturnSuccess) {
            return result;
        }
    }
    return result;
}

#else

static bool parseVCPResponse(
    const uint8_t response[12],
    uint8_t vcpCode,
    MacKVMNativeDDCVCPValue *value
);

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

static IOReturn readIntel(
    const MacKVMNativeDDCDisplay *display,
    uint8_t vcpCode,
    uint8_t response[12]
) {
    if (display == NULL || display->framebuffer == MACH_PORT_NULL
        || response == NULL) {
        return kIOReturnBadArgument;
    }
    IOItemCount busCount = 0;
    IOReturn result = IOFBGetI2CInterfaceCount(
        display->framebuffer,
        &busCount
    );
    if (result != kIOReturnSuccess || busCount == 0) {
        return result == kIOReturnSuccess ? kIOReturnNoDevice : result;
    }

    // IOI2C supports two ways of expressing the DDC data address.  Newer
    // Intel framebuffers require the address in sendSubAddress with the
    // sub-address communication flag; older drivers accept the legacy form
    // where 0x51 is included in the send buffer.  Try the standards-based
    // form first, then retain the legacy form as a compatibility fallback.
    uint8_t queryWithSubAddress[4] = { 0x82, 0x01, vcpCode, 0x00 };
    queryWithSubAddress[3] = kMacKVMNativeDDCWriteAddress
        ^ kMacKVMNativeDDCAddressByte
        ^ queryWithSubAddress[0]
        ^ queryWithSubAddress[1]
        ^ queryWithSubAddress[2];
    uint8_t queryWithEmbeddedAddress[5] = {
        kMacKVMNativeDDCAddressByte,
        queryWithSubAddress[0],
        queryWithSubAddress[1],
        queryWithSubAddress[2],
        0x00
    };
    queryWithEmbeddedAddress[4] = kMacKVMNativeDDCWriteAddress
        ^ queryWithEmbeddedAddress[0]
        ^ queryWithEmbeddedAddress[1]
        ^ queryWithEmbeddedAddress[2]
        ^ queryWithEmbeddedAddress[3];
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
        IOReturn openResult = IOI2CInterfaceOpen(
            interface,
            kNilOptions,
            &connection
        );
        IOObjectRelease(interface);
        if (openResult != kIOReturnSuccess || connection == NULL) {
            result = openResult;
            continue;
        }

        const struct {
            const uint8_t *buffer;
            uint32_t bytes;
            IOOptionBits commFlags;
            uint8_t sendSubAddress;
            uint8_t replySubAddress;
        } queryForms[2] = {
            {
                queryWithSubAddress,
                sizeof(queryWithSubAddress),
                kIOI2CUseSubAddressCommFlag,
                kMacKVMNativeDDCAddressByte,
                kMacKVMNativeDDCAddressByte
            },
            {
                queryWithEmbeddedAddress,
                sizeof(queryWithEmbeddedAddress),
                0,
                0,
                kMacKVMNativeDDCAddressByte
            }
        };
        // Prefer Apple's DDC/CI reply transaction because it strips the
        // protocol's embedded length byte; fall back to a simple reply for
        // older Intel framebuffers that only advertise transaction type 1.
        IOOptionBits replyTypes[2] = {
            kIOI2CDDCciReplyTransactionType,
            kIOI2CSimpleTransactionType
        };
        uint32_t receivedBytes = 0;
        bool validResponse = false;
        for (size_t formIndex = 0; formIndex < 2; formIndex += 1) {
            for (size_t typeIndex = 0; typeIndex < 2; typeIndex += 1) {
                memset(response, 0, 12);
                IOI2CRequest request;
                memset(&request, 0, sizeof(request));
                request.sendTransactionType = kIOI2CSimpleTransactionType;
                request.replyTransactionType = replyTypes[typeIndex];
                request.sendAddress = kMacKVMNativeDDCWriteAddress;
                request.replyAddress = 0x6F;
                request.sendSubAddress = queryForms[formIndex].sendSubAddress;
                request.replySubAddress = queryForms[formIndex].replySubAddress;
                request.commFlags = queryForms[formIndex].commFlags;
                request.sendBuffer = (vm_address_t)queryForms[formIndex].buffer;
                request.sendBytes = queryForms[formIndex].bytes;
                request.replyBuffer = (vm_address_t)response;
                request.replyBytes = 12;
                request.minReplyDelay = 50000000;
                request.result = kIOReturnError;

                IOReturn sendResult = IOI2CSendRequest(
                    connection,
                    kNilOptions,
                    &request
                );
                result = sendResult == kIOReturnSuccess
                    ? request.result : sendResult;
                receivedBytes = request.replyBytes;
                if (result == kIOReturnSuccess && receivedBytes >= 10) {
                    MacKVMNativeDDCVCPValue parsedValue;
                    memset(&parsedValue, 0, sizeof(parsedValue));
                    validResponse = parseVCPResponse(
                        response,
                        vcpCode,
                        &parsedValue
                    );
                    if (validResponse) {
                        break;
                    }
                }
            }
            if (validResponse) {
                break;
            }
        }
        IOI2CInterfaceClose(connection, kNilOptions);
        if (validResponse) {
            return result;
        }
    }
    return result;
}

#endif

static IOReturn writeVCP(
    const MacKVMNativeDDCDisplay *display,
    uint8_t vcpCode,
    uint16_t value
) {
    uint8_t packet[7];
    makeVCPWritePacket(vcpCode, value, packet);
#if defined(__arm64__)
    return writeAppleSilicon(display, packet);
#else
    return writeIntel(display, packet);
#endif
}

static IOReturn readVCP(
    const MacKVMNativeDDCDisplay *display,
    uint8_t vcpCode,
    uint8_t response[12]
) {
#if defined(__arm64__)
    return readAppleSilicon(display, vcpCode, response);
#else
    return readIntel(display, vcpCode, response);
#endif
}

static bool parseVCPFrame(
    const uint8_t frame[11],
    uint8_t vcpCode,
    MacKVMNativeDDCVCPValue *value
) {
    if (frame == NULL || value == NULL
        || frame[0] != 0x6E
        || (frame[1] & 0x80) == 0
        || (frame[1] & 0x7F) != 8
        || frame[2] != 0x02
        || frame[3] != 0x00
        || frame[4] != vcpCode) {
        return false;
    }

    // DDC/CI checksums XOR the virtual 0x50 response address with every
    // byte through the current value.  Do not trust a VCP value unless the
    // complete 0x88 VCP-reply frame and its checksum are present.
    uint8_t checksum = 0x50;
    for (size_t index = 0; index < 10; index += 1) {
        checksum ^= frame[index];
    }
    if (checksum != frame[10]) {
        return false;
    }

    value->valueType = frame[5];
    value->maximumValue = ((uint16_t)frame[6] << 8) | frame[7];
    value->currentValue = ((uint16_t)frame[8] << 8) | frame[9];
    return true;
}

static bool parseVCPResponse(
    const uint8_t response[12],
    uint8_t vcpCode,
    MacKVMNativeDDCVCPValue *value
) {
    if (response == NULL || value == NULL) {
        return false;
    }

    // Most transports return the complete eleven-byte frame. Intel's
    // kIOI2CDDCciReplyTransactionType may remove the embedded length byte;
    // reconstruct that byte before applying the same header/checksum checks.
    if (parseVCPFrame(response, vcpCode, value)) {
        return true;
    }
    if (response[0] == 0x6E && response[1] == 0x02) {
        uint8_t compactFrame[11] = { 0 };
        compactFrame[0] = response[0];
        compactFrame[1] = 0x88;
        memcpy(compactFrame + 2, response + 1, 9);
        return parseVCPFrame(compactFrame, vcpCode, value);
    }
    return false;
}

static bool resolveDisplay(
    const char *displayIdentifier,
    MacKVMNativeDDCListRef *listOut,
    MacKVMNativeDDCDisplay **displayOut,
    MacKVMNativeDDCDisplay *cachedRouteOut,
    bool *usingCachedRouteOut,
    char *errorBuffer,
    size_t errorCapacity
) {
    if (listOut == NULL || displayOut == NULL || cachedRouteOut == NULL
        || usingCachedRouteOut == NULL) {
        setError(errorBuffer, errorCapacity, "Invalid display resolution state");
        return false;
    }
    *listOut = NULL;
    *displayOut = NULL;
    *usingCachedRouteOut = false;
    memset(cachedRouteOut, 0, sizeof(*cachedRouteOut));

    if (displayIdentifier == NULL
        || strnlen(displayIdentifier, kMacKVMNativeDDCIdentifierCapacity)
            >= kMacKVMNativeDDCIdentifierCapacity) {
        setError(errorBuffer, errorCapacity, "Invalid display selector");
        return false;
    }

    char discoveryError[256];
    MacKVMNativeDDCListRef list = MacKVMNativeDDCCreateList(
        discoveryError,
        sizeof(discoveryError)
    );
    if (list != NULL) {
        for (size_t index = 0; index < list->count; index += 1) {
            if (identifierMatches(
                displayIdentifier,
                list->displays[index].identifier
            )) {
                *listOut = list;
                *displayOut = &list->displays[index];
                return true;
            }
        }
    }
    if (copyCachedRoute(displayIdentifier, cachedRouteOut)) {
        *listOut = list;
        *displayOut = cachedRouteOut;
        *usingCachedRouteOut = true;
        return true;
    }

    setError(
        errorBuffer,
        errorCapacity,
        "%s",
        discoveryError[0] == '\0'
            ? "The selected display is no longer available"
            : discoveryError
    );
    if (list != NULL) {
        MacKVMNativeDDCReleaseList(list);
    }
    return false;
}

static void releaseResolvedDisplay(
    MacKVMNativeDDCListRef list,
    MacKVMNativeDDCDisplay *display,
    MacKVMNativeDDCDisplay *cachedRoute,
    bool usingCachedRoute
) {
    if (usingCachedRoute && display == cachedRoute) {
        releaseRouteSnapshot(cachedRoute);
    }
    if (list != NULL) {
        MacKVMNativeDDCReleaseList(list);
    }
}

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
    MacKVMNativeDDCDisplay *selected = NULL;
    MacKVMNativeDDCDisplay cachedRoute;
    bool usingCachedRoute = false;
    if (list != NULL) {
        for (size_t index = 0; index < list->count; index += 1) {
            if (identifierMatches(
                displayIdentifier,
                list->displays[index].identifier
            )) {
                selected = &list->displays[index];
                break;
            }
        }
    }
    if (selected == NULL) {
        if (!copyCachedRoute(displayIdentifier, &cachedRoute)) {
            setError(
                errorBuffer,
                errorCapacity,
                "%s",
                discoveryError[0] == '\0'
                    ? "The selected display is no longer available"
                    : discoveryError
            );
            if (list != NULL) {
                MacKVMNativeDDCReleaseList(list);
            }
            return 0;
        }
        selected = &cachedRoute;
        usingCachedRoute = true;
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
        if (usingCachedRoute) {
            clearCachedRoute(displayIdentifier);
            releaseRouteSnapshot(&cachedRoute);
        }
        if (list != NULL) {
            MacKVMNativeDDCReleaseList(list);
        }
        return 0;
    }
    if (!usingCachedRoute) {
        cacheDisplayRoute(selected);
    }
    if (usingCachedRoute) {
        releaseRouteSnapshot(&cachedRoute);
    }
    if (list != NULL) {
        MacKVMNativeDDCReleaseList(list);
    }
    return 1;
}

int MacKVMNativeDDCReadVCP(
    const char *displayIdentifier,
    uint8_t vcpCode,
    MacKVMNativeDDCVCPValue *value,
    char *errorBuffer,
    size_t errorCapacity
) {
    clearError(errorBuffer, errorCapacity);
    if (value == NULL) {
        setError(errorBuffer, errorCapacity, "VCP output is required");
        return 0;
    }
    memset(value, 0, sizeof(*value));

    MacKVMNativeDDCListRef list = NULL;
    MacKVMNativeDDCDisplay *selected = NULL;
    MacKVMNativeDDCDisplay cachedRoute;
    bool usingCachedRoute = false;
    if (!resolveDisplay(
        displayIdentifier,
        &list,
        &selected,
        &cachedRoute,
        &usingCachedRoute,
        errorBuffer,
        errorCapacity
    )) {
        return 0;
    }

    uint8_t response[12] = { 0 };
    IOReturn result = readVCP(selected, vcpCode, response);
    bool parsed = result == kIOReturnSuccess
        && parseVCPResponse(response, vcpCode, value);
    if (!parsed) {
        if (result != kIOReturnSuccess) {
            setIOReturnError(errorBuffer, errorCapacity, "DDC/CI VCP read", result);
        } else {
            setError(
                errorBuffer,
                errorCapacity,
                "DDC/CI VCP 0x%02x returned an invalid reply",
                vcpCode
            );
        }
        // A read can fail transiently while the monitor is showing the
        // newly selected input and disappears from CoreGraphics. Keep a
        // cached native route alive so the diagnostic scanner can still try
        // its final restore write; a write failure clears the route in the
        // write path where it is proven unusable.
        releaseResolvedDisplay(
            list,
            selected,
            &cachedRoute,
            usingCachedRoute
        );
        return 0;
    }
    if (!usingCachedRoute) {
        cacheDisplayRoute(selected);
    }
    releaseResolvedDisplay(
        list,
        selected,
        &cachedRoute,
        usingCachedRoute
    );
    return 1;
}

int MacKVMNativeDDCWriteVCP(
    const char *displayIdentifier,
    uint8_t vcpCode,
    uint16_t value,
    char *errorBuffer,
    size_t errorCapacity
) {
    clearError(errorBuffer, errorCapacity);
    if (vcpCode != kMacKVMNativeDDCInputVCP) {
        setError(
            errorBuffer,
            errorCapacity,
            "Diagnostic writes are limited to input-source VCP 0x%02x",
            kMacKVMNativeDDCInputVCP
        );
        return 0;
    }
    MacKVMNativeDDCListRef list = NULL;
    MacKVMNativeDDCDisplay *selected = NULL;
    MacKVMNativeDDCDisplay cachedRoute;
    bool usingCachedRoute = false;
    if (!resolveDisplay(
        displayIdentifier,
        &list,
        &selected,
        &cachedRoute,
        &usingCachedRoute,
        errorBuffer,
        errorCapacity
    )) {
        return 0;
    }

    IOReturn result = writeVCP(selected, vcpCode, value);
    if (result != kIOReturnSuccess) {
        setIOReturnError(errorBuffer, errorCapacity, "DDC/CI VCP write", result);
        if (usingCachedRoute) {
            clearCachedRoute(displayIdentifier);
        }
        releaseResolvedDisplay(
            list,
            selected,
            &cachedRoute,
            usingCachedRoute
        );
        return 0;
    }
    if (!usingCachedRoute) {
        cacheDisplayRoute(selected);
    }
    releaseResolvedDisplay(
        list,
        selected,
        &cachedRoute,
        usingCachedRoute
    );
    return 1;
}
