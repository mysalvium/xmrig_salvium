/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/net/stratum/SoloEffort.h"


#include <cmath>
#include <iostream>
#include <string>


namespace {


constexpr double kEpsilon = 1.0e-12;


class Test
{
public:
    void expect(bool condition, const std::string &message)
    {
        if (!condition) {
            std::cerr << "FAIL: " << message << std::endl;
            ++m_failures;
        }
    }

    void expectNear(double actual, double expected, const std::string &message)
    {
        expect(std::fabs(actual - expected) <= kEpsilon, message);
    }

    int failures() const
    {
        return m_failures;
    }

private:
    int m_failures = 0;
};


void testUnitEffort(Test &test)
{
    xmrig::SoloEffort effort;
    constexpr uint64_t difficulty = 400;

    effort.onJob(difficulty);
    effort.addHashes(difficulty);
    test.expectNear(effort.currentEffort(), 1.0, "one difficulty of hashes must equal unit effort");

    effort.addHashes(2 * difficulty);
    test.expectNear(effort.currentEffort(), 3.0, "additional hashes must accumulate on the current job");
}


void testPiecewiseDifficulty(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(100);
    effort.addHashes(50);
    effort.onJob(200);
    effort.addHashes(100);

    test.expectNear(effort.currentEffort(), 1.0, "each hash interval must use its own job difficulty");
}


void testNetworkJobsDoNotReset(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(100);
    effort.addHashes(25);
    effort.onJob(200);
    effort.addHashes(100);
    effort.onJob(50);
    effort.addHashes(25);

    test.expectNear(effort.currentEffort(), 1.25, "network job changes must preserve accumulated effort");
}


void testMeasuredHashrateFeedsLiveEffort(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(1000);
    effort.sampleHashrate(10000, 250.0, true);
    effort.sampleHashrate(12000, 250.0, true);
    test.expectNear(effort.currentEffort(), 0.5,
                    "sampled production hashrate must accumulate effort between block submissions");

    effort.onJob(2000);
    effort.sampleHashrate(13000, 500.0, true);
    test.expectNear(effort.currentEffort(), 0.75,
                    "sampled hashrate must use the difficulty active for each interval");

    effort.onOwnBlockFound(42, 3000);
    test.expectNear(effort.history().back().effort, 0.75,
                    "a recorded solve must retain the measured, nonconstant effort");
}


void testInactiveHashrateIntervalsAreExcluded(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(100);
    effort.sampleHashrate(1000, 100.0, true);
    effort.sampleHashrate(2000, 100.0, false);
    test.expectNear(effort.currentEffort(), 0.0,
                    "paused, donation, and non-daemon intervals must not contribute solo effort");

    effort.sampleHashrate(3000, 100.0, true);
    test.expectNear(effort.currentEffort(), 1.0,
                    "solo effort sampling must resume from the last inactive boundary");
}


void testOwnBlockResets(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(200);
    effort.addHashes(150);
    effort.onOwnBlockFound(123456, 7890);

    test.expectNear(effort.currentEffort(), 0.0, "an accepted own block must reset current effort");
    test.expect(effort.blocksFound() == 1, "an accepted own block must increment blocksFound");
    test.expect(effort.history().size() == 1, "an accepted own block must enter solve history");

    if (!effort.history().empty()) {
        const auto &solve = effort.history().back();
        test.expect(solve.height == 123456, "solve history must retain block height");
        test.expect(solve.elapsedMs == 7890, "solve history must retain elapsed milliseconds");
        test.expectNear(solve.effort, 0.75, "solve history must retain effort before reset");
    }
}


void testAverageEffort(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(100);
    effort.addHashes(50);
    effort.onOwnBlockFound(1, 1000);

    effort.onJob(200);
    effort.addHashes(300);
    effort.onOwnBlockFound(2, 2000);

    test.expectNear(effort.avgEffort(), 1.0, "average effort must be the mean of all recorded solves");
}


void testBoundedHistory(Test &test)
{
    xmrig::SoloEffort effort;
    const uint64_t solveCount = xmrig::SoloEffort::kHistorySize + 3;

    for (uint64_t height = 1; height <= solveCount; ++height) {
        effort.onJob(10);
        effort.addHashes(height);
        effort.onOwnBlockFound(height, height * 100);
    }

    test.expect(effort.blocksFound() == solveCount, "blocksFound must remain an unbounded all-time counter");
    test.expect(effort.history().size() == xmrig::SoloEffort::kHistorySize, "solve history must be capped at kHistorySize");

    if (!effort.history().empty()) {
        test.expect(effort.history().front().height == 4, "bounded history must evict the oldest solves");
        test.expect(effort.history().back().height == solveCount, "bounded history must retain the newest solve");
        test.expect(effort.history().back().elapsedMs == solveCount * 100, "newest solve metadata must remain intact");
        test.expectNear(effort.history().back().effort, static_cast<double>(solveCount) / 10.0,
                        "newest solve effort must remain intact");
    }
}


void testZeroDifficultyIgnoresHashes(Test &test)
{
    xmrig::SoloEffort effort;

    effort.onJob(0);
    effort.addHashes(100);

    test.expectNear(effort.currentEffort(), 0.0, "zero-difficulty jobs must not divide by zero or add effort");
}


} // namespace


int main()
{
    Test test;

    testUnitEffort(test);
    testPiecewiseDifficulty(test);
    testNetworkJobsDoNotReset(test);
    testMeasuredHashrateFeedsLiveEffort(test);
    testInactiveHashrateIntervalsAreExcluded(test);
    testOwnBlockResets(test);
    testAverageEffort(test);
    testBoundedHistory(test);
    testZeroDifficultyIgnoresHashes(test);

    if (test.failures() != 0) {
        std::cerr << test.failures() << " solo effort assertion(s) failed" << std::endl;
        return 1;
    }

    std::cout << "Solo effort preserves piecewise work across network jobs and resets only on own blocks" << std::endl;
    return 0;
}
