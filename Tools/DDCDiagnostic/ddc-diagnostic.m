@import CoreFoundation;
@import CoreGraphics;
@import Foundation;

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "MacKVMNativeDDC.h"

enum {
    kDefaultVCPCode = 0x60,
    kMaxInputCandidates = 64,
    kMaxEDIDBytes = 2048
};

typedef struct {
    bool hasDisplay;
    size_t displayNumber;
    bool scanInputs;
    uint8_t vcpCode;
    uint16_t values[kMaxInputCandidates];
    size_t valueCount;
} Options;

typedef struct {
    char manufacturer[4];
    uint16_t productCode;
    uint32_t serialNumber;
    char displayName[14];
    bool validHeader;
    bool validChecksum;
} ParsedEDID;

static const uint16_t defaultInputCandidates[] = {
    15, 16, 17, 18, 19, 20, 21, 22,
    23, 24, 25, 26, 27, 28, 29, 30, 31
};

// Signal handlers may only set an atomic flag. The scan loop observes this
// flag and performs the normal synchronous restore path before returning, so
// Ctrl-C/SIGTERM cannot leave the monitor on an arbitrary candidate input.
static volatile sig_atomic_t inputScanInterrupted = 0;

static void handleInputScanSignal(int signalNumber) {
    (void)signalNumber;
    inputScanInterrupted = 1;
}

static void usage(FILE *stream) {
    fprintf(
        stream,
        "Usage: ddc-diagnostic [options]\n"
        "\n"
        "Read-only options:\n"
        "  --display N       inspect one 1-based display from the list\n"
        "  --vcp CODE        read a VCP code (default: 0x60 input source)\n"
        "  --help            show this help\n"
        "\n"
        "Opt-in input mapping scan:\n"
        "  --scan-inputs     write candidates, read them back, then restore\n"
        "  --values LIST     comma-separated decimal/hex values for the scan\n"
        "\n"
        "The scan changes the monitor input temporarily. Use it only when the\n"
        "display is safe to switch and the original input can be restored.\n"
    );
}

static bool parseUnsigned(
    const char *text,
    unsigned long maximum,
    unsigned long *value
) {
    if (text == NULL || text[0] == '\0' || value == NULL) {
        return false;
    }
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 0);
    if (errno != 0 || end == text || end == NULL || end[0] != '\0'
        || parsed > maximum) {
        return false;
    }
    *value = parsed;
    return true;
}

static bool parseValues(const char *text, Options *options) {
    if (text == NULL || options == NULL) {
        return false;
    }
    char *copy = strdup(text);
    if (copy == NULL) {
        return false;
    }
    size_t count = 0;
    char *cursor = copy;
    while (cursor != NULL && cursor[0] != '\0') {
        char *separator = strchr(cursor, ',');
        if (separator != NULL) {
            *separator = '\0';
        }
        unsigned long value = 0;
        if (count >= kMaxInputCandidates
            || !parseUnsigned(cursor, UINT16_MAX, &value)) {
            free(copy);
            return false;
        }
        options->values[count] = (uint16_t)value;
        count += 1;
        cursor = separator == NULL ? NULL : separator + 1;
    }
    free(copy);
    options->valueCount = count;
    return count > 0;
}

static bool parseOptions(int argc, char **argv, Options *options) {
    if (options == NULL) {
        return false;
    }
    memset(options, 0, sizeof(*options));
    options->vcpCode = kDefaultVCPCode;
    for (size_t index = 0;
         index < sizeof(defaultInputCandidates) / sizeof(defaultInputCandidates[0]);
         index += 1) {
        options->values[index] = defaultInputCandidates[index];
    }
    options->valueCount = sizeof(defaultInputCandidates)
        / sizeof(defaultInputCandidates[0]);

    for (int index = 1; index < argc; index += 1) {
        const char *argument = argv[index];
        if (strcmp(argument, "--help") == 0 || strcmp(argument, "-h") == 0) {
            usage(stdout);
            exit(EXIT_SUCCESS);
        }
        if (strcmp(argument, "--scan-inputs") == 0) {
            options->scanInputs = true;
            continue;
        }
        if (strcmp(argument, "--display") == 0 || strcmp(argument, "--vcp") == 0
            || strcmp(argument, "--values") == 0) {
            if (index + 1 >= argc) {
                fprintf(stderr, "%s requires a value.\n", argument);
                return false;
            }
            const char *valueText = argv[++index];
            if (strcmp(argument, "--display") == 0) {
                unsigned long value = 0;
                if (!parseUnsigned(valueText, SIZE_MAX, &value) || value == 0) {
                    fprintf(stderr, "Invalid --display value: %s\n", valueText);
                    return false;
                }
                options->hasDisplay = true;
                options->displayNumber = (size_t)value;
            } else if (strcmp(argument, "--vcp") == 0) {
                unsigned long value = 0;
                if (!parseUnsigned(valueText, UINT8_MAX, &value)) {
                    fprintf(stderr, "Invalid --vcp value: %s\n", valueText);
                    return false;
                }
                options->vcpCode = (uint8_t)value;
            } else if (!parseValues(valueText, options)) {
                fprintf(stderr, "Invalid --values list: %s\n", valueText);
                return false;
            }
            continue;
        }
        fprintf(stderr, "Unknown option: %s\n", argument);
        return false;
    }
    return true;
}

static void sysctlString(
    const char *name,
    char *destination,
    size_t capacity,
    const char *fallback
) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    destination[0] = '\0';
    size_t size = capacity;
    if (name != NULL
        && sysctlbyname(name, destination, &size, NULL, 0) == 0
        && destination[0] != '\0') {
        destination[capacity - 1] = '\0';
        return;
    }
    snprintf(destination, capacity, "%s", fallback == NULL ? "unknown" : fallback);
    destination[capacity - 1] = '\0';
}

static const char *compiledArchitecture(void) {
#if defined(__arm64__) || defined(__aarch64__)
    return "arm64";
#elif defined(__x86_64__)
    return "x86_64";
#else
    return "unknown";
#endif
}

static void printSystemInfo(void) {
    char model[128];
    char machine[128];
    char osVersion[128];
    char osBuild[128];
    sysctlString("hw.model", model, sizeof(model), "unknown");
    sysctlString("hw.machine", machine, sizeof(machine), "unknown");
    sysctlString(
        "kern.osproductversion",
        osVersion,
        sizeof(osVersion),
        "unknown"
    );
    sysctlString("kern.osversion", osBuild, sizeof(osBuild), "unknown");
    printf("MacKVM Native DDC diagnostic\n");
    printf("system.architecture=%s\n", machine);
    printf("system.compiled_architecture=%s\n", compiledArchitecture());
    printf("system.model=%s\n", model);
    printf("system.os_version=%s\n", osVersion);
    printf("system.os_build=%s\n", osBuild);
}

static void parseEDID(
    const uint8_t *edid,
    size_t length,
    ParsedEDID *parsed
) {
    if (parsed == NULL) {
        return;
    }
    memset(parsed, 0, sizeof(*parsed));
    snprintf(parsed->manufacturer, sizeof(parsed->manufacturer), "???");
    snprintf(parsed->displayName, sizeof(parsed->displayName), "unknown");
    if (edid == NULL || length < 128) {
        return;
    }
    static const uint8_t header[8] = {
        0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00
    };
    parsed->validHeader = memcmp(edid, header, sizeof(header)) == 0;
    uint16_t manufacturerCode = ((uint16_t)edid[8] << 8) | edid[9];
    parsed->manufacturer[0] = (char)('A' + ((manufacturerCode >> 10) & 0x1f) - 1);
    parsed->manufacturer[1] = (char)('A' + ((manufacturerCode >> 5) & 0x1f) - 1);
    parsed->manufacturer[2] = (char)('A' + (manufacturerCode & 0x1f) - 1);
    parsed->manufacturer[3] = '\0';
    parsed->productCode = (uint16_t)edid[10] | ((uint16_t)edid[11] << 8);
    parsed->serialNumber = (uint32_t)edid[12]
        | ((uint32_t)edid[13] << 8)
        | ((uint32_t)edid[14] << 16)
        | ((uint32_t)edid[15] << 24);
    parsed->validChecksum = true;
    size_t blockCount = length / 128;
    for (size_t block = 0; block < blockCount; block += 1) {
        uint8_t checksum = 0;
        for (size_t byte = 0; byte < 128; byte += 1) {
            checksum = (uint8_t)(checksum + edid[block * 128 + byte]);
        }
        if (checksum != 0) {
            parsed->validChecksum = false;
        }
    }
    for (size_t descriptor = 0; descriptor < 4; descriptor += 1) {
        size_t offset = 54 + descriptor * 18;
        if (offset + 18 > length
            || edid[offset] != 0x00
            || edid[offset + 1] != 0x00
            || edid[offset + 2] != 0x00
            || edid[offset + 3] != 0xFC) {
            continue;
        }
        size_t output = 0;
        for (size_t byte = 5; byte < 18 && output + 1 < sizeof(parsed->displayName); byte += 1) {
            uint8_t character = edid[offset + byte];
            if (character == 0x0a || character == 0x00) {
                break;
            }
            if (character >= 0x20 && character <= 0x7e) {
                parsed->displayName[output++] = (char)character;
            }
        }
        parsed->displayName[output] = '\0';
    }
}

static const char *transportName(MacKVMNativeDDCTransport transport) {
    return transport == MacKVMNativeDDCTransportAppleSilicon
        ? "Apple Silicon IOAVService"
        : "Intel IOFramebuffer/IOI2C";
}

static const char *inputLabel(uint16_t value) {
    switch (value) {
        case 15: return "DisplayPort 1";
        case 16: return "DisplayPort 2";
        case 17: return "HDMI 1";
        case 18: return "HDMI 2";
        case 19: return "USB-C (MA270U observed)";
        default: return "unknown / monitor-specific";
    }
}

static void printEDID(const uint8_t *edid, size_t length) {
    ParsedEDID parsed;
    parseEDID(edid, length, &parsed);
    printf("  edid.length=%zu\n", length);
    printf("  edid.header_valid=%s\n", parsed.validHeader ? "yes" : "no");
    printf("  edid.checksum_valid=%s\n", parsed.validChecksum ? "yes" : "no");
    printf("  edid.manufacturer=%s\n", parsed.manufacturer);
    printf("  edid.product_id=%u (0x%04x)\n",
           parsed.productCode,
           parsed.productCode);
    printf("  edid.serial=%u (0x%08x)\n",
           parsed.serialNumber,
           parsed.serialNumber);
    printf("  edid.display_name=%s\n", parsed.displayName);
}

static bool readVCP(
    const char *selector,
    uint8_t code,
    MacKVMNativeDDCVCPValue *value,
    char *error,
    size_t errorCapacity
) {
    return selector != NULL
        && MacKVMNativeDDCReadVCP(
            selector,
            code,
            value,
            error,
            errorCapacity
        ) != 0;
}

static bool writeVCP(
    const char *selector,
    uint8_t code,
    uint16_t value,
    char *error,
    size_t errorCapacity
) {
    return selector != NULL
        && MacKVMNativeDDCWriteVCP(
            selector,
            code,
            value,
            error,
            errorCapacity
        ) != 0;
}

static void waitForMonitor(void) {
    usleep(150000);
}

static void scanInputMapping(
    const char *selector,
    const Options *options,
    const MacKVMNativeDDCVCPValue *initial
) {
    inputScanInterrupted = 0;
    struct sigaction action;
    struct sigaction previousInterrupt;
    struct sigaction previousTermination;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handleInputScanSignal;
    sigemptyset(&action.sa_mask);
    bool interruptHandlerInstalled =
        sigaction(SIGINT, &action, &previousInterrupt) == 0;
    bool terminationHandlerInstalled =
        sigaction(SIGTERM, &action, &previousTermination) == 0;

    uint16_t acceptedValues[kMaxInputCandidates] = { 0 };
    size_t acceptedCount = 0;
    printf("  input_scan.warning=This scan writes VCP 0x60 and changes the monitor input temporarily.\n");
    printf("  input_scan.initial=%u (%s)\n",
           initial->currentValue,
           inputLabel(initial->currentValue));
    for (size_t index = 0;
         index < options->valueCount && !inputScanInterrupted;
         index += 1) {
        uint16_t candidate = options->values[index];
        char error[512] = { 0 };
        bool wrote = writeVCP(
            selector,
            kDefaultVCPCode,
            candidate,
            error,
            sizeof(error)
        );
        if (!wrote) {
            printf("  input_scan.value=%u label=%s write=failed error=%s\n",
                   candidate,
                   inputLabel(candidate),
                   error[0] == '\0' ? "unknown" : error);
            continue;
        }
        if (inputScanInterrupted) {
            break;
        }
        waitForMonitor();
        if (inputScanInterrupted) {
            break;
        }
        MacKVMNativeDDCVCPValue reply;
        memset(&reply, 0, sizeof(reply));
        bool read = false;
        for (int attempt = 0;
             attempt < 3 && !read && !inputScanInterrupted;
             attempt += 1) {
            char readError[512] = { 0 };
            read = readVCP(
                selector,
                kDefaultVCPCode,
                &reply,
                readError,
                sizeof(readError)
            );
            if (!read) {
                waitForMonitor();
            }
        }
        if (!read) {
            printf("  input_scan.value=%u label=%s write=ok readback=unavailable\n",
                   candidate,
                   inputLabel(candidate));
        } else {
            if (reply.currentValue == candidate
                && acceptedCount < kMaxInputCandidates) {
                acceptedValues[acceptedCount++] = candidate;
            }
            printf("  input_scan.value=%u label=%s write=ok readback=%u accepted=%s\n",
                   candidate,
                   inputLabel(candidate),
                   reply.currentValue,
                   reply.currentValue == candidate ? "yes" : "no");
        }
    }

    if (inputScanInterrupted) {
        printf("  input_scan.interrupted=yes\n");
    }
    char restoreError[512] = { 0 };
    bool restored = writeVCP(
        selector,
        kDefaultVCPCode,
        initial->currentValue,
        restoreError,
        sizeof(restoreError)
    );
    if (restored) {
        waitForMonitor();
        printf("  input_scan.restored=%u (%s)\n",
               initial->currentValue,
               inputLabel(initial->currentValue));
    } else {
        printf("  input_scan.restore=failed error=%s\n",
               restoreError[0] == '\0' ? "unknown" : restoreError);
    }
    if (terminationHandlerInstalled) {
        sigaction(SIGTERM, &previousTermination, NULL);
    }
    if (interruptHandlerInstalled) {
        sigaction(SIGINT, &previousInterrupt, NULL);
    }
    printf("  input_scan.mapping=");
    if (acceptedCount == 0) {
        printf("none confirmed\n");
    } else {
        for (size_t index = 0; index < acceptedCount; index += 1) {
            if (index > 0) {
                printf(",");
            }
            printf("%u (0x%02x) %s",
                   acceptedValues[index],
                   acceptedValues[index],
                   inputLabel(acceptedValues[index]));
        }
        printf("\n");
    }
}

static void printDisplay(
    MacKVMNativeDDCListRef list,
    size_t index,
    const Options *options
) {
    const char *name = MacKVMNativeDDCListNameAt(list, index);
    const char *selector = MacKVMNativeDDCListIdentifierAt(list, index);
    if (name == NULL) {
        return;
    }
    bool selectorAvailable = selector != NULL && selector[0] != '\0';
    MacKVMNativeDDCTransport transport = MacKVMNativeDDCListTransportAt(
        list,
        index
    );
    uint32_t vendor = MacKVMNativeDDCListVendorIDAt(list, index);
    uint32_t product = MacKVMNativeDDCListProductIDAt(list, index);
    uint32_t serial = MacKVMNativeDDCListSerialNumberAt(list, index);
    size_t edidLength = MacKVMNativeDDCListEDIDLengthAt(list, index);
    uint8_t edid[kMaxEDIDBytes];
    size_t copiedEDID = 0;
    if (edidLength > 0) {
        copiedEDID = MacKVMNativeDDCCopyEDIDAt(
            list,
            index,
            edid,
            sizeof(edid)
        );
    }

    printf("display[%zu]\n", index + 1);
    printf("  name=%s\n", name);
    printf("  selector=%s\n",
           selectorAvailable ? selector : "ambiguous (identical display identity)");
    printf("  transport=%s\n", transportName(transport));
    printf("  vendor_id=%u (0x%04x)\n", vendor, vendor);
    printf("  product_id=%u (0x%04x)\n", product, product);
    printf("  serial=%u (0x%08x)\n", serial, serial);
    if (copiedEDID > 0) {
        printEDID(edid, copiedEDID);
    } else {
        printf("  edid=unavailable\n");
    }
    if (vendor == 2513 && product == 32884) {
        printf("  mapping.known_model=BenQ MA270U (hardware-observed)\n");
        printf("  mapping.known_values=HDMI 1=17 (0x11), USB-C=19 (0x13)\n");
    } else {
        printf("  mapping.known_model=none; use --scan-inputs to verify values\n");
    }

    if (!selectorAvailable) {
        printf("  mapping.status=unavailable until the display has a unique selector\n");
        printf("  vcp=unavailable (ambiguous display selector)\n");
        return;
    }

    char error[512] = { 0 };
    MacKVMNativeDDCVCPValue current;
    memset(&current, 0, sizeof(current));
    bool read = readVCP(
        selector,
        options->vcpCode,
        &current,
        error,
        sizeof(error)
    );
    if (!read) {
        printf("  vcp.0x%02x=unavailable error=%s\n",
               options->vcpCode,
               error[0] == '\0' ? "unknown" : error);
        return;
    }
    printf("  vcp.0x%02x.type=%u\n", options->vcpCode, current.valueType);
    printf("  vcp.0x%02x.current=%u\n", options->vcpCode, current.currentValue);
    printf("  vcp.0x%02x.maximum=%u\n", options->vcpCode, current.maximumValue);
    if (options->scanInputs) {
        if (options->vcpCode != kDefaultVCPCode) {
            printf("  input_scan=skipped (scan always targets VCP 0x60)\n");
        } else if (current.currentValue > UINT8_MAX) {
            printf("  input_scan=skipped (current input value cannot be restored safely)\n");
        } else {
            scanInputMapping(selector, options, &current);
        }
    }
}

int main(int argc, char **argv) {
    Options options;
    if (!parseOptions(argc, argv, &options)) {
        usage(stderr);
        return EXIT_FAILURE;
    }
    printSystemInfo();

    char error[512] = { 0 };
    MacKVMNativeDDCListRef list = MacKVMNativeDDCCreateList(
        error,
        sizeof(error)
    );
    if (list == NULL) {
        fprintf(stderr, "display_discovery=failed error=%s\n",
                error[0] == '\0' ? "unknown" : error);
        return EXIT_FAILURE;
    }
    size_t count = MacKVMNativeDDCListCount(list);
    printf("display_count=%zu\n", count);
    if (count == 0) {
        fprintf(stderr, "No native DDC/CI display was found.\n");
        MacKVMNativeDDCReleaseList(list);
        return EXIT_FAILURE;
    }
    if (options.hasDisplay && options.displayNumber > count) {
        fprintf(stderr, "--display %zu is outside the detected range 1..%zu.\n",
                options.displayNumber,
                count);
        MacKVMNativeDDCReleaseList(list);
        return EXIT_FAILURE;
    }
    if (options.scanInputs && !options.hasDisplay && count > 1) {
        fprintf(stderr, "--scan-inputs requires --display when multiple displays are detected.\n");
        MacKVMNativeDDCReleaseList(list);
        return EXIT_FAILURE;
    }

    if (options.hasDisplay) {
        printDisplay(list, options.displayNumber - 1, &options);
    } else {
        for (size_t index = 0; index < count; index += 1) {
            printDisplay(list, index, &options);
        }
    }
    MacKVMNativeDDCReleaseList(list);
    return EXIT_SUCCESS;
}
