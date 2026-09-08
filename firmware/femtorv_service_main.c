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

#define A78_HEADER_SIZE 128u
#define A78_OFF_VERSION 0u
#define A78_OFF_MAGIC   1u
#define A78_OFF_ROM_SIZE 49u
#define A78_OFF_V4_MAPPER 64u
#define A78_OFF_V4_AUDIO 66u

static FATFS g_fs;

void loader_set_stage(BYTE stage) {
    CART_CSR_STATUS = stage;
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

static uint8_t find_first_a78_path(uint8_t use_roms_subdir, char *out_path, uint8_t out_len) {
    DIR dj;
    FILINFO fi;
    FRESULT fr;
    const char *dir_path = use_roms_subdir ? "ROMS" : "";

    loader_set_stage(0x16u);
    fr = pf_opendir(&dj, dir_path);
    if (fr != FR_OK) {
        return 0u;
    }

    loader_set_stage(0x17u);
    while (1) {
        fr = pf_readdir(&dj, &fi);
        if (fr != FR_OK) {
            return 0u;
        }
        if (fi.fname[0] == 0) {
            return 0u;
        }
        if ((fi.fattrib & AM_DIR) != 0u) {
            continue;
        }
        if (!has_a78_extension(fi.fname)) {
            continue;
        }

        if (use_roms_subdir) {
            const char prefix[] = "ROMS/";
            uint8_t i = 0u;
            uint8_t o = 0u;

            while (prefix[i] != 0u && o < (uint8_t)(out_len - 1u)) {
                out_path[o++] = prefix[i++];
            }
            i = 0u;
            while (fi.fname[i] != 0u && o < (uint8_t)(out_len - 1u)) {
                out_path[o++] = fi.fname[i++];
            }
            out_path[o] = 0;
        } else {
            uint8_t i = 0u;
            while (fi.fname[i] != 0u && i < (uint8_t)(out_len - 1u)) {
                out_path[i] = fi.fname[i];
                ++i;
            }
            out_path[i] = 0;
        }

        return 1u;
    }
}

static void run_fat_scan(uint8_t use_roms_subdir) {
    FRESULT fr;
    UINT br = 0u;
    uint8_t hdr[A78_HEADER_SIZE];
    uint8_t i;
    char a78_path[32];

    CART_CSR_DEBUG0 = 0u;
    CART_CSR_DEBUG1 = 0u;
    CART_CSR_DEBUG2 = 0u;

    fr = (FRESULT)disk_initialize();
    if (fr != 0) {
        loader_set_stage(0xE0u);
        return;
    }

    loader_set_stage(0x13u);
    fr = pf_mount(&g_fs);
    if (fr != FR_OK) {
        loader_set_stage(0xE2u);
        return;
    }

    loader_set_stage(0x14u);
    loader_set_stage(0x15u);

    if (!find_first_a78_path(use_roms_subdir, a78_path, sizeof(a78_path))) {
        loader_set_stage(use_roms_subdir ? 0xD8u : 0xEAu);
        return;
    }

    loader_set_stage(0x19u);
    fr = pf_open(a78_path);
    if (fr != FR_OK) {
        loader_set_stage(0xEAu);
        return;
    }

    loader_set_stage(0x1Au);
    fr = pf_read(hdr, A78_HEADER_SIZE, &br);
    if (fr != FR_OK || br < A78_HEADER_SIZE) {
        loader_set_stage(0xE9u);
        return;
    }

    loader_set_stage(0x1Bu);
    if (!is_a78_magic(hdr)) {
        loader_set_stage(0xD6u);
        return;
    }

    if (read_be_u32(&hdr[A78_OFF_ROM_SIZE]) == 0u) {
        loader_set_stage(0xD7u);
        return;
    }

    for (i = 0u; i < A78_HEADER_SIZE; ++i) {
        if (hdr[i] == 0xFFu) {
            break;
        }
    }

    CART_CSR_DEBUG0 = hdr[A78_OFF_VERSION];
    CART_CSR_DEBUG1 = hdr[A78_OFF_V4_MAPPER];
    CART_CSR_DEBUG2 = hdr[A78_OFF_V4_AUDIO];
    loader_set_stage(0x1Cu);
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
