/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef XMRIG_ZMQHINT_H
#define XMRIG_ZMQHINT_H


namespace xmrig {


// A negative port is the Pool sentinel for an unconfigured daemon ZMQ endpoint.
inline bool shouldWarnMissingZmq(bool isDaemonMode, int zmqPort)
{
    return isDaemonMode && zmqPort < 0;
}


} // namespace xmrig


#endif // XMRIG_ZMQHINT_H
