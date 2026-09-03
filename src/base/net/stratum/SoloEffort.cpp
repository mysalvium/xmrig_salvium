/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/net/stratum/SoloEffort.h"


#include <cmath>


void xmrig::SoloEffort::onJob(uint64_t difficulty)
{
    m_difficulty = difficulty;
}


void xmrig::SoloEffort::addHashes(uint64_t hashes)
{
    if (m_difficulty == 0) {
        return;
    }

    m_currentEffort += static_cast<double>(hashes) / static_cast<double>(m_difficulty);
}


void xmrig::SoloEffort::sampleHashrate(uint64_t now, double hashesPerSecond, bool active)
{
    const uint64_t previous = m_sampleTime;
    m_sampleTime = now;

    if (previous == 0 || now <= previous || !active || m_difficulty == 0 ||
        !std::isfinite(hashesPerSecond) || hashesPerSecond <= 0.0) {
        return;
    }

    const double hashes = hashesPerSecond * static_cast<double>(now - previous) / 1000.0;
    m_currentEffort += hashes / static_cast<double>(m_difficulty);
}


void xmrig::SoloEffort::onOwnBlockFound(uint64_t height, uint64_t elapsedMs)
{
    const Solve solve{ height, elapsedMs, m_currentEffort };

    if (m_history.size() == kHistorySize) {
        m_history.pop_front();
    }

    m_history.push_back(solve);
    m_solveEffort += solve.effort;
    ++m_blocksFound;
    m_currentEffort = 0.0;
}
