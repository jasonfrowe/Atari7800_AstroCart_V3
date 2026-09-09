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
#define CART_CSR_CONFIG   REG8(0xC0000018u)

#define CART_RAM_BASE       0xD0000000u
#define MENU_TITLES_OFFSET  0xA800u  // 48K Cart RAM offset for 6502 address $E800
#define MENU_SLOT_STRIDE    32u
#define MENU_SLOT_COUNT     8u

#define A78_HEADER_SIZE 128u
#define A78_OFF_VERSION 0u
#define A78_OFF_MAGIC   1u
#define A78_OFF_ROM_SIZE 49u
#define A78_OFF_CART_TYPE 53u
#define A78_OFF_TITLE    17u
#define A78_OFF_V4_MAPPER 64u
#define A78_OFF_V4_AUDIO 66u

#define CART_FLAG_POKEY_4000   (1u << 0)
#define CART_FLAG_SUPERGAME    (1u << 1)
#define CART_FLAG_POKEY_450    (1u << 6)
#define CART_FLAG_POKEY_440    (1u << 10)
#define CART_FLAG_POKEY_800    (1u << 15)

#define V4_MAPPER_LINEAR       0u
#define V4_MAPPER_SUPERGAME    1u

#define V4_AUDIO_POKEY_MASK    0x0007u
#define V4_AUDIO_NONE          0u
#define V4_AUDIO_POKEY_440     1u
#define V4_AUDIO_POKEY_450     2u
#define V4_AUDIO_POKEY_450_440 3u
#define V4_AUDIO_POKEY_800     4u
#define V4_AUDIO_POKEY_4000    5u

#define MAP_CLASS_LINEAR       0u
#define MAP_CLASS_SUPERGAME    1u
#define MAP_CLASS_UNSUPPORTED  0xFFu

#define POKEY_MODE_NONE        0u
#define POKEY_MODE_4000        1u
#define POKEY_MODE_0450        2u
#define POKEY_MODE_0440        3u
#define POKEY_MODE_0800        4u
#define POKEY_MODE_MULTI       0xFEu
#define POKEY_MODE_UNKNOWN     0xFFu

#define SLOT_FLAG_VALID              0x01u
#define SLOT_FLAG_SRC_V4             0x02u
#define SLOT_FLAG_SRC_LEGACY         0x04u
#define SLOT_FLAG_UNSUPPORTED_MAPPER 0x08u
#define SLOT_FLAG_UNSUPPORTED_AUDIO  0x10u
#define SLOT_FLAG_HAS_POKEY          0x20u
#define SLOT_FLAG_TITLE_FALLBACK     0x40u

typedef struct {
    uint8_t mapper_class;
    uint8_t pokey_mode;
    uint8_t slot_flags;
} a78_profile_t;

static uint16_t read_be_u16(const uint8_t *p);
static void decode_legacy_profile(uint16_t cart_type, a78_profile_t *out);
static void decode_v4_profile(uint8_t mapper_raw, uint8_t audio_raw, a78_profile_t *out);

static FATFS g_fs;
static char g_slot_paths[MENU_SLOT_COUNT][32];
static uint8_t g_astro_slot = 0xFFu; // slot whose short name starts with "ASTRO", or 0xFF if not found

void loader_set_stage(BYTE stage) {
    CART_CSR_STATUS = stage;
}

static void cart_write(uint16_t off, uint8_t value) {
    REG8(CART_RAM_BASE + (uint32_t)off) = value;
}

static uint8_t sanitize_char(uint8_t c) {
    if (c < 0x20u || c > 0x7Eu) {
        return ' ';
    }
    return c;
}

static void cart_write_slot_title(uint8_t slot, const char *text) {
    uint16_t base = (uint16_t)(MENU_TITLES_OFFSET + (uint16_t)slot * (uint16_t)MENU_SLOT_STRIDE);
    uint8_t i;

    for (i = 0u; i < 32u; ++i) {
        uint8_t c = (uint8_t)text[i];
        if (c == 0u) {
            break;
        }
        cart_write((uint16_t)(base + i), sanitize_char(c));
    }

    for (; i < 32u; ++i) {
        cart_write((uint16_t)(base + i), 0u);
    }
}

static void cart_write_slot_from_header(uint8_t slot, const uint8_t *hdr, uint8_t hdr_off, const char *fallback_name, a78_profile_t *out_profile) {
    uint16_t base = (uint16_t)(MENU_TITLES_OFFSET + (uint16_t)slot * (uint16_t)MENU_SLOT_STRIDE);
    uint8_t version = hdr[hdr_off + A78_OFF_VERSION];
    uint16_t cart_type = read_be_u16(&hdr[hdr_off + A78_OFF_CART_TYPE]);
    uint8_t mapper_raw = hdr[hdr_off + A78_OFF_V4_MAPPER];
    uint8_t audio_raw = hdr[hdr_off + A78_OFF_V4_AUDIO];
    uint8_t i;
    uint8_t has_title = 0u;

    if (version >= 4u) {
        decode_v4_profile(mapper_raw, audio_raw, out_profile);
    } else {
        decode_legacy_profile(cart_type, out_profile);
    }

    for (i = 0u; i < 32u; ++i) {
        uint8_t c = hdr[hdr_off + A78_OFF_TITLE + i];
        if (c == 0u) {
            break;
        }
        c = sanitize_char(c);
        if (c != ' ') {
            has_title = 1u;
        }
        cart_write((uint16_t)(base + i), c);
    }
    for (; i < 32u; ++i) {
        cart_write((uint16_t)(base + i), 0u);
    }

    if (!has_title) {
        cart_write_slot_title(slot, fallback_name);
        out_profile->slot_flags = (uint8_t)(out_profile->slot_flags | SLOT_FLAG_TITLE_FALLBACK);
    }
}

static uint8_t ascii_upper(uint8_t c) {
    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - ('a' - 'A'));
    }
    return c;
}

// PetitFatFs has no LFN support, so pf_readdir() only ever returns the FAT
// 8.3 short name. That alias is NOT the simple "first six chars + ~1" DOS
// scheme once a real OS (e.g. macOS, including its hidden "._" AppleDouble
// sidecar files) has written the volume -- it can end up as something like
// "ASTRO~22.A78". Guessing the short name in firmware is fragile and breaks
// the moment the SD card's file listing changes. Instead, remember which
// slot's short name started with "ASTRO" during the scan (the one real ROM
// on this card with that prefix) and reuse that proven-working path.
static uint8_t starts_with_astro(const char *name) {
    static const char prefix[] = "ASTRO";
    uint8_t i;
    for (i = 0u; i < 5u; ++i) {
        if (name[i] == 0u || ascii_upper((uint8_t)name[i]) != (uint8_t)prefix[i]) {
            return 0u;
        }
    }
    return 1u;
}

static uint16_t read_be_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
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

static uint8_t find_a78_header_offset(const uint8_t *hdr) {
    uint8_t off;
    for (off = 0u; off <= 4u; ++off) {
        if (hdr[off + A78_OFF_VERSION] == 0u) {
            continue;
        }
        if (is_a78_magic(&hdr[off])) {
            return off;
        }
    }
    return 0xFFu;
}

static uint8_t popcount16(uint16_t x) {
    uint8_t n = 0u;
    while (x != 0u) {
        n = (uint8_t)(n + (x & 1u));
        x >>= 1;
    }
    return n;
}

static void decode_legacy_profile(uint16_t cart_type, a78_profile_t *out) {
    uint16_t pokey_bits = (uint16_t)(cart_type & (CART_FLAG_POKEY_4000 |
                                                  CART_FLAG_POKEY_450 |
                                                  CART_FLAG_POKEY_440 |
                                                  CART_FLAG_POKEY_800));
    uint16_t known_bits = (uint16_t)(CART_FLAG_SUPERGAME |
                                     CART_FLAG_POKEY_4000 |
                                     CART_FLAG_POKEY_450 |
                                     CART_FLAG_POKEY_440 |
                                     CART_FLAG_POKEY_800);

    out->slot_flags = (uint8_t)(SLOT_FLAG_VALID | SLOT_FLAG_SRC_LEGACY);
    out->mapper_class = (cart_type & CART_FLAG_SUPERGAME) ? MAP_CLASS_SUPERGAME : MAP_CLASS_LINEAR;
    out->pokey_mode = POKEY_MODE_NONE;

    if (pokey_bits != 0u) {
        out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY);
    }

    if (popcount16(pokey_bits) > 1u) {
        out->pokey_mode = POKEY_MODE_MULTI;
        out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_UNSUPPORTED_AUDIO);
    } else if (pokey_bits & CART_FLAG_POKEY_4000) {
        out->pokey_mode = POKEY_MODE_4000;
    } else if (pokey_bits & CART_FLAG_POKEY_450) {
        out->pokey_mode = POKEY_MODE_0450;
    } else if (pokey_bits & CART_FLAG_POKEY_440) {
        out->pokey_mode = POKEY_MODE_0440;
    } else if (pokey_bits & CART_FLAG_POKEY_800) {
        out->pokey_mode = POKEY_MODE_0800;
    }

    if ((cart_type & (uint16_t)(~known_bits)) != 0u) {
        out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_UNSUPPORTED_MAPPER);
    }
}

static void decode_v4_profile(uint8_t mapper_raw, uint8_t audio_raw, a78_profile_t *out) {
    uint8_t pokey = (uint8_t)(audio_raw & (uint8_t)V4_AUDIO_POKEY_MASK);

    out->slot_flags = (uint8_t)(SLOT_FLAG_VALID | SLOT_FLAG_SRC_V4);
    out->mapper_class = MAP_CLASS_UNSUPPORTED;
    out->pokey_mode = POKEY_MODE_NONE;

    switch (mapper_raw) {
        case V4_MAPPER_LINEAR:
            out->mapper_class = MAP_CLASS_LINEAR;
            break;
        case V4_MAPPER_SUPERGAME:
            out->mapper_class = MAP_CLASS_SUPERGAME;
            break;
        default:
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_UNSUPPORTED_MAPPER);
            break;
    }

    switch (pokey) {
        case V4_AUDIO_NONE:
            out->pokey_mode = POKEY_MODE_NONE;
            break;
        case V4_AUDIO_POKEY_4000:
            out->pokey_mode = POKEY_MODE_4000;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY);
            break;
        case V4_AUDIO_POKEY_450:
            out->pokey_mode = POKEY_MODE_0450;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY);
            break;
        case V4_AUDIO_POKEY_440:
            out->pokey_mode = POKEY_MODE_0440;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY);
            break;
        case V4_AUDIO_POKEY_800:
            out->pokey_mode = POKEY_MODE_0800;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY);
            break;
        case V4_AUDIO_POKEY_450_440:
            out->pokey_mode = POKEY_MODE_MULTI;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_HAS_POKEY | SLOT_FLAG_UNSUPPORTED_AUDIO);
            break;
        default:
            out->pokey_mode = POKEY_MODE_UNKNOWN;
            out->slot_flags = (uint8_t)(out->slot_flags | SLOT_FLAG_UNSUPPORTED_AUDIO);
            break;
    }
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

static uint8_t scan_and_populate(uint8_t *valid_bitmap, uint8_t *entry_count, uint8_t *last_error) {
    DIR dj;
    FILINFO fi;
    FRESULT fr;
    uint8_t slot = 0u;
    uint8_t overflow = 0u;
    uint8_t hdr[A78_HEADER_SIZE];
    uint8_t hdr_off;
    uint8_t version;
    a78_profile_t profile;
    UINT br;
    char path[32];
    uint8_t pass;

    for (pass = 0; pass < 2 && slot == 0; ++pass) {
        uint8_t use_roms_subdir = (pass == 0) ? 1u : 0u;
        const char *dir_path = use_roms_subdir ? "ROMS" : "";

        loader_set_stage(0x16u);
        fr = pf_opendir(&dj, dir_path);
        if (fr != FR_OK) {
            *last_error = 0x6Au;
            continue;
        }

        loader_set_stage(0x17u);
        while (1) {
            fr = pf_readdir(&dj, &fi);
            if (fr != FR_OK || fi.fname[0] == 0) {
                break;
            }
            if ((fi.fattrib & AM_DIR) != 0u) {
                continue;
            }
            if (!has_a78_extension(fi.fname)) {
                continue;
            }

            if (slot >= MENU_SLOT_COUNT) {
                overflow = 1u;
                continue;
            }

            if (!build_path(use_roms_subdir, fi.fname, path, sizeof(path))) {
                *last_error = 0x6Au;
                continue;
            }

            loader_set_stage(0x19u);
            fr = pf_open(path);
            if (fr != FR_OK) {
                *last_error = 0x6Au;
                continue;
            }

            loader_set_stage(0x1Au);
            br = 0u;
            fr = pf_read(hdr, A78_HEADER_SIZE, &br);
            if (fr != FR_OK || br < A78_HEADER_SIZE) {
                *last_error = 0x69u;
                continue;
            }

            loader_set_stage(0x1Bu);
            hdr_off = find_a78_header_offset(hdr);
            if (hdr_off == 0xFFu) {
                *last_error = 0x56u;
                continue;
            }

            version = hdr[hdr_off + A78_OFF_VERSION];
            if (version > 4u) {
                *last_error = 0x55u;
                continue;
            }

            if (read_be_u32(&hdr[hdr_off + A78_OFF_ROM_SIZE]) == 0u) {
                *last_error = 0x57u;
                continue;
            }

            cart_write_slot_from_header(slot, hdr, hdr_off, fi.fname, &profile);
            for (uint8_t pi = 0u; pi < 32u; ++pi) {
                g_slot_paths[slot][pi] = path[pi];
                if (path[pi] == 0) break;
            }
            if (g_astro_slot == 0xFFu && starts_with_astro(fi.fname)) {
                g_astro_slot = slot;
            }
            *valid_bitmap = (uint8_t)(*valid_bitmap | (1u << slot));
            slot++;
            *entry_count = slot;

            if (slot == 1u) {
                CART_CSR_DEBUG0 = version;
                CART_CSR_DEBUG1 = profile.mapper_class;
                CART_CSR_DEBUG2 = profile.pokey_mode;
            }
        }
    }

    return overflow;
}

static void run_fat_scan(void) {
    FRESULT fr;
    uint8_t entry_count = 0u;
    uint8_t valid_bitmap = 0u;
    uint8_t last_error = 0u;
    uint8_t overflow;

    CART_CSR_DEBUG0 = 0u;
    CART_CSR_DEBUG1 = 0u;
    CART_CSR_DEBUG2 = 0u;
    g_astro_slot = 0xFFu;

    fr = (FRESULT)disk_initialize();
    if (fr != 0) {
        loader_set_stage(0x60u);
        return;
    }

    loader_set_stage(0x13u);
    fr = pf_mount(&g_fs);
    if (fr != FR_OK) {
        loader_set_stage(0x62u);
        return;
    }

    loader_set_stage(0x14u);
    loader_set_stage(0x15u);

    overflow = scan_and_populate(&valid_bitmap, &entry_count, &last_error);
    (void)overflow;

    if (entry_count == 0u) {
        if (last_error == 0u) {
            last_error = 0x6Au;
        }
        loader_set_stage(last_error);
    } else {
        loader_set_stage(0x1Cu);
    }
}

static void load_game(uint8_t slot) {
    FRESULT fr = FR_NO_FILE;
    UINT br;
    uint8_t hdr[A78_HEADER_SIZE];
    uint8_t hdr_off;
    uint32_t rom_size;
    uint8_t version;
    uint16_t cart_type;
    a78_profile_t profile;
    uint32_t bytes_loaded = 0;
    uint8_t chunk_buf[256];
    uint32_t ram_offset = 0;

    loader_set_stage(0x20u);

    // Default to always loading astrowing.a78 from SDCard: use the path the
    // scan already proved works (g_astro_slot), rather than guessing an 8.3
    // short name -- the FAT alias macOS assigns (e.g. "ASTRO~22.A78") is not
    // the simple "~1" DOS convention and shifts whenever the card's file
    // listing changes, including its hidden "._" AppleDouble sidecar files.
    if (g_astro_slot != 0xFFu && g_slot_paths[g_astro_slot][0] != 0) {
        fr = pf_open(g_slot_paths[g_astro_slot]);
    }

    // If that didn't open, ensure filesystem is mounted and retry
    if (fr != FR_OK && g_astro_slot != 0xFFu && g_slot_paths[g_astro_slot][0] != 0) {
        (void)disk_initialize();
        (void)pf_mount(&g_fs);
        fr = pf_open(g_slot_paths[g_astro_slot]);
    }

    // If still not opened, try selected slot path if populated
    if (fr != FR_OK && slot < MENU_SLOT_COUNT && g_slot_paths[slot][0] != 0) {
        fr = pf_open(g_slot_paths[slot]);
    }

    // If still not opened, try any slot path that was discovered
    if (fr != FR_OK) {
        for (uint8_t s = 0u; s < MENU_SLOT_COUNT; ++s) {
            if (g_slot_paths[s][0] != 0) {
                fr = pf_open(g_slot_paths[s]);
                if (fr == FR_OK) {
                    break;
                }
            }
        }
    }

    if (fr != FR_OK) {
        loader_set_stage(0x6Au);
        return;
    }

    loader_set_stage(0x21u);
    fr = pf_read(hdr, A78_HEADER_SIZE, &br);
    if (fr != FR_OK || br < A78_HEADER_SIZE) {
        loader_set_stage(0x69u);
        return;
    }

    hdr_off = find_a78_header_offset(hdr);
    if (hdr_off == 0xFFu) {
        hdr_off = 0u;
        rom_size = 49152u;
        profile.pokey_mode = POKEY_MODE_0450;
        profile.mapper_class = MAP_CLASS_LINEAR;
    } else {
        version = hdr[hdr_off + A78_OFF_VERSION];
        rom_size = read_be_u32(&hdr[hdr_off + A78_OFF_ROM_SIZE]);
        cart_type = read_be_u16(&hdr[hdr_off + A78_OFF_CART_TYPE]);

        if (version >= 4u) {
            decode_v4_profile(hdr[hdr_off + A78_OFF_V4_MAPPER], hdr[hdr_off + A78_OFF_V4_AUDIO], &profile);
        } else {
            decode_legacy_profile(cart_type, &profile);
        }
    }

    if (rom_size == 0u || rom_size > 49152u) {
        rom_size = 49152u;
    }
    if (profile.pokey_mode == POKEY_MODE_NONE) {
        profile.pokey_mode = POKEY_MODE_0450;
    }

    // Configure POKEY and Mapper in FPGA CSR
    uint8_t cfg = 0u;
    if (profile.pokey_mode == POKEY_MODE_4000) {
        cfg = 0x01u | (0u << 1);
    } else if (profile.pokey_mode == POKEY_MODE_0450) {
        cfg = 0x01u | (1u << 1);
    } else if (profile.pokey_mode == POKEY_MODE_0800) {
        cfg = 0x01u | (2u << 1);
    } else if (profile.pokey_mode == POKEY_MODE_0440) {
        cfg = 0x01u | (3u << 1);
    }
    cfg |= ((uint8_t)(profile.mapper_class & 0x0Fu)) << 3;
    CART_CSR_CONFIG = cfg;

    // If 32KB ROM (e.g. Choplifter, Food Fight):
    // $4000-$7FFF is padded with $FF (16384 bytes)
    // Game payload goes to $8000-$FFFF (Cart RAM offset 16384 to 49151)
    if (rom_size <= 32768u) {
        for (uint32_t i = 0u; i < 16384u; ++i) {
            REG8(CART_RAM_BASE + i) = 0xFFu;
        }
        ram_offset = 16384u;
    }

    loader_set_stage(0x22u);
    while (bytes_loaded < rom_size && (ram_offset + bytes_loaded) < 49152u) {
        UINT to_read = sizeof(chunk_buf);
        if (to_read > (rom_size - bytes_loaded)) {
            to_read = (UINT)(rom_size - bytes_loaded);
        }
        fr = pf_read(chunk_buf, to_read, &br);
        if (fr != FR_OK) {
            loader_set_stage(0x69u);
            return;
        }
        if (br == 0u) {
            break;
        }
        for (UINT i = 0; i < br; ++i) {
            REG8(CART_RAM_BASE + ram_offset + bytes_loaded + (uint32_t)i) = chunk_buf[i];
        }
        bytes_loaded += br;
    }

    if (bytes_loaded == 0u) {
        loader_set_stage(0x69u);
        return;
    }

    // Set status ready bit 7: ALL BYTES WRITTEN TO BSRAM!
    loader_set_stage(0x80u);
}

int main(void) {
    uint8_t last_cmd = 0x00u;

    CART_CSR_CONFIG = 0x03u; // Default $0450 POKEY enabled, linear mapper

    run_fat_scan();

    while (1) {
        uint8_t cmd = CART_CSR_TRIGGER;
        if (cmd != last_cmd) {
            last_cmd = cmd;
            if (cmd == 64u) {
                run_fat_scan();
            } else if (cmd >= 128u && cmd <= 135u) {
                load_game((uint8_t)(cmd - 128u));
            }
        }
    }

    return 0;
}
