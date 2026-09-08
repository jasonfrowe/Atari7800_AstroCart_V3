// ============================================================================
// File: femtorv_service_main.c
// Description: FemtoRV service firmware using Petit FatFs for A78 header probe.
// ============================================================================

#include "petitfatfs/pff.h"
#include "petitfatfs/diskio.h"
#include <stdint.h>

#define REG8(addr) (*(volatile uint8_t *)(addr))

#define CART_CSR_STATUS   REG8(0xC0000004u)
#define CART_CSR_TRIGGER  REG8(0xC0000008u)
#define CART_CSR_DEBUG0   REG8(0xC000000Cu)
#define CART_CSR_DEBUG1   REG8(0xC0000010u)
#define CART_CSR_DEBUG2   REG8(0xC0000014u)

#define META_BASE         0xE0000000u

#define META_HDR_SIG0     0x00u
#define META_HDR_SIG1     0x01u
#define META_HDR_VER      0x02u
#define META_HDR_FLAGS    0x03u
#define META_HDR_COUNT    0x04u
#define META_HDR_VALID    0x05u
#define META_HDR_ERROR    0x06u

#define META_SLOT_BASE    0x20u
#define META_SLOT_STRIDE  36u
#define META_SLOT_COUNT   8u

#define META_FLAG_BUSY    0x01u
#define META_FLAG_DONE    0x02u
#define META_FLAG_ERROR   0x04u
#define META_FLAG_OVER    0x08u

#define A78_HEADER_SIZE 128u
#define A78_OFF_VERSION 0u
#define A78_OFF_MAGIC   1u
#define A78_OFF_ROM_SIZE 49u
#define A78_OFF_TITLE    17u
#define A78_OFF_V4_MAPPER 64u
#define A78_OFF_V4_AUDIO 66u

static FATFS g_fs;

void loader_set_stage(BYTE stage) {
    CART_CSR_STATUS = stage;
}

static void meta_write(uint16_t off, uint8_t value) {
    REG8(META_BASE + (uint32_t)off) = value;
}

static void meta_set_header(uint8_t flags, uint8_t count, uint8_t valid, uint8_t error) {
    meta_write(META_HDR_SIG0, 'M');
    meta_write(META_HDR_SIG1, 'D');
    meta_write(META_HDR_VER, 0x01u);
    meta_write(META_HDR_FLAGS, flags);
    meta_write(META_HDR_COUNT, count);
    meta_write(META_HDR_VALID, valid);
    meta_write(META_HDR_ERROR, error);
}

static uint8_t sanitize_char(uint8_t c) {
    if (c < 0x20u || c > 0x7Eu) {
        return ' ';
    }
    return c;
}

static void meta_clear_slots(void) {
    uint16_t i;
    for (i = 0u; i < (uint16_t)META_SLOT_COUNT * (uint16_t)META_SLOT_STRIDE; ++i) {
        meta_write((uint16_t)(META_SLOT_BASE + i), 0u);
    }
}

static void meta_write_slot_title(uint8_t slot, const char *text) {
    uint16_t base = (uint16_t)(META_SLOT_BASE + (uint16_t)slot * (uint16_t)META_SLOT_STRIDE);
    uint8_t i;

    for (i = 0u; i < 32u; ++i) {
        uint8_t c = (uint8_t)text[i];
        if (c == 0u) {
            break;
        }
        meta_write((uint16_t)(base + i), sanitize_char(c));
    }

    for (; i < 32u; ++i) {
        meta_write((uint16_t)(base + i), 0u);
    }
}

static void meta_write_slot_from_header(uint8_t slot, const uint8_t *hdr, const char *fallback_name) {
    uint16_t base = (uint16_t)(META_SLOT_BASE + (uint16_t)slot * (uint16_t)META_SLOT_STRIDE);
    uint8_t version = hdr[A78_OFF_VERSION];
    uint8_t i;
    uint8_t has_title = 0u;

    for (i = 0u; i < 32u; ++i) {
        uint8_t c = hdr[A78_OFF_TITLE + i];
        if (c == 0u) {
            break;
        }
        c = sanitize_char(c);
        if (c != ' ') {
            has_title = 1u;
        }
        meta_write((uint16_t)(base + i), c);
    }
    for (; i < 32u; ++i) {
        meta_write((uint16_t)(base + i), 0u);
    }

    if (!has_title) {
        meta_write_slot_title(slot, fallback_name);
    }

    meta_write((uint16_t)(base + 32u), (version >= 4u) ? hdr[A78_OFF_V4_MAPPER] : 0u);
    meta_write((uint16_t)(base + 33u), (version >= 4u) ? hdr[A78_OFF_V4_AUDIO] : 0u);
    meta_write((uint16_t)(base + 34u), 0x01u);
    meta_write((uint16_t)(base + 35u), 0u);
}

static uint8_t ascii_upper(uint8_t c) {
    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - ('a' - 'A'));
    }
    return c;
}

static uint32_t read_be_u32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24)
         | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)
         | (uint32_t)p[3];
}

static uint8_t is_a78_magic(const uint8_t *hdr) {
    return (hdr[A78_OFF_MAGIC + 0u] == 'A' &&
            hdr[A78_OFF_MAGIC + 1u] == 'T' &&
            hdr[A78_OFF_MAGIC + 2u] == 'A' &&
            hdr[A78_OFF_MAGIC + 3u] == 'R' &&
            hdr[A78_OFF_MAGIC + 4u] == 'I' &&
            hdr[A78_OFF_MAGIC + 5u] == '7' &&
            hdr[A78_OFF_MAGIC + 6u] == '8' &&
            hdr[A78_OFF_MAGIC + 7u] == '0' &&
            hdr[A78_OFF_MAGIC + 8u] == '0');
}

static uint8_t has_a78_extension(const char *name) {
    uint8_t i;

    for (i = 0u; name[i] != 0u; ++i) {
        if (name[i] == '.' && name[i + 1] != 0u && name[i + 2] != 0u && name[i + 3] != 0u && name[i + 4] == 0u) {
            uint8_t e0 = ascii_upper((uint8_t)name[i + 1]);
            uint8_t e1 = ascii_upper((uint8_t)name[i + 2]);
            uint8_t e2 = ascii_upper((uint8_t)name[i + 3]);
            return (e0 == 'A' && e1 == '7' && e2 == '8') ? 1u : 0u;
        }
    }
    return 0u;
}

static uint8_t build_path(uint8_t use_roms_subdir, const char *name, char *out_path, uint8_t out_len) {
    uint8_t i = 0u;
    uint8_t o = 0u;

    if (use_roms_subdir) {
        const char prefix[] = "ROMS/";
        while (prefix[i] != 0u && o < (uint8_t)(out_len - 1u)) {
            out_path[o++] = prefix[i++];
        }
        i = 0u;
    }

    while (name[i] != 0u && o < (uint8_t)(out_len - 1u)) {
        out_path[o++] = name[i++];
    }
    out_path[o] = 0;
    return (o > 0u) ? 1u : 0u;
}

static uint8_t scan_and_populate(uint8_t use_roms_subdir, uint8_t *valid_bitmap, uint8_t *entry_count, uint8_t *last_error) {
    DIR dj;
    FILINFO fi;
    FRESULT fr;
    const char *dir_path = use_roms_subdir ? "ROMS" : "";
    uint8_t slot = 0u;
    uint8_t overflow = 0u;
    uint8_t hdr[A78_HEADER_SIZE];
    UINT br;
    char path[32];

    loader_set_stage(0x16u);
    fr = pf_opendir(&dj, dir_path);
    if (fr != FR_OK) {
        *last_error = use_roms_subdir ? 0xD8u : 0xEAu;
        return 0u;
    }

    loader_set_stage(0x17u);
    while (1) {
        fr = pf_readdir(&dj, &fi);
        if (fr != FR_OK) {
            *last_error = 0xEAu;
            break;
        }
        if (fi.fname[0] == 0) {
            break;
        }
        if ((fi.fattrib & AM_DIR) != 0u) {
            continue;
        }
        if (!has_a78_extension(fi.fname)) {
            continue;
        }

        if (slot >= META_SLOT_COUNT) {
            overflow = 1u;
            continue;
        }

        if (!build_path(use_roms_subdir, fi.fname, path, sizeof(path))) {
            *last_error = 0xEAu;
            continue;
        }

        loader_set_stage(0x19u);
        fr = pf_open(path);
        if (fr != FR_OK) {
            *last_error = 0xEAu;
            continue;
        }

        loader_set_stage(0x1Au);
        br = 0u;
        fr = pf_read(hdr, A78_HEADER_SIZE, &br);
        if (fr != FR_OK || br < A78_HEADER_SIZE) {
            *last_error = 0xE9u;
            continue;
        }

        loader_set_stage(0x1Bu);
        if (!is_a78_magic(hdr)) {
            *last_error = 0xD6u;
            continue;
        }
        if (read_be_u32(&hdr[A78_OFF_ROM_SIZE]) == 0u) {
            *last_error = 0xD7u;
            continue;
        }

        meta_write_slot_from_header(slot, hdr, fi.fname);
        *valid_bitmap = (uint8_t)(*valid_bitmap | (1u << slot));
        slot++;
        *entry_count = slot;

        if (slot == 1u) {
            CART_CSR_DEBUG0 = hdr[A78_OFF_VERSION];
            CART_CSR_DEBUG1 = hdr[A78_OFF_V4_MAPPER];
            CART_CSR_DEBUG2 = hdr[A78_OFF_V4_AUDIO];
        }
    }

    return overflow;
}

static void run_fat_scan(uint8_t use_roms_subdir) {
    FRESULT fr;
    uint8_t flags = META_FLAG_BUSY;
    uint8_t entry_count = 0u;
    uint8_t valid_bitmap = 0u;
    uint8_t last_error = 0u;
    uint8_t overflow;

    CART_CSR_DEBUG0 = 0u;
    CART_CSR_DEBUG1 = 0u;
    CART_CSR_DEBUG2 = 0u;

    meta_clear_slots();
    meta_set_header(flags, 0u, 0u, 0u);

    fr = (FRESULT)disk_initialize();
    if (fr != 0) {
        loader_set_stage(0xE0u);
        flags = (uint8_t)(META_FLAG_DONE | META_FLAG_ERROR);
        meta_set_header(flags, 0u, 0u, 0xE0u);
        return;
    }

    loader_set_stage(0x13u);
    fr = pf_mount(&g_fs);
    if (fr != FR_OK) {
        loader_set_stage(0xE2u);
        flags = (uint8_t)(META_FLAG_DONE | META_FLAG_ERROR);
        meta_set_header(flags, 0u, 0u, 0xE2u);
        return;
    }

    loader_set_stage(0x14u);
    loader_set_stage(0x15u);

    overflow = scan_and_populate(use_roms_subdir, &valid_bitmap, &entry_count, &last_error);

    flags = META_FLAG_DONE;
    if (overflow) {
        flags = (uint8_t)(flags | META_FLAG_OVER);
    }

    if (entry_count == 0u) {
        flags = (uint8_t)(flags | META_FLAG_ERROR);
        if (last_error == 0u) {
            last_error = use_roms_subdir ? 0xD8u : 0xEAu;
        }
        loader_set_stage(last_error);
    } else {
        loader_set_stage(0x1Cu);
    }

    meta_set_header(flags, entry_count, valid_bitmap, last_error);
}

int main(void) {
    uint8_t last_cmd = 0x00u;

    run_fat_scan(1u);

    while (1) {
        uint8_t cmd = CART_CSR_TRIGGER;
        if ((cmd != last_cmd) && (cmd & 0x80u)) {
            last_cmd = cmd;
            run_fat_scan((uint8_t)(cmd & 0x01u));
        }
    }

    return 0;
}
