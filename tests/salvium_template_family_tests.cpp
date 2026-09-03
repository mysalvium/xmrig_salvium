/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/crypto/keccak.h"
#include "base/net/stratum/DaemonTelemetry.h"
#include "base/tools/cryptonote/TemplateFamily.h"


#include <algorithm>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>


namespace {


class Test
{
public:
    explicit Test(const char *name) :
        m_name(name)
    {}

    void expect(bool condition, const std::string &message)
    {
        if (!condition) {
            ++m_failures;
            std::cerr << "FAIL " << m_name << ": " << message << std::endl;
        }
    }

    inline int failures() const { return m_failures; }

private:
    const char *m_name;
    int m_failures = 0;
};


bool isZero(const xmrig::TemplateFamilyId &id)
{
    return std::all_of(std::begin(id.data), std::end(id.data), [](uint8_t value) { return value == 0; });
}


int testNonceInvarianceAndCallerImmutability()
{
    Test test("nonce invariance");
    const size_t nonceOffset = 8;
    const size_t nonceSize = 4;
    std::vector<uint8_t> first {
        0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
        0x01, 0x02, 0x03, 0x04, 0x98, 0xa9, 0xba, 0xcb
    };
    std::vector<uint8_t> second = first;
    second[8]  = 0xf1;
    second[9]  = 0xe2;
    second[10] = 0xd3;
    second[11] = 0xc4;
    const std::vector<uint8_t> firstBefore = first;
    const std::vector<uint8_t> secondBefore = second;

    const auto firstId = xmrig::templateFamilyId(first.data(), first.size(), nonceOffset, nonceSize);
    const auto secondId = xmrig::templateFamilyId(second.data(), second.size(), nonceOffset, nonceSize);

    test.expect(firstId == secondId, "changes anywhere in the four-byte nonce field changed the family id");
    test.expect(first == firstBefore, "computing the first id mutated the caller's blob");
    test.expect(second == secondBefore, "computing the second id mutated the caller's blob");

    return test.failures();
}


int testExtraNonceSensitivity()
{
    Test test("extra-nonce sensitivity");
    std::vector<uint8_t> first(24, 0x5a);
    std::vector<uint8_t> second = first;
    second[18] ^= 0x01;

    const auto firstId = xmrig::templateFamilyId(first.data(), first.size(), 7, 4);
    const auto secondId = xmrig::templateFamilyId(second.data(), second.size(), 7, 4);

    test.expect(firstId != secondId, "a byte outside the nonce field did not change the family id");

    return test.failures();
}


int testEightByteNoncePath()
{
    Test test("eight-byte nonce path");
    std::vector<uint8_t> base {
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x66, 0x77, 0x88, 0x99
    };
    std::vector<uint8_t> highNonceChanged = base;
    highNonceChanged[10] = 0xa5;
    highNonceChanged[11] = 0xb6;
    highNonceChanged[12] = 0xc7;
    highNonceChanged[13] = 0xd8;
    std::vector<uint8_t> afterNonceChanged = base;
    afterNonceChanged[14] ^= 0xff;

    const auto baseId = xmrig::templateFamilyId(base.data(), base.size(), 6, 8);
    const auto highNonceId = xmrig::templateFamilyId(highNonceChanged.data(), highNonceChanged.size(), 6, 8);
    const auto afterNonceId = xmrig::templateFamilyId(afterNonceChanged.data(), afterNonceChanged.size(), 6, 8);

    test.expect(baseId == highNonceId, "changes in bytes five through eight of the nonce changed the family id");
    test.expect(baseId != afterNonceId, "a change immediately after the eight-byte nonce did not change the family id");

    return test.failures();
}


int testDeterminismAndSpecifiedDigest()
{
    Test test("determinism and specified digest");
    const std::vector<uint8_t> blob { 0x10, 0x20, 0x30, 0xaa, 0xbb, 0xcc, 0xdd, 0x40, 0x50 };
    const std::vector<uint8_t> canonical { 0x10, 0x20, 0x30, 0x00, 0x00, 0x00, 0x00, 0x40, 0x50 };
    uint8_t expected[32];
    xmrig::keccak(canonical.data(), static_cast<int>(canonical.size()), expected, sizeof(expected));

    const auto first = xmrig::templateFamilyId(blob.data(), blob.size(), 3, 4);
    const auto second = xmrig::templateFamilyId(blob.data(), blob.size(), 3, 4);

    test.expect(first == second, "identical inputs produced different ids");
    test.expect(memcmp(first.data, expected, sizeof(first.data)) == 0,
                "id is not the first 128 bits of Keccak-256 over the specified canonical blob");

    return test.failures();
}


int testNonceAtEndAndInvalidBounds()
{
    Test test("bounds");
    std::vector<uint8_t> first { 0x10, 0x20, 0x30, 0x40, 0x01, 0x02, 0x03, 0x04 };
    std::vector<uint8_t> second = first;
    second[4] = 0xf1;
    second[5] = 0xe2;
    second[6] = 0xd3;
    second[7] = 0xc4;

    const auto firstId = xmrig::templateFamilyId(first.data(), first.size(), 4, 4);
    const auto secondId = xmrig::templateFamilyId(second.data(), second.size(), 4, 4);
    test.expect(firstId == secondId, "a nonce field ending exactly at blob.size() was rejected or not fully zeroed");
    test.expect(!isZero(firstId), "a valid range ending at blob.size() returned the invalid-range sentinel");

    const auto pastEnd = xmrig::templateFamilyId(first.data(), first.size(), 5, 4);
    const auto overflowing = xmrig::templateFamilyId(first.data(), first.size(), std::numeric_limits<size_t>::max(), 2);
    test.expect(isZero(pastEnd), "a nonce range extending past blob.size() did not return the zero id");
    test.expect(isZero(overflowing), "an integer-overflowing nonce range did not return the zero id");

    return test.failures();
}


int testTemplateSourceProvenance()
{
    Test test("template source provenance");
    xmrig::DaemonTemplateRequests requests;
    requests.add(41, xmrig::Buffer { 0x10, 0x11 }, xmrig::TemplateSource::POLL);
    requests.add(42, xmrig::Buffer { 0x20, 0x21 }, xmrig::TemplateSource::ZMQ);

    xmrig::DaemonTemplateRequest zmq;
    xmrig::DaemonTemplateRequest poll;
    test.expect(requests.take(42, zmq), "lost the ZMQ-triggered request");
    test.expect(requests.take(41, poll), "lost the watchdog/poll-triggered request");
    test.expect(zmq.source == xmrig::TemplateSource::ZMQ, "a ZMQ-triggered template was not labeled ZMQ");
    test.expect(poll.source == xmrig::TemplateSource::POLL, "a watchdog/poll-triggered template was not labeled poll");
    test.expect(zmq.extraNonce == xmrig::Buffer({ 0x20, 0x21 }), "ZMQ request metadata was paired with the wrong response id");
    test.expect(poll.extraNonce == xmrig::Buffer({ 0x10, 0x11 }), "poll request metadata was paired with the wrong response id");
    test.expect(xmrig::templateSourceFromTag(xmrig::templateSourceTag(xmrig::TemplateSource::ZMQ)) == xmrig::TemplateSource::ZMQ,
                "the HTTP trigger tag did not preserve ZMQ provenance");
    test.expect(xmrig::templateSourceFromTag(xmrig::templateSourceTag(xmrig::TemplateSource::POLL)) == xmrig::TemplateSource::POLL,
                "the HTTP trigger tag did not preserve poll provenance");

    return test.failures();
}


int testRetryPreservesSiblingRequest()
{
    Test test("retry preserves sibling request");
    xmrig::DaemonTemplateRequests requests;
    requests.add(51, xmrig::Buffer { 0x31, 0x32 }, xmrig::TemplateSource::POLL);
    requests.add(52, xmrig::Buffer { 0x41, 0x42 }, xmrig::TemplateSource::ZMQ);

    requests.onRetry(51);

    xmrig::DaemonTemplateRequest failed;
    xmrig::DaemonTemplateRequest sibling;
    test.expect(!requests.take(51, failed), "failed request metadata was not discarded");
    test.expect(requests.take(52, sibling), "retry discarded an independent in-flight request");
    test.expect(sibling.extraNonce == xmrig::Buffer({ 0x41, 0x42 }), "late sibling response lost its retained extra nonce");
    test.expect(sibling.source == xmrig::TemplateSource::ZMQ, "late sibling response lost its retained source");

    requests.add(53, xmrig::Buffer { 0x51, 0x52 }, xmrig::TemplateSource::POLL);
    requests.onRetry(-1);
    test.expect(requests.take(53, sibling), "a retry unrelated to an HTTP RPC discarded in-flight request metadata");

    for (size_t i = 0; i <= xmrig::DaemonTemplateRequests::maxPending(); ++i) {
        requests.add(static_cast<int64_t>(100 + i), xmrig::Buffer { static_cast<uint8_t>(i) }, xmrig::TemplateSource::POLL);
    }

    test.expect(requests.size() == xmrig::DaemonTemplateRequests::maxPending(), "pending request metadata was not bounded");
    test.expect(!requests.take(100, failed), "the oldest request was not evicted when the bound was exceeded");
    test.expect(requests.take(100 + xmrig::DaemonTemplateRequests::maxPending(), sibling), "the newest bounded request was not retained");

    return test.failures();
}


} // namespace


int main()
{
    int failures = 0;
    failures += testNonceInvarianceAndCallerImmutability();
    failures += testExtraNonceSensitivity();
    failures += testEightByteNoncePath();
    failures += testDeterminismAndSpecifiedDigest();
    failures += testNonceAtEndAndInvalidBounds();
    failures += testTemplateSourceProvenance();
    failures += testRetryPreservesSiblingRequest();

    if (failures != 0) {
        std::cerr << failures << " template-family assertion(s) failed" << std::endl;
        return 1;
    }

    std::cout << "Template-family identity preserves work-domain separation without mutating blobs" << std::endl;
    return 0;
}
