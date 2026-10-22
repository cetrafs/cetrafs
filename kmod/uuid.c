// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <crypto/hash.h>
#include <linux/crypto.h>
#include <linux/dmi.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uuid.h>

#include "kmod.h"

static void hash_to_uuid(const u8 *hash, char *uuid_str)
{
    /* Convert 16-byte MD5 hash into UUID format (8-4-4-4-12). Buffer must
     * be UUID_STRING_LEN+1 bytes -- UUID_STRING_LEN (36) is the string
     * length *excluding* the NUL, so snprintf's size arg needs the +1 or
     * it silently truncates the last character (see get_stable_machine_
     * uuid()'s comment below -- this exact bug produced a 35-char string
     * that uuid_parse() rejected once node.c became the first caller to
     * actually parse this value instead of just printing it). */
    snprintf(uuid_str, UUID_STRING_LEN + 1, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10],
             hash[11], hash[12], hash[13], hash[14], hash[15]);
}

const char *get_stable_machine_uuid(void)
{
    /* +1: UUID_STRING_LEN (36) excludes the NUL -- a buffer of exactly
     * that size can't hold a full "xxxxxxxx-...-xxxxxxxxxxxx" string plus
     * its terminator, which previously truncated the last character and
     * produced a UUID string too short for uuid_parse() to accept. */
    static char uuid_str[UUID_STRING_LEN + 1];
    const char *dmi_uuid;

    dmi_uuid = dmi_get_system_info(DMI_PRODUCT_UUID);
    if (dmi_uuid && strlen(dmi_uuid) >= UUID_STRING_LEN) {
        strncpy(uuid_str, dmi_uuid, UUID_STRING_LEN);
        uuid_str[UUID_STRING_LEN] = '\0';
        return uuid_str;
    }

    fs_debug(info, "========================= IN %s uuid fallback", __FUNCTION__);

    /* Fallback: hash multiple DMI fields */
    {
        char buf[256];
        struct crypto_shash *tfm;
        struct shash_desc *shash;
        u8 hash[16];
        const char *vendor = dmi_get_system_info(DMI_SYS_VENDOR);
        const char *product = dmi_get_system_info(DMI_PRODUCT_NAME);
        const char *serial = dmi_get_system_info(DMI_PRODUCT_SERIAL);
        const char *board = dmi_get_system_info(DMI_BOARD_SERIAL);

        snprintf(buf, sizeof(buf), "%s-%s-%s-%s", vendor ? vendor : "unknown", product ? product : "unknown",
                 serial ? serial : "unknown", board ? board : "unknown");

        tfm = crypto_alloc_shash("md5", 0, 0);
        if (IS_ERR(tfm))
            return NULL;

        shash = kmalloc(sizeof(*shash) + crypto_shash_descsize(tfm), GFP_KERNEL);
        if (!shash) {
            crypto_free_shash(tfm);
            return NULL;
        }

        shash->tfm = tfm;
        crypto_shash_init(shash);
        crypto_shash_update(shash, buf, strlen(buf));
        crypto_shash_final(shash, hash);
        kfree(shash);
        crypto_free_shash(tfm);

        hash_to_uuid(hash, uuid_str);
    }

    return uuid_str;
}
