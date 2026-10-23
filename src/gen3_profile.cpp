#include "profile.h"

namespace gen3 {
const Profile& game_profile() {
#if defined(GEN3_VARIANT_FIRERED)
    // firered USA rev0: variants/firered/symbols/imported*_symbols.tsv.
    // Map-group pointer independently checked in the ROM lookup literal.
    static constexpr Profile profile{
        "firered", true, 0x030030F0, 0x080565B4, 0x02036DFC,
        0x03005040, 0x03005008, 0x03000E90, 0x083526A8, true,
        0x02036E38, 0x0202063C, 0x02021BC8, 0x02021BCA, 0x020204B4,
        0x0835B5D8, 33, 0x0839FDB0, 0x0839FD5D, 0x083A640C,
        0x083A707C, 0x083A5330, 0x02037098, 0x0203709A, 152,
        81, 0x8E0, 0xEE0, 0x1000, 0x900,
        0x020370E0, 0, 0, 0
    };
#elif defined(GEN3_VARIANT_LEAFGREEN)
    // leafgreen USA rev0: variants/leafgreen/symbols/imported*_symbols.tsv.
    // Map-group pointer independently checked in the ROM lookup literal.
    static constexpr Profile profile{
        "leafgreen", true, 0x030030F0, 0x080565B4, 0x02036DFC,
        0x03005040, 0x03005008, 0x03000E90, 0x08352688, true,
        0x02036E38, 0x0202063C, 0x02021BC8, 0x02021BCA, 0x020204B4,
        0x0835B5B8, 33, 0x0839FD90, 0x0839FD3D, 0x083A63EC,
        0x083A705C, 0x083A5310, 0x02037098, 0x0203709A, 152,
        81, 0x8E0, 0xEE0, 0x1000, 0x900,
        0x020370E0, 0, 0, 0
    };
#else
#error Select a reviewed Gen III ROM profile
#endif
    return profile;
}
}
