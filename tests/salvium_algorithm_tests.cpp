/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/crypto/Algorithm.h"
#include "base/crypto/Coin.h"


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


int testDisplayNames()
{
    const xmrig::Algorithm randomX(xmrig::Algorithm::RX_0);
    const xmrig::Algorithm randomWow(xmrig::Algorithm::RX_WOW);
    const xmrig::Coin salvium(xmrig::Coin::SALVIUM);
    const xmrig::Coin monero(xmrig::Coin::MONERO);
    int failures = 0;

    if (std::strcmp(salvium.displayAlgorithmName(randomX), "rx/salvium") != 0) {
        std::cerr << "FAIL SAL RX_0 display name is not rx/salvium" << std::endl;
        ++failures;
    }

    if (xmrig::Algorithm(salvium.displayAlgorithmName(randomX)) != xmrig::Algorithm::RX_0) {
        std::cerr << "FAIL SAL display name does not resolve to RX_0" << std::endl;
        ++failures;
    }

    if (std::strcmp(monero.displayAlgorithmName(randomX), xmrig::Algorithm::kRX_0) != 0) {
        std::cerr << "FAIL non-SAL RX_0 display name changed" << std::endl;
        ++failures;
    }

    if (std::strcmp(salvium.displayAlgorithmName(randomWow), xmrig::Algorithm::kRX_WOW) != 0) {
        std::cerr << "FAIL non-RX_0 Salvium display name changed" << std::endl;
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

    failures += testDisplayNames();

    if (failures != 0) {
        std::cerr << failures << " Salvium RandomX alias assertion(s) failed" << std::endl;
        return 1;
    }

    std::cout << "Salvium aliases and display branding preserve the canonical rx/0 backend" << std::endl;
    return 0;
}
