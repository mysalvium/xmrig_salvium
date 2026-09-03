/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/net/stratum/DaemonTelemetry.h"


#include <utility>


void xmrig::DaemonTemplateRequests::add(int64_t id, Buffer &&extraNonce, TemplateSource source)
{
    DaemonTemplateRequest request;
    request.extraNonce = std::move(extraNonce);
    request.source     = source;

    m_requests[id] = std::move(request);
    while (m_requests.size() > maxPending()) {
        m_requests.erase(m_requests.begin());
    }
}


void xmrig::DaemonTemplateRequests::onRetry(int64_t failedRequestId)
{
    if (failedRequestId >= 0) {
        m_requests.erase(failedRequestId);
    }
}


bool xmrig::DaemonTemplateRequests::take(int64_t id, DaemonTemplateRequest &request)
{
    const auto it = m_requests.find(id);
    if (it == m_requests.end()) {
        return false;
    }

    request = std::move(it->second);
    m_requests.erase(it);

    return true;
}


int xmrig::templateSourceTag(TemplateSource source)
{
    return static_cast<int>(source);
}


xmrig::TemplateSource xmrig::templateSourceFromTag(int tag)
{
    switch (static_cast<TemplateSource>(tag)) {
    case TemplateSource::POLL:
        return TemplateSource::POLL;

    case TemplateSource::ZMQ:
        return TemplateSource::ZMQ;

    default:
        return TemplateSource::UNSUPPORTED;
    }
}
