// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <crypto/hash.h>
#include <linux/crypto.h>
#include <linux/ctype.h>
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

/*
 * This node's identity in the Node Registry, set explicitly. Two
 * machines with the same identity act as ONE node -- same row, same
 * Zone Groups, same allocations -- and the DMI-derived default is not
 * unique everywhere: a cloned VM keeps its SMBIOS UUID unless the
 * hypervisor regenerates it, firmware ships placeholder UUIDs, and the
 * fallback below hashes vendor/product/serial strings that boards often
 * leave empty or generic. A mount that finds its own identity live on
 * another machine refuses and names this parameter (node.c).
 */
static char *cetrafs_node_uuid;
module_param_named(node_uuid, cetrafs_node_uuid, charp, 0444);
MODULE_PARM_DESC(node_uuid,
                 "This machine's node identity (a UUID); overrides the DMI-derived one, which is not "
                 "unique on cloned VMs or on boards without a serial");

/*
 * UUIDs that firmware and hypervisors write in place of a real one. Two
 * machines carrying the same value are one node to the registry (audit
 * L7), so the DMI value is refused when it is one of these. A value is a
 * placeholder when its 32 hex digits repeat with period 1 or 2 (all
 * zeros, all F, "fefefefe...", "1212...") or when it is one of the
 * fixed samples below, which boards ship as their default.
 */
static bool cetrafs_uuid_is_placeholder(const char *s)
{
    static const char *const samples[] = {
        "03000200-0400-0500-0006-000700080009", /* the sample value in several firmware releases */
        "00020003-0004-0005-0006-000700080009",
        "12345678-1234-1234-1234-123456789012",
        "01234567-89ab-cdef-0123-456789abcdef",
    };
    char hex[32];
    bool periodic = true;
    int i, n = 0;

    if (strlen(s) < UUID_STRING_LEN)
        return false;
    for (i = 0; i < UUID_STRING_LEN; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-')
                return false; /* not the 8-4-4-4-12 form: not judged */
            continue;
        }
        hex[n++] = (char) tolower((unsigned char) s[i]);
    }
    for (i = 0; i < 32; i++)
        if (hex[i] != hex[i % 2])
            periodic = false;
    if (periodic)
        return true;
    for (i = 0; i < ARRAY_SIZE(samples); i++)
        if (!strncasecmp(s, samples[i], UUID_STRING_LEN))
            return true;
    return false;
}

/* TEST ONLY: refuse nothing for a placeholder (the DMI and override checks
 * below pass it through). grow/node_uuid_placeholder.sh's control: the
 * placeholder then mounts as a node. */
static bool cetrafs_placeholder_ok;
cetrafs_test_param(placeholder_ok, cetrafs_placeholder_ok, bool, 0644);
MODULE_PARM_DESC(placeholder_ok, "TEST ONLY: accept a placeholder DMI or node_uuid identity instead of refusing it");

/* TEST ONLY: the DMI product UUID is read from this table instead of the
 * firmware, so a suite can give the module a placeholder or a distinct
 * identity without the machine's own. 0 = the firmware's value; 5 = no
 * UUID and no serials either. */
static const char *const cetrafs_dmi_test_uuids[] = {
    NULL,
    "00000000-0000-0000-0000-000000000000",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "03000200-0400-0500-0006-000700080009",
    "5b1d4f22-2e7a-4c91-9d3b-6a0f8e21c4d7",
    "", /* 5: no DMI UUID and no serials -- the hash fallback with nothing to hash */
};
static unsigned int cetrafs_dmi_uuid_inject;
cetrafs_test_param(dmi_uuid_inject, cetrafs_dmi_uuid_inject, uint, 0644);
MODULE_PARM_DESC(dmi_uuid_inject, "TEST ONLY: index of the DMI product UUID to use instead of the firmware's (1-5)");

/* Refuse a placeholder identity with the way out named. The override is
 * the module parameter node_uuid, set when cetrafs loads. */
static const char *cetrafs_placeholder_refused(const char *what, const char *uuid)
{
    pr_err("%s %s is a placeholder that boards and hypervisors write in place of a real identity -- refusing to "
           "mount as a node other machines would share. Give this machine its own: load cetrafs with "
           "node_uuid=<uuid> (modprobe cetrafs node_uuid=<uuid>, or cetrafs.node_uuid=<uuid> on the kernel "
           "command line)\n",
           what, uuid);
    return NULL;
}

/* A serial number that tells this machine from another of its model: not
 * absent, not empty, not one of the strings firmware writes in its place,
 * and not one character repeated ("0000000", "xxxxx"). */
static bool cetrafs_serial_usable(const char *s)
{
    static const char *const fillers[] = {"to be filled by o.e.m.", "default string", "not specified", "none",
                                          "system serial number", "not applicable", "n/a", "unknown",
                                          "chassis serial number", "base board serial number"};
    size_t i, n;

    if (!s)
        return false;
    while (*s == ' ')
        s++;
    n = strlen(s);
    while (n && s[n - 1] == ' ')
        n--;
    if (!n)
        return false;
    for (i = 0; i < ARRAY_SIZE(fillers); i++)
        if (n == strlen(fillers[i]) && !strncasecmp(s, fillers[i], n))
            return false;
    for (i = 1; i < n; i++)
        if (tolower(s[i]) != tolower(s[0]))
            return true;
    return false;
}

const char *get_stable_machine_uuid(void)
{
    /* +1: UUID_STRING_LEN (36) excludes the NUL -- a buffer of exactly
     * that size can't hold a full "xxxxxxxx-...-xxxxxxxxxxxx" string plus
     * its terminator, which previously truncated the last character and
     * produced a UUID string too short for uuid_parse() to accept. */
    static char uuid_str[UUID_STRING_LEN + 1];
    const char *dmi_uuid;
    uuid_t parsed;

    if (cetrafs_node_uuid && *cetrafs_node_uuid) {
        if (strlen(cetrafs_node_uuid) == UUID_STRING_LEN && !uuid_parse(cetrafs_node_uuid, &parsed)) {
            if (cetrafs_uuid_is_placeholder(cetrafs_node_uuid) && !READ_ONCE(cetrafs_placeholder_ok))
                return cetrafs_placeholder_refused("node_uuid", cetrafs_node_uuid);
            strscpy(uuid_str, cetrafs_node_uuid, sizeof(uuid_str));
            return uuid_str;
        }
        pr_err("node_uuid=%s is not a UUID -- refusing to guess an identity\n", cetrafs_node_uuid);
        return NULL;
    }

    dmi_uuid = dmi_get_system_info(DMI_PRODUCT_UUID);
    if (READ_ONCE(cetrafs_dmi_uuid_inject) < ARRAY_SIZE(cetrafs_dmi_test_uuids) &&
        cetrafs_dmi_test_uuids[READ_ONCE(cetrafs_dmi_uuid_inject)])
        dmi_uuid = cetrafs_dmi_test_uuids[READ_ONCE(cetrafs_dmi_uuid_inject)];
    if (dmi_uuid && strlen(dmi_uuid) >= UUID_STRING_LEN) {
        if (cetrafs_uuid_is_placeholder(dmi_uuid) && !READ_ONCE(cetrafs_placeholder_ok))
            return cetrafs_placeholder_refused("this machine's DMI product UUID", dmi_uuid);
        /* strscpy, not strncpy: the kernel is retiring strncpy and 7.2
         * no longer declares it at all, so this would not build there.
         * Same result -- the length was checked above, and strscpy
         * NUL-terminates, which is why the explicit terminator is
         * gone. */
        strscpy(uuid_str, dmi_uuid, sizeof(uuid_str));
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

        if (READ_ONCE(cetrafs_dmi_uuid_inject) == 5) /* test-only; see the parameter */
            serial = board = NULL;
        /* Vendor and product name every board of a model alike: with no
         * serial to tell two machines apart the hash is the model's, and
         * two such machines become one node (audit 2026-11-14 L7). */
        if (!cetrafs_serial_usable(serial) && !cetrafs_serial_usable(board) && !READ_ONCE(cetrafs_placeholder_ok))
            return cetrafs_placeholder_refused("this machine's identity (no DMI UUID and no serial number)",
                                               "the vendor and product name alone");

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
