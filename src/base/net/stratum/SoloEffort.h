/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef XMRIG_SOLOEFFORT_H
#define XMRIG_SOLOEFFORT_H


#include <cstddef>
#include <cstdint>
#include <deque>


namespace xmrig {


class SoloEffort
{
public:
    struct Solve
    {
        uint64_t height;
        uint64_t elapsedMs;
        double effort;
    };

    constexpr static size_t kHistorySize = 16;

    void onJob(uint64_t difficulty);
    void addHashes(uint64_t hashes);
    void sampleHashrate(uint64_t now, double hashesPerSecond, bool active);
    void onOwnBlockFound(uint64_t height, uint64_t elapsedMs);

    inline double avgEffort() const                   { return m_blocksFound == 0 ? 0.0 : m_solveEffort / m_blocksFound; }
    inline double currentEffort() const               { return m_currentEffort; }
    inline const std::deque<Solve> &history() const   { return m_history; }
    inline uint64_t blocksFound() const               { return m_blocksFound; }

private:
    std::deque<Solve> m_history;
    double m_currentEffort = 0.0;
    double m_solveEffort   = 0.0;
    uint64_t m_blocksFound = 0;
    uint64_t m_difficulty  = 0;
    uint64_t m_sampleTime  = 0;
};


} // namespace xmrig


#endif // XMRIG_SOLOEFFORT_H
