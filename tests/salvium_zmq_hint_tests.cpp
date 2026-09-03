/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/net/stratum/ZmqHint.h"


#include <iostream>
#include <string>


namespace {


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

    int failures() const
    {
        return m_failures;
    }

private:
    int m_failures = 0;
};


void testZmqWarningPredicate(Test &test)
{
    test.expect(xmrig::shouldWarnMissingZmq(true, -1),
                "daemon mode without a configured ZMQ port must warn");
    test.expect(!xmrig::shouldWarnMissingZmq(true, 1234),
                "daemon mode with a configured ZMQ port must not warn");
    test.expect(!xmrig::shouldWarnMissingZmq(false, -1),
                "pool mode without a ZMQ port must not warn");
    test.expect(!xmrig::shouldWarnMissingZmq(false, 1234),
                "pool mode with a port value must not warn");
}


} // namespace


int main()
{
    Test test;

    testZmqWarningPredicate(test);

    if (test.failures() != 0) {
        std::cerr << test.failures() << " test(s) failed" << std::endl;
        return 1;
    }

    std::cout << "All Salvium ZMQ hint tests passed" << std::endl;
    return 0;
}
