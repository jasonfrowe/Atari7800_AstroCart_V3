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
#define CART_RAM_BASE     0x80000000u

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

#define GAME_LOAD_MAX_BYTES 49152u

typedef struct {
    uint8_t mapper_class;
    uint8_t pokey_mode;
    uint8_t slot_flags;
} a78_profile_t;

static uint16_t read_be_u16(const uint8_t *p);
static void decode_legacy_profile(uint16_t cart_type, a78_profile_t *out);
static void decode_v4_profile(uint8_t mapper_raw, uint8_t audio_raw, a78_profile_t *out);

static void cart_ram_write_u8(uint16_t off, uint8_t value) {
    REG8(CART_RAM_BASE + (uint32_t)off) = value;
}

static void cart_ram_fill(uint8_t value) {
    uint16_t i;
    for (i = 0u; i < (uint16_t)GAME_LOAD_MAX_BYTES; ++i) {
        cart_ram_write_u8(i, value);
    }
}

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

static void meta_write_slot_from_header(uint8_t slot, const uint8_t *hdr, uint8_t hdr_off, const char *fallback_name, a78_profile_t *out_profile) {
    uint16_t base = (uint16_t)(META_SLOT_BASE + (uint16_t)slot * (uint16_t)META_SLOT_STRIDE);
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
        meta_write((uint16_t)(base + i), c);
    }
    for (; i < 32u; ++i) {
        meta_write((uint16_t)(base + i), 0u);
    }

    if (!has_title) {
        meta_write_slot_title(slot, fallback_name);
        out_profile->slot_flags = (uint8_t)(out_profile->slot_flags | SLOT_FLAG_TITLE_FALLBACK);
    }

    meta_write((uint16_t)(base + 32u), out_profile->mapper_class);
    meta_write((uint16_t)(base + 33u), out_profile->pokey_mode);
    meta_write((uint16_t)(base + 34u), out_profile->slot_flags);
    meta_write((uint16_t)(base + 35u), 0u);
}

static uint8_t ascii_upper(uint8_t c) {
    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - ('a' - 'A'));
    }
    return c;
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

static uint8_t find_slot_path(uint8_t use_roms_subdir, uint8_t target_slot, char *out_path, uint8_t out_len, uint8_t *last_error) {
    DIR dj;
    FILINFO fi;
    FRESULT fr;
    const char *dir_path = use_roms_subdir ? "ROMS" : "";
    uint8_t slot = 0u;

    fr = pf_opendir(&dj, dir_path);
    if (fr != FR_OK) {
        *last_error = use_roms_subdir ? 0xD8u : 0xEAu;
        return 0u;
    }

    while (1) {
        fr = pf_readdir(&dj, &fi);
        if (fr != FR_OK) {
            *last_error = 0xEAu;
            return 0u;
        }
        if (fi.fname[0] == 0u) {
            break;
        }
        if ((fi.fattrib & AM_DIR) != 0u) {
            continue;
        }
        if (!has_a78_extension(fi.fname)) {
            continue;
        }

        if (slot == target_slot) {
            if (!build_path(use_roms_subdir, fi.fname, out_path, out_len)) {
                *last_error = 0xEAu;
                return 0u;
            }
            return 1u;
        }
        ++slot;
    }

    *last_error = 0xD9u;
    return 0u;
}

static uint8_t load_linear_slot(uint8_t slot, uint8_t *last_error) {
    char path[32];
    uint8_t hdr[A78_HEADER_SIZE];
    uint8_t io_buf[128];
    uint8_t hdr_off;
    uint8_t version;
    uint16_t cart_type;
    uint32_t rom_size;
    uint16_t dst;
    uint32_t remaining;
    a78_profile_t profile;
    UINT br;
    FRESULT fr;

    if (!find_slot_path(1u, slot, path, sizeof(path), last_error)) {
        if (!find_slot_path(0u, slot, path, sizeof(path), last_error)) {
            return 0u;
        }
    }

    loader_set_stage(0x31u);
    fr = pf_open(path);
    if (fr != FR_OK) {
        *last_error = 0xEAu;
        return 0u;
    }

    loader_set_stage(0x32u);
    br = 0u;
    fr = pf_read(hdr, A78_HEADER_SIZE, &br);
    if (fr != FR_OK || br < A78_HEADER_SIZE) {
        *last_error = 0xE9u;
        return 0u;
    }

    hdr_off = find_a78_header_offset(hdr);
    if (hdr_off == 0xFFu) {
        *last_error = 0xD6u;
        return 0u;
    }

    version = hdr[hdr_off + A78_OFF_VERSION];
    if (version > 4u) {
        *last_error = 0xD5u;
        return 0u;
    }

    rom_size = read_be_u32(&hdr[hdr_off + A78_OFF_ROM_SIZE]);
    if (rom_size == 0u || rom_size > (uint32_t)GAME_LOAD_MAX_BYTES) {
        *last_error = 0xD3u;
        return 0u;
    }

    cart_type = read_be_u16(&hdr[hdr_off + A78_OFF_CART_TYPE]);
    if (version >= 4u) {
        decode_v4_profile(hdr[hdr_off + A78_OFF_V4_MAPPER], hdr[hdr_off + A78_OFF_V4_AUDIO], &profile);
    } else {
        decode_legacy_profile(cart_type, &profile);
    }

    if (profile.mapper_class != MAP_CLASS_LINEAR) {
        *last_error = 0xD4u;
        return 0u;
    }

    loader_set_stage(0x33u);
    fr = pf_lseek((DWORD)((uint32_t)hdr_off + (uint32_t)A78_HEADER_SIZE));
    if (fr != FR_OK) {
        *last_error = 0xEAu;
        return 0u;
    }

    cart_ram_fill(0xFFu);

    remaining = rom_size;
    dst = (uint16_t)((uint32_t)GAME_LOAD_MAX_BYTES - rom_size);
    loader_set_stage(0x34u);
    while (remaining > 0u) {
        UINT request = (remaining > sizeof(io_buf)) ? (UINT)sizeof(io_buf) : (UINT)remaining;
        br = 0u;
        fr = pf_read(io_buf, request, &br);
        if (fr != FR_OK || br == 0u) {
            *last_error = 0xE9u;
            return 0u;
        }

        for (UINT i = 0u; i < br; ++i) {
            cart_ram_write_u8(dst, io_buf[i]);
            ++dst;
        }

        remaining -= (uint32_t)br;
    }

    CART_CSR_DEBUG0 = version;
    CART_CSR_DEBUG1 = profile.mapper_class;
    CART_CSR_DEBUG2 = profile.pokey_mode;
    return 1u;
}

static uint8_t scan_and_populate(uint8_t use_roms_subdir, uint8_t *valid_bitmap, uint8_t *entry_count, uint8_t *last_error) {
    DIR dj;
    FILINFO fi;
    FRESULT fr;
    const char *dir_path = use_roms_subdir ? "ROMS" : "";
    uint8_t slot = 0u;
    uint8_t overflow = 0u;
    uint8_t hdr[A78_HEADER_SIZE];
    uint8_t hdr_off;
    uint8_t version;
    a78_profile_t profile;
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
        hdr_off = find_a78_header_offset(hdr);
        if (hdr_off == 0xFFu) {
            *last_error = 0xD6u;
            continue;
        }

        version = hdr[hdr_off + A78_OFF_VERSION];
        if (version > 4u) {
            *last_error = 0xD5u;
            continue;
        }

        if (read_be_u32(&hdr[hdr_off + A78_OFF_ROM_SIZE]) == 0u) {
            *last_error = 0xD7u;
            continue;
        }

        meta_write_slot_from_header(slot, hdr, hdr_off, fi.fname, &profile);
        *valid_bitmap = (uint8_t)(*valid_bitmap | (1u << slot));
        slot++;
        *entry_count = slot;

        if (slot == 1u) {
            CART_CSR_DEBUG0 = version;
            CART_CSR_DEBUG1 = profile.mapper_class;
            CART_CSR_DEBUG2 = profile.pokey_mode;
        }
    }

    return overflow;
}

static void run_fat_scan(uint8_t use_roms_subdir) {
    FRESULT fr;
    FATFS fs;
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
    fr = pf_mount(&fs);
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

static void run_slot_load(uint8_t slot) {
    FRESULT fr;
    FATFS fs;
    uint8_t last_error = 0u;

    loader_set_stage(0x30u);

    fr = (FRESULT)disk_initialize();
    if (fr != 0) {
        loader_set_stage(0xE0u);
        return;
    }

    fr = pf_mount(&fs);
    if (fr != FR_OK) {
        loader_set_stage(0xE2u);
        return;
    }

    if (!load_linear_slot(slot, &last_error)) {
        CART_CSR_DEBUG0 = slot;
        CART_CSR_DEBUG1 = last_error;
        CART_CSR_DEBUG2 = 0xFFu;
        // Report the actual failure so menu-side handover logic does not jump
        // into an invalid/empty image.
        loader_set_stage(last_error ? last_error : 0xEFu);
        return;
    }

    loader_set_stage(0x80u);
}

int main(void) {
    uint8_t last_cmd = 0x00u;

    run_fat_scan(1u);

    while (1) {
        uint8_t cmd = CART_CSR_TRIGGER;
        if ((cmd != last_cmd) && (cmd & 0x80u)) {
            last_cmd = cmd;
            if ((cmd == 0x80u) || (cmd == 0x81u)) {
                run_fat_scan((uint8_t)(cmd & 0x01u));
            } else {
                run_slot_load((uint8_t)(cmd & 0x07u));
            }
        }
    }

    return 0;
}
