/* XMRig
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef XMRIG_TEMPLATEFAMILY_H
#define XMRIG_TEMPLATEFAMILY_H


#include <cstddef>
#include <cstdint>


namespace xmrig {


struct TemplateFamilyId
{
    uint8_t data[16]{};

    bool operator==(const TemplateFamilyId &other) const;
    bool operator!=(const TemplateFamilyId &other) const;
};


/**
 * Returns the first 128 bits of Keccak-256 over a copy of blob with the
 * complete nonce field zeroed. The caller's blob is never modified.
 *
 * Invalid ranges (including integer-overflowing ranges) and null blobs return
 * an all-zero id.
 */
TemplateFamilyId templateFamilyId(const uint8_t *blob, size_t size, size_t nonceOffset, size_t nonceSize);


} /* namespace xmrig */


#endif /* XMRIG_TEMPLATEFAMILY_H */
