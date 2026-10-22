/* SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary */
#ifndef CETRAFS_CRC32C_H
#define CETRAFS_CRC32C_H


/* ---------- CRC32C (Castagnoli) ---------- */
static const uint32_t crc32c_tab[256] = {
    0x00000000U, 0xF26B8303U, 0xE13B70F7U, 0x1350F3F4U, 0xC79A971FU, 0x35F1141CU, 0x26A1E7E8U, 0xD4CA64EBU, 0x8AD958CFU,
    0x78B2DBCCU, 0x6BE22838U, 0x9989AB3BU, 0x4D43CFD0U, 0xBF284CD3U, 0xAC78BF27U, 0x5E133C24U, 0x105EC76FU, 0xE235446CU,
    0xF165B798U, 0x030E349BU, 0xD7C45070U, 0x25AFD373U, 0x36FF2087U, 0xC494A384U, 0x9A879FA0U, 0x68EC1CA3U, 0x7BBCEF57U,
    0x89D76C54U, 0x5D1D08BFU, 0xAF768BBCU, 0xBC267848U, 0x4E4DFB4BU, 0x20BD8EDEU, 0xD2D60DDDU, 0xC186FE29U, 0x33ED7D2AU,
    0xE72719C1U, 0x154C9AC2U, 0x061C6936U, 0xF477EA35U, 0xAA64D611U, 0x580F5512U, 0x4B5FA6E6U, 0xB93425E5U, 0x6DFE410EU,
    0x9F95C20DU, 0x8CC531F9U, 0x7EAEB2FAU, 0x30E349B1U, 0xC288CAB2U, 0xD1D83946U, 0x23B3BA45U, 0xF779DEAEU, 0x05125DADU,
    0x1642AE59U, 0xE4292D5AU, 0xBA3A117EU, 0x4851927DU, 0x5B016189U, 0xA96AE28AU, 0x7DA08661U, 0x8FCB0562U, 0x9C9BF696U,
    0x6EF07595U, 0x417B1DBCU, 0xB3109EBFU, 0xA0406D4BU, 0x522BEE48U, 0x86E18AA3U, 0x748A09A0U, 0x67DAFA54U, 0x95B17957U,
    0xCBA24573U, 0x39C9C670U, 0x2A993584U, 0xD8F2B687U, 0x0C38D26CU, 0xFE53516FU, 0xED03A29BU, 0x1F682198U, 0x5125DAD3U,
    0xA34E59D0U, 0xB01EAA24U, 0x42752927U, 0x96BF4DCCU, 0x64D4CECFU, 0x77843D3BU, 0x85EFBE38U, 0xDBFC821CU, 0x2997011FU,
    0x3AC7F2EBU, 0xC8AC71E8U, 0x1C661503U, 0xEE0D9600U, 0xFD5D65F4U, 0x0F36E6F7U, 0x61C69362U, 0x93AD1061U, 0x80FDE395U,
    0x72966096U, 0xA65C047DU, 0x5437877EU, 0x4767748AU, 0xB50CF789U, 0xEB1FCBADU, 0x197448AEU, 0x0A24BB5AU, 0xF84F3859U,
    0x2C855CB2U, 0xDEEEDFB1U, 0xCDBE2C45U, 0x3FD5AF46U, 0x7198540DU, 0x83F3D70EU, 0x90A324FAU, 0x62C8A7F9U, 0xB602C312U,
    0x44694011U, 0x5739B3E5U, 0xA55230E6U, 0xFB410CC2U, 0x092A8FC1U, 0x1A7A7C35U, 0xE811FF36U, 0x3CDB9BDD,  0xCEB018DEU,
    0xDDE0EB2AU, 0x2F8B6829U, 0x82F63B78U, 0x709DB87BU, 0x63CD4B8FU, 0x91A6C88CU, 0x456CAC67U, 0xB7072F64U, 0xA457DC90U,
    0x563C5F93U, 0x082F63B7U, 0xFA44E0B4U, 0xE9141340U, 0x1B7F9043U, 0xCFB5F4A8U, 0x3DDE77ABU, 0x2E8E845FU, 0xDCE5075CU,
    0x92A8FC17U, 0x60C37F14U, 0x73938CE0U, 0x81F80FE3U, 0x55326B08U, 0xA759E80BU, 0xB4091BFFU, 0x466298FCU, 0x1871A4D8U,
    0xEA1A27DBU, 0xF94AD42FU, 0x0B21572CU, 0xDFEB33C7U, 0x2D80B0C4U, 0x3ED04330U, 0xCCBBC033U, 0xA24BB5A6U, 0x502036A5U,
    0x4370C551U, 0xB11B4652U, 0x65D122B9U, 0x97BAA1BAU, 0x84EA524EU, 0x7681D14DU, 0x2892ED69U, 0xDAF96E6AU, 0xC9A99D9EU,
    0x3BC21E9DU, 0xEF087A76U, 0x1D63F975U, 0x0E330A81U, 0xFC588982U, 0xB21572C9U, 0x407EF1CAU, 0x532E023EU, 0xA145813DU,
    0x758FE5D6U, 0x87E466D5U, 0x94B49521U, 0x66DF1622U, 0x38CC2A06U, 0xCAA7A905U, 0xD9F75AF1U, 0x2B9CD9F2U, 0xFF56BD19U,
    0x0D3D3E1AU, 0x1E6DCDEEU, 0xEC064EEDU, 0xC38D26C4U, 0x31E6A5C7U, 0x22B65633U, 0xD0DDD530U, 0x0417B1DBU, 0xF67C32D8U,
    0xE52CC12CU, 0x1747422FU, 0x49547E0BU, 0xBB3FFD08U, 0xA86F0EFCU, 0x5A048DFFU, 0x8ECEE914U, 0x7CA56A17U, 0x6FF599E3U,
    0x9D9E1AE0U, 0xD3D3E1ABU, 0x21B862A8U, 0x32E8915CU, 0xC083125FU, 0x144976B4U, 0xE622F5B7U, 0xF5720643U, 0x07198540U,
    0x590AB964U, 0xAB613A67U, 0xB831C993U, 0x4A5A4A90U, 0x9E902E7BU, 0x6CFBAD78U, 0x7FAB5E8CU, 0x8DC0DD8FU, 0xE330A81AU,
    0x115B2B19U, 0x020BD8EDU, 0xF0605BEEU, 0x24AA3F05U, 0xD6C1BC06U, 0xC5914FF2U, 0x37FACCF1U, 0x69E9F0D5U, 0x9B8273D6U,
    0x88D28022U, 0x7AB90321U, 0xAE7367CAU, 0x5C18E4C9U, 0x4F48173DU, 0xBD23943EU, 0xF36E6F75U, 0x0105EC76U, 0x12551F82U,
    0xE03E9C81U, 0x34F4F86AU, 0xC69F7B69U, 0xD5CF889DU, 0x27A40B9EU, 0x79B737BAU, 0x8BDCB4B9U, 0x988C474DU, 0x6AE7C44EU,
    0xBE2DA0A5U, 0x4C4623A6U, 0x5F16D052U, 0xAD7D5351U};

static inline uint32_t crc32c_update(uint32_t crc, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *) buf;
    crc ^= 0xFFFFFFFFU;
    while (len--)
        crc = (crc >> 8) ^ crc32c_tab[(crc ^ *p++) & 0xFFU];
    return crc ^ 0xFFFFFFFFU;
}

static uint32_t crc32c_struct(const void *s, size_t len, size_t csum_off, size_t csum_len)
{
    /* Copy into a tmp buffer with the checksum field zeroed. A fixed
     * stack buffer, not malloc: every on-disk structure is at most one
     * block, and the old allocation's only failure mode was an exit(1)
     * from header code -- aborting a tool mid-write over an allocation
     * that cannot legitimately fail at these sizes. Bad geometry (an
     * oversize len, or a checksum field outside the struct -- the old
     * check also wrapped on csum_off + csum_len) is a programming error:
     * answer with a CRC that cannot match anything stored, loudly, and
     * let the caller's verification report it. */
    uint8_t tmp[4096]; /* CETRAFS_BLOCK_SIZE, without requiring the header */

    if (len > sizeof(tmp) || csum_off > len || csum_len > len - csum_off) {
        fprintf(stderr, "crc32c_struct: bad geometry (len=%zu csum_off=%zu csum_len=%zu)\n", len, csum_off, csum_len);
        return 0xDEADC5C5U;
    }
    memcpy(tmp, s, len);
    memset(tmp + csum_off, 0, csum_len);
    return crc32c_update(0, tmp, len);
}


/* ---- v0x0005 two-sector inode record helpers (userspace tools) ----
 * The record is two independently-checksummed 512-byte sectors (see
 * cetrafs.h). Every userspace stamp/verify goes through these so no tool
 * hand-rolls the sector geometry. Available only when cetrafs.h was
 * included first (all the tools do). */
#ifdef CETRAFS_VERSION

static inline uint32_t cetrafs_inode_crc_ns_us(const cetrafs_inode_t *in)
{
    return crc32c_struct(in, CETRAFS_INODE_NS_BYTES, offsetof(cetrafs_inode_t, ns_checksum),
                         sizeof(in->ns_checksum));
}

static inline uint32_t cetrafs_inode_crc_fd_us(const cetrafs_inode_t *in)
{
    /* The record carries only the FILE sector's live head; the rest of
     * the sector is the zero tail it does not store (see cetrafs.h).
     * Rebuild the full on-disk sector so the checksum is the same value
     * the kernel stamps -- the format is unchanged by the struct's
     * in-core shrink. */
    uint8_t sector[CETRAFS_INODE_FD_BYTES];

    memcpy(sector, (const uint8_t *) in + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE);
    memset(sector + CETRAFS_INODE_FD_LIVE, 0, sizeof(sector) - CETRAFS_INODE_FD_LIVE);
    return crc32c_struct(sector, CETRAFS_INODE_FD_BYTES, offsetof(cetrafs_inode_t, fd_checksum) - CETRAFS_INODE_FD_OFF,
                         sizeof(in->fd_checksum));
}

/* Stamp the identity echoes and both sector CRCs -- what every record
 * WRITE must do last. */
static inline void cetrafs_inode_stamp_crcs_us(cetrafs_inode_t *in)
{
    in->fd_ino = in->ino;
    in->fd_generation = in->generation;
    in->ns_checksum = 0;
    in->ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns_us(in));
    in->fd_checksum = 0;
    in->fd_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_fd_us(in));
}

/* Both sectors checksum-valid AND agreeing on identity. A mismatch
 * between the sectors' identities is a half-landed whole-record write --
 * transient on a live volume, a fault on a quiet one. */
static inline int cetrafs_inode_crcs_ok(const cetrafs_inode_t *in)
{
    return (uint32_t) cetrafs_le64(in->ns_checksum) == cetrafs_inode_crc_ns_us(in) &&
           (uint32_t) cetrafs_le64(in->fd_checksum) == cetrafs_inode_crc_fd_us(in) &&
           in->fd_ino == in->ino && in->fd_generation == in->generation;
}

#endif /* CETRAFS_VERSION */

#endif /* CETRAFS_CRC32C_H */
