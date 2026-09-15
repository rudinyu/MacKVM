namespace WindowsKVM.Protocol;

/// <summary>
/// The stable Apple virtual keycode to Windows virtual-key mapping used by
/// SendInput. Keeping this table in the protocol assembly makes the mapping
/// independently testable and prevents navigation/function-key drift.
/// </summary>
public readonly record struct MacVirtualKeyMapping(ushort VirtualKey, bool Extended);

public static class MacVirtualKeyMap
{
    private static readonly IReadOnlyDictionary<ushort, MacVirtualKeyMapping> Map =
        new Dictionary<ushort, MacVirtualKeyMapping>
        {
            // ANSI letters, digits and symbols.
            [0] = new(0x41, false), [1] = new(0x53, false),
            [2] = new(0x44, false), [3] = new(0x46, false),
            [4] = new(0x48, false), [5] = new(0x47, false),
            [6] = new(0x5A, false), [7] = new(0x58, false),
            [8] = new(0x43, false), [9] = new(0x56, false),
            [11] = new(0x42, false), [12] = new(0x51, false),
            [13] = new(0x57, false), [14] = new(0x45, false),
            [15] = new(0x52, false), [16] = new(0x59, false),
            [17] = new(0x54, false), [18] = new(0x31, false),
            [19] = new(0x32, false), [20] = new(0x33, false),
            [21] = new(0x34, false), [22] = new(0x36, false),
            [23] = new(0x35, false), [24] = new(0xBB, false),
            [25] = new(0x39, false), [26] = new(0x37, false),
            [27] = new(0xBD, false), [28] = new(0x38, false),
            [29] = new(0x30, false), [30] = new(0xDD, false),
            [31] = new(0x4F, false), [32] = new(0x55, false),
            [33] = new(0xDB, false), [34] = new(0x49, false),
            [35] = new(0x50, false), [36] = new(0x0D, false),
            [37] = new(0x4C, false), [38] = new(0x4A, false),
            [39] = new(0xDE, false), [40] = new(0x4B, false),
            [41] = new(0xBA, false), [42] = new(0xDC, false),
            [43] = new(0xBC, false), [44] = new(0xBF, false),
            [45] = new(0x4E, false), [46] = new(0x4D, false),
            [47] = new(0xBE, false), [48] = new(0x09, false),
            [49] = new(0x20, false), [50] = new(0xC0, false),
            [51] = new(0x08, false), [53] = new(0x1B, false),

            // Function keys. Apple keycodes are intentionally non-sequential.
            [64] = new(0x80, false), [79] = new(0x81, false),
            [80] = new(0x82, false), [90] = new(0x83, false),
            [96] = new(0x74, false), [97] = new(0x75, false),
            [98] = new(0x76, false), [99] = new(0x72, false),
            [100] = new(0x77, false), [101] = new(0x78, false),
            [103] = new(0x7A, false), [105] = new(0x7C, false),
            [106] = new(0x7F, false), [107] = new(0x7D, false),
            [109] = new(0x79, false), [111] = new(0x7B, false),
            [113] = new(0x7E, false), [118] = new(0x73, false),
            [120] = new(0x71, false), [122] = new(0x70, false),

            // Navigation and editing keys.
            [115] = new(0x24, true),  // Home
            [116] = new(0x21, true),  // Page Up
            [117] = new(0x2E, true),  // Forward Delete
            [119] = new(0x23, true),  // End
            [121] = new(0x22, true),  // Page Down
            [123] = new(0x25, true),  // Left
            [124] = new(0x27, true),  // Right
            [125] = new(0x28, true),  // Down
            [126] = new(0x26, true),  // Up

            // Keypad keys.
            [65] = new(0x6E, false), [67] = new(0x6A, false),
            [69] = new(0x6B, false), [71] = new(0x90, false),
            [75] = new(0x6F, false), [76] = new(0x0D, true),
            [78] = new(0x6D, false), [81] = new(0xBB, false),
            [82] = new(0x60, false), [83] = new(0x61, false),
            [84] = new(0x62, false), [85] = new(0x63, false),
            [86] = new(0x64, false), [87] = new(0x65, false),
            [88] = new(0x66, false), [89] = new(0x67, false),
            [91] = new(0x68, false), [92] = new(0x69, false)
        };

    private static readonly IReadOnlyDictionary<ushort, MacVirtualKeyMapping> ModifierMap =
        new Dictionary<ushort, MacVirtualKeyMapping>
        {
            [54] = new(0x5C, true), // Right Command
            [55] = new(0x5B, true), // Left Command
            [56] = new(0xA0, false), // Left Shift
            [60] = new(0xA1, false), // Right Shift
            [58] = new(0xA4, true), // Left Option
            [61] = new(0xA5, true), // Right Option
            [59] = new(0xA2, true), // Left Control
            [62] = new(0xA3, true), // Right Control
            [57] = new(0x14, false) // Caps Lock
        };

    public static bool TryGet(ushort keyCode, out MacVirtualKeyMapping mapping)
        => ModifierMap.TryGetValue(keyCode, out mapping)
            || Map.TryGetValue(keyCode, out mapping);

    public static bool TryGetModifier(ushort keyCode, out MacVirtualKeyMapping mapping)
        => ModifierMap.TryGetValue(keyCode, out mapping);
}
