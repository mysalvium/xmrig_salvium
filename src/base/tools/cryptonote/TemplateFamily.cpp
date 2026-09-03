/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "base/tools/cryptonote/TemplateFamily.h"
#include "base/crypto/keccak.h"


#include <climits>
#include <cstring>
#include <vector>


bool xmrig::TemplateFamilyId::operator==(const TemplateFamilyId &other) const
{
    return memcmp(data, other.data, sizeof(data)) == 0;
}


bool xmrig::TemplateFamilyId::operator!=(const TemplateFamilyId &other) const
{
    return !(*this == other);
}


xmrig::TemplateFamilyId xmrig::templateFamilyId(const uint8_t *blob, size_t size, size_t nonceOffset, size_t nonceSize)
{
    TemplateFamilyId id{};

    if (!blob || size > static_cast<size_t>(INT_MAX) || nonceOffset > size || nonceSize > size - nonceOffset) {
        return id;
    }

    std::vector<uint8_t> canonical(blob, blob + size);
    memset(canonical.data() + nonceOffset, 0, nonceSize);

    uint8_t digest[32];
    keccak(canonical.data(), static_cast<int>(canonical.size()), digest, sizeof(digest));
    memcpy(id.data, digest, sizeof(id.data));

    return id;
}
