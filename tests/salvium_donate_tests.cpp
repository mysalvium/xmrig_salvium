/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/*
 * Donation-layer regression tests.
 *
 * Spec: on the donation layer a user may fully opt out of the dev donation by
 * setting "donate-level": 0 in the config, and that value must be stored and
 * reported by Pools (kMinimumDonateLevel == 0). The shipped default stays 1%.
 *
 * The donate level is driven through the public Pools::load() path — the same
 * path config.json takes; the private setDonateLevel() is exercised through it.
 * A "pools" array must be present or load() returns before reading the level.
 *
 * These expectations hold only where kMinimumDonateLevel == 0, so this test
 * belongs to the `donation` branch (and reaches `combined` via merge). It must
 * never be added to `salvium`, which keeps the upstream minimum of 1.
 */

#include "3rdparty/rapidjson/document.h"
#include "base/io/json/Json.h"
#include "base/net/stratum/Pools.h"


#include <iostream>


namespace {


int loadedDonateLevel(const char *json)
{
    rapidjson::Document doc;
    doc.Parse(json);

    xmrig::Pools pools;
    pools.load(xmrig::JsonReader(doc));

    return pools.donateLevel();
}


// The shipped default is 1% (spec: the opt-out must not change the default).
// This also proves the later == 0 assertions are not vacuously true.
int testDefaultDonateLevel()
{
    int failures = 0;

    const xmrig::Pools pools;

    if (pools.donateLevel() != 1) {
        std::cerr << "FAIL constructed donate level is " << pools.donateLevel() << ", expected 1" << std::endl;
        ++failures;
    }

    const int level = loadedDonateLevel(R"({"pools": []})");

    if (level != 1) {
        std::cerr << "FAIL config without donate-level loaded as " << level << ", expected default 1" << std::endl;
        ++failures;
    }

    return failures;
}


// A user-set 0 must be honored: donateLevel() == 0 means Network never creates
// a DonateStrategy (src/net/Network.cpp) and the banner prints 0%.
int testConfigDonateLevelZeroIsHonored()
{
    const int level = loadedDonateLevel(R"({"donate-level": 0, "pools": []})");

    if (level != 0) {
        std::cerr << "FAIL config donate-level 0 loaded as " << level << ", expected 0" << std::endl;
        return 1;
    }

    return 0;
}


// Out-of-range values must still be rejected (0 is the minimum, 99 the maximum)
// and a valid non-zero value must still be accepted.
int testOutOfRangeLevelsRejected()
{
    int failures = 0;

    const int below = loadedDonateLevel(R"({"donate-level": -1, "pools": []})");

    if (below != 1) {
        std::cerr << "FAIL config donate-level -1 loaded as " << below << ", expected default 1" << std::endl;
        ++failures;
    }

    const int above = loadedDonateLevel(R"({"donate-level": 100, "pools": []})");

    if (above != 1) {
        std::cerr << "FAIL config donate-level 100 loaded as " << above << ", expected default 1" << std::endl;
        ++failures;
    }

    const int valid = loadedDonateLevel(R"({"donate-level": 5, "pools": []})");

    if (valid != 5) {
        std::cerr << "FAIL config donate-level 5 loaded as " << valid << ", expected 5" << std::endl;
        ++failures;
    }

    return failures;
}


} // namespace


int main()
{
    int failures = 0;

    failures += testDefaultDonateLevel();
    failures += testConfigDonateLevelZeroIsHonored();
    failures += testOutOfRangeLevelsRejected();

    if (failures == 0) {
        std::cout << "OK donation donate-level tests passed" << std::endl;
    }

    return failures;
}
