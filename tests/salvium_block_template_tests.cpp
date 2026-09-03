/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "3rdparty/rapidjson/document.h"
#include "base/crypto/keccak.h"
#include "base/tools/Cvt.h"
#include "base/tools/cryptonote/BlockTemplate.h"


#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>


namespace {


std::string toHex(const uint8_t *data, size_t size)
{
    static constexpr char hex[] = "0123456789abcdef";

    std::string out(size * 2, '\0');
    for (size_t i = 0; i < size; ++i) {
        out[i * 2]     = hex[data[i] >> 4];
        out[i * 2 + 1] = hex[data[i] & 0x0F];
    }

    return out;
}


void appendVarint(xmrig::Buffer &out, uint64_t value)
{
    while (value >= 0x80) {
        out.emplace_back((static_cast<uint8_t>(value) & 0x7F) | 0x80);
        value >>= 7;
    }

    out.emplace_back(static_cast<uint8_t>(value));
}


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


int testFixture(const rapidjson::Value &fixture)
{
    const char *name = fixture["name"].GetString();
    Test test(name);

    const char *blobHex = fixture["blob"].GetString();
    const size_t blobHexSize = fixture["blob"].GetStringLength();
    xmrig::Buffer blob = xmrig::Cvt::fromHex(blobHex, blobHexSize);

    test.expect(blob.size() == fixture["blob_bytes"].GetUint64(), "decoded blob length");

    xmrig::BlockTemplate block;
    if (!block.parse(blob, xmrig::Coin::SALVIUM, true)) {
        test.expect(false, "BlockTemplate rejected canonical mainnet block");
        return test.failures();
    }

    test.expect(block.majorVersion() == fixture["major_version"].GetUint(), "major version");
    test.expect(block.minorVersion() == fixture["minor_version"].GetUint(), "minor version");
    test.expect(block.height() == fixture["height"].GetUint64(), "miner height");
    test.expect(block.txVersion() == fixture["miner_tx_version"].GetUint64(), "miner transaction version");
    test.expect(block.numOutputs() == fixture["miner_outputs"].GetUint64(), "miner output count");
    test.expect(block.outputType() == fixture["first_output_type"].GetUint64(), "first miner output type");
    test.expect(block.numHashes() == fixture["regular_tx_hashes"].GetUint64(), "regular transaction hash count");
    test.expect(block.hasProtocolTransaction(), "protocol transaction detected");

    const size_t expectedHashCount = static_cast<size_t>(block.numHashes()) + 2;
    test.expect(block.hashes().size() == expectedHashCount * xmrig::BlockTemplate::kHashSize, "Merkle hash list size");

    if (block.hashes().size() >= 2 * xmrig::BlockTemplate::kHashSize) {
        test.expect(
            toHex(block.hashes().data(), xmrig::BlockTemplate::kHashSize) == fixture["miner_tx_hash"].GetString(),
            "miner transaction hash"
            );
        test.expect(
            toHex(block.hashes().data() + xmrig::BlockTemplate::kHashSize, xmrig::BlockTemplate::kHashSize) == fixture["protocol_tx_hash"].GetString(),
            "protocol transaction hash"
            );
    }

    const xmrig::Buffer hashingBlob = block.generateHashingBlob();
    // Salvium calculates the public block ID by hashing the binary-serialized
    // blobdata value: a varint byte length followed by the mining blob.
    xmrig::Buffer serializedHashingBlob;
    appendVarint(serializedHashingBlob, hashingBlob.size());
    serializedHashingBlob.insert(serializedHashingBlob.end(), hashingBlob.begin(), hashingBlob.end());

    uint8_t blockHash[xmrig::BlockTemplate::kHashSize];
    xmrig::keccak(
        serializedHashingBlob.data(),
        static_cast<int>(serializedHashingBlob.size()),
        blockHash,
        xmrig::BlockTemplate::kHashSize
        );

    const std::string actualBlockHash = toHex(blockHash, sizeof(blockHash));
    test.expect(
        actualBlockHash == fixture["block_hash"].GetString(),
        "canonical block hash (actual " + actualBlockHash + ", hashing blob " + std::to_string(hashingBlob.size()) + " bytes)"
        );

    xmrig::Buffer truncated(blob);
    truncated.pop_back();
    xmrig::BlockTemplate truncatedBlock;
    test.expect(!truncatedBlock.parse(truncated, xmrig::Coin::SALVIUM, true), "truncated blob must be rejected");

    xmrig::Buffer invalidOutput(blob);
    const size_t outputTypeOffset = block.offset(xmrig::BlockTemplate::EPH_PUBLIC_KEY_OFFSET) - 1;
    invalidOutput[outputTypeOffset] = 0x7F;
    xmrig::BlockTemplate invalidOutputBlock;
    test.expect(!invalidOutputBlock.parse(invalidOutput, xmrig::Coin::SALVIUM, true), "unknown output type must be rejected");

    xmrig::Buffer invalidProtocol(blob);
    invalidProtocol[block.offset(xmrig::BlockTemplate::PROTOCOL_TX_PREFIX_OFFSET)] = 0x7F;
    xmrig::BlockTemplate invalidProtocolBlock;
    test.expect(!invalidProtocolBlock.parse(invalidProtocol, xmrig::Coin::SALVIUM, true), "unknown protocol transaction version must be rejected");

    if (test.failures() == 0) {
        std::cout << "PASS " << name
                  << " (height " << block.height()
                  << ", v" << static_cast<unsigned>(block.majorVersion())
                  << ", " << block.numOutputs() << " miner outputs)"
                  << std::endl;
    }

    return test.failures();
}


} // namespace


int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "usage: salvium_block_template_tests <fixture.json>" << std::endl;
        return 2;
    }

    std::ifstream input(argv[1], std::ios::binary);
    if (!input) {
        std::cerr << "unable to open fixture file: " << argv[1] << std::endl;
        return 2;
    }

    std::ostringstream stream;
    stream << input.rdbuf();

    rapidjson::Document document;
    document.Parse(stream.str().c_str());
    if (document.HasParseError() || !document.IsObject() || !document.HasMember("fixtures") || !document["fixtures"].IsArray()) {
        std::cerr << "invalid fixture document: " << argv[1] << std::endl;
        return 2;
    }

    int failures = 0;
    for (const rapidjson::Value &fixture : document["fixtures"].GetArray()) {
        failures += testFixture(fixture);
    }

    if (failures != 0) {
        std::cerr << failures << " Salvium block-template assertion(s) failed" << std::endl;
        return 1;
    }

    std::cout << document["fixtures"].Size() << " canonical Salvium mainnet fixtures passed" << std::endl;
    return 0;
}
