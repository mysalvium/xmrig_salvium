/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/crypto/Algorithm.h"


#include <cstring>
#include <iostream>


namespace {


int testAlias(const char *name)
{
    const xmrig::Algorithm algorithm(name);
    int failures = 0;

    if (algorithm != xmrig::Algorithm::RX_0) {
        std::cerr << "FAIL " << name << ": does not resolve to RX_0" << std::endl;
        ++failures;
    }

    if (!algorithm.isValid() || algorithm.family() != xmrig::Algorithm::RANDOM_X) {
        std::cerr << "FAIL " << name << ": is not a valid RandomX algorithm" << std::endl;
        ++failures;
    }

    if (std::strcmp(algorithm.name(), xmrig::Algorithm::kRX_0) != 0) {
        std::cerr << "FAIL " << name << ": canonical name is not rx/0" << std::endl;
        ++failures;
    }

    return failures;
}


} // namespace


int main()
{
    static const char *aliases[] = {
        "rx/salvium",
        "randomx/salvium",
        "randomsalvium",
        "RX/SALVIUM"
    };

    int failures = 0;
    for (const char *alias : aliases) {
        failures += testAlias(alias);
    }

    if (failures != 0) {
        std::cerr << failures << " Salvium RandomX alias assertion(s) failed" << std::endl;
        return 1;
    }

    std::cout << "Salvium aliases resolve to the canonical rx/0 backend" << std::endl;
    return 0;
}
