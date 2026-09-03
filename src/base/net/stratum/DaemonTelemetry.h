/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef XMRIG_DAEMONTELEMETRY_H
#define XMRIG_DAEMONTELEMETRY_H


#include "base/tools/Buffer.h"


#include <cstddef>
#include <cstdint>
#include <map>


namespace xmrig {


enum class TemplateSource : uint8_t {
    UNSUPPORTED,
    POLL,
    ZMQ
};


struct DaemonTemplateRequest
{
    Buffer extraNonce;
    TemplateSource source = TemplateSource::UNSUPPORTED;
};


class DaemonTemplateRequests
{
public:
    static constexpr size_t maxPending() { return 16; }

    void add(int64_t id, Buffer &&extraNonce, TemplateSource source);
    void onRetry(int64_t failedRequestId);
    bool take(int64_t id, DaemonTemplateRequest &request);

    inline size_t size() const { return m_requests.size(); }

private:
    std::map<int64_t, DaemonTemplateRequest> m_requests;
};


int templateSourceTag(TemplateSource source);
TemplateSource templateSourceFromTag(int tag);


} /* namespace xmrig */


#endif /* XMRIG_DAEMONTELEMETRY_H */
