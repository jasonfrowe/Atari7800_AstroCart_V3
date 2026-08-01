// ============================================================================
// File: main.c
// Description: Hazard5 RISC-V Multi-Cart Firmware (FAT32 SD & A78 Title Engine)
// Target: Sipeed Tang Nano 9K / Atari 7800 Multi-Cart V3
// ============================================================================

typedef unsigned char  uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int   uint32_t;

#define REG32(addr) (*(volatile uint32_t *)(addr))
#define REG8(addr)  (*(volatile uint8_t  *)(addr))

#define A78_HEADER_SIZE 128u

#define A78_OFF_VERSION       0u
#define A78_OFF_MAGIC         1u
#define A78_OFF_TITLE        10u
#define A78_OFF_ROM_SIZE     49u
#define A78_OFF_CART_TYPE    53u
#define A78_OFF_V4_MAPPER    64u
#define A78_OFF_V4_MAPPER_OPT 65u
#define A78_OFF_V4_AUDIO     66u
#define A78_OFF_V4_INTERRUPTS 68u

#define CART_FLAG_POKEY_4000   (1u << 0)
#define CART_FLAG_POKEY_450    (1u << 6)
#define CART_FLAG_POKEY_440    (1u << 10)
#define CART_FLAG_POKEY_800    (1u << 15)
#define CART_FLAG_SUPERGAME    (1u << 1)

// Hardware Base Addresses
#define SPI_BASE         0x40000000
#define SPI_DATA         REG8(SPI_BASE + 0x00)
#define SPI_CTRL         REG8(SPI_BASE + 0x04)
#define SPI_DIV          REG8(SPI_BASE + 0x08)

#define CART_RAM_BASE    0x80000000U
#define CART_CSR_CTRL    REG32(0xC0000000)
#define CART_CSR_STATUS  REG32(0xC0000004)
#define CART_CSR_TRIGGER REG32(0xC0000008)

#define MAX_MENU_GAMES 8

typedef struct {
    uint8_t  valid;
    uint8_t  version;
    char     title[33];
    uint32_t rom_size;
    uint16_t cart_type;
    uint8_t  v4_mapper;
    uint8_t  v4_mapper_opt;
    uint16_t v4_audio;
    uint16_t v4_interrupts;
    uint32_t first_cluster;
} a78_cart_info_t;

static a78_cart_info_t g_cart_list[MAX_MENU_GAMES];
static uint8_t g_game_count = 0;
static uint8_t g_sector_buf[512];
static uint8_t g_file_hdr_buf[512];

// Endian Helpers (Safe against unaligned lhu/lw optimization)
static uint16_t read_le_u16(const uint8_t *p) {
    volatile const uint8_t *vp = (volatile const uint8_t *)p;
    uint32_t b0 = vp[0];
    uint32_t b1 = vp[1];
    return (uint16_t)(b0 | (b1 << 8));
}

static uint32_t read_le_u32(const uint8_t *p) {
    volatile const uint8_t *vp = (volatile const uint8_t *)p;
    uint32_t b0 = vp[0];
    uint32_t b1 = vp[1];
    uint32_t b2 = vp[2];
    uint32_t b3 = vp[3];
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

static uint16_t read_be_u16(const uint8_t *p) {
    volatile const uint8_t *vp = (volatile const uint8_t *)p;
    uint32_t b0 = vp[0];
    uint32_t b1 = vp[1];
    return (uint16_t)((b0 << 8) | b1);
}

static uint32_t read_be_u32(const uint8_t *p) {
    volatile const uint8_t *vp = (volatile const uint8_t *)p;
    uint32_t b0 = vp[0];
    uint32_t b1 = vp[1];
    uint32_t b2 = vp[2];
    uint32_t b3 = vp[3];
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

static inline void write_cart_ram(uint32_t offset, uint8_t val) {
    volatile uint8_t *ptr = (volatile uint8_t *)(0x80000000U | (offset & 0xFFFFU));
    *ptr = val;
}

// SPI Helper Functions
static void spi_set_cs(uint8_t state) {
    SPI_CTRL = state ? 1 : 0; // 1 = High (Inactive), 0 = Low (Active)
}

static uint8_t spi_transfer(uint8_t data) {
    SPI_DATA = data;
    while (SPI_CTRL & 0x02); // Wait while busy bit (bit 1) is set
    return SPI_DATA;
}

// SD Card Commands
static uint8_t sd_cmd(uint8_t cmd, uint32_t arg, uint8_t crc) {
    spi_set_cs(0);
    spi_transfer(0xFF);
    spi_transfer(0x40 | cmd);
    spi_transfer((arg >> 24) & 0xFF);
    spi_transfer((arg >> 16) & 0xFF);
    spi_transfer((arg >> 8)  & 0xFF);
    spi_transfer(arg & 0xFF);
    spi_transfer(crc);

    uint8_t res = 0xFF;
    for (int i = 0; i < 10; i++) {
        res = spi_transfer(0xFF);
        if ((res & 0x80) == 0) break;
    }
    spi_set_cs(1);
    return res;
}

static int sd_init(void) {
    SPI_DIV = 33; // Slow clock (~400 kHz) for SD initialization
    spi_set_cs(1);
    for (int i = 0; i < 10; i++) spi_transfer(0xFF); // 80 dummy clocks

    if (sd_cmd(0, 0, 0x95) != 0x01) return -1; // CMD0: Idle state
    sd_cmd(8, 0x000001AA, 0x87);              // CMD8: Check voltage

    // ACMD41 loop
    for (int timeout = 0; timeout < 1000; timeout++) {
        sd_cmd(55, 0, 0xFF);
        if (sd_cmd(41, 0x40000000, 0xFF) == 0x00) break;
    }

    SPI_DIV = 0; // High speed clock (~13.5 MHz)
    spi_set_cs(1);
    return 0;
}

// Read 512-byte Sector from SD Card
static int sd_read_sector(uint32_t sector_lba, uint8_t *buf) {
    spi_set_cs(0);
    spi_transfer(0xFF);
    spi_transfer(0x40 | 17);
    spi_transfer((sector_lba >> 24) & 0xFF);
    spi_transfer((sector_lba >> 16) & 0xFF);
    spi_transfer((sector_lba >> 8)  & 0xFF);
    spi_transfer(sector_lba & 0xFF);
    spi_transfer(0xFF);

    uint8_t res = 0xFF;
    for (int i = 0; i < 100; i++) {
        res = spi_transfer(0xFF);
        if ((res & 0x80) == 0) break;
    }
    if (res != 0x00) {
        spi_set_cs(1);
        return -1;
    }

    // Wait for data token (0xFE)
    uint8_t token = 0xFF;
    for (int i = 0; i < 10000; i++) {
        token = spi_transfer(0xFF);
        if (token == 0xFE) break;
    }
    if (token != 0xFE) {
        spi_set_cs(1);
        return -2;
    }

    for (int i = 0; i < 512; i++) {
        buf[i] = spi_transfer(0xFF);
    }
    // Read 2 CRC bytes
    spi_transfer(0xFF);
    spi_transfer(0xFF);
    spi_set_cs(1);
    return 0;
}

// A78 Header Magic Validator
static int check_a78_magic(const uint8_t *hdr) {
    volatile const uint8_t *p = (volatile const uint8_t *)hdr;
    if (p[1] != 'A') return 1;
    if (p[2] != 'T') return 2;
    if (p[3] != 'A') return 3;
    if (p[4] != 'R') return 4;
    if (p[5] != 'I') return 5;
    if (p[6] != '7') return 6;
    if (p[7] != '8') return 7;
    if (p[8] != '0') return 8;
    if (p[9] != '0') return 9;
    return 0;
}

int main(void) {
    CART_CSR_STATUS = 0x01; // Signal booting / in-progress

    g_game_count = 0;

    // 1. Initialize SD Card over SPI
    if (sd_init() != 0) {
        CART_CSR_STATUS = 0x02; // SD init failed
        return -1;
    }
    CART_CSR_STATUS = 0x03; // SD init succeeded

    // 2. Read Sector 0 (MBR) & Find FAT32 Partition
    uint32_t lba_start = 0;
    if (sd_read_sector(0, g_sector_buf) == 0) {
        if (g_sector_buf[510] == 0x55 && g_sector_buf[511] == 0xAA) {
            // Check partition 1 entry at offset 0x1BE
            uint8_t part_type = g_sector_buf[0x1BE + 4];
            if (part_type != 0x00) {
                lba_start = read_le_u32(&g_sector_buf[0x1BE + 8]);
            }
        }
    } else {
        CART_CSR_STATUS = 0x04; // Read MBR failed
        return -1;
    }
    CART_CSR_STATUS = 0x05; // Read MBR succeeded

    // 3. Read Volume Boot Record (VBR / FAT32 BPB)
    int vbr_err = sd_read_sector(lba_start, g_sector_buf);
    if (vbr_err != 0) {
        CART_CSR_STATUS = (uint32_t)(0xB0 + (-vbr_err));
        return -1;
    }
    if (vbr_err == 0) {
        uint16_t bytes_per_sec = read_le_u16(&g_sector_buf[11]);
        if (bytes_per_sec == 0) bytes_per_sec = 512;

        uint8_t  sec_per_clus = g_sector_buf[13];
        if (sec_per_clus == 0) sec_per_clus = 1;

        uint16_t rsvd_sec_cnt = read_le_u16(&g_sector_buf[14]);
        uint8_t  num_fats     = g_sector_buf[16];
        uint32_t fat_sz32     = read_le_u32(&g_sector_buf[36]);
        uint32_t root_clus    = read_le_u32(&g_sector_buf[44]);
        if (root_clus == 0) root_clus = 2;

        uint32_t fat_start_sector     = lba_start + rsvd_sec_cnt;
        uint32_t cluster_start_sector = fat_start_sector + (num_fats * fat_sz32);

        // 4. Scan FAT32 Root Directory for .A78 files
        uint32_t root_sector = cluster_start_sector + (root_clus - 2) * sec_per_clus;
        CART_CSR_STATUS = 0x10; // Directory scan started

        for (uint32_t s = 0; s < sec_per_clus && g_game_count < MAX_MENU_GAMES; s++) {
            int r_err = sd_read_sector(root_sector + s, g_sector_buf);
            if (r_err != 0) {
                CART_CSR_STATUS = (uint32_t)(0x70 + (-r_err));
                break;
            }

            for (uint32_t entry_idx = 0; entry_idx < 512; entry_idx += 32) {
                const uint8_t *entry = &g_sector_buf[entry_idx];

                if (entry[0] == 0x00) break; // End of directory
                if (entry[0] == 0xE5) continue; // Deleted entry

                CART_CSR_STATUS = 0xD0000000 | ((uint32_t)entry[8] << 16) | ((uint32_t)entry[9] << 8) | entry[10];

                uint8_t attr = entry[11];
                if (attr & 0x18) continue; // Skip Volume ID or Directory entries

                CART_CSR_STATUS = 0x50; // Active entry being checked

                // Check for .A78 / .a78 extension in 8.3 entry (bytes 8..10)
                if ((entry[8] == 'A' || entry[8] == 'a') &&
                    (entry[9] == '7' || entry[9] == '7') &&
                    (entry[10] == '8' || entry[10] == '8')) {

                    CART_CSR_STATUS = 0x20; // .A78 file entry found

                    uint32_t first_clus = ((uint32_t)read_le_u16(&entry[20]) << 16) | read_le_u16(&entry[26]);
                    uint32_t file_sector = cluster_start_sector + (first_clus - 2) * sec_per_clus;

                    // Read first sector of .a78 file to parse A78 header
                    int hdr_err = sd_read_sector(file_sector, g_file_hdr_buf);
                    if (hdr_err != 0) {
                        CART_CSR_STATUS = (uint32_t)(0x70 + (-hdr_err));
                    } else {
                        CART_CSR_STATUS = 0x25; // Sector read ok
                    }
                    if (hdr_err == 0) {
                        for (uint32_t j = 0; j < 32; j++) {
                            write_cart_ram(0xE800 + j, g_file_hdr_buf[j]);
                        }
                        int cmp_res = check_a78_magic(g_file_hdr_buf);
                        if (cmp_res == 0) {
                            CART_CSR_STATUS = 0x30; // A78 header magic matched
                        } else {
                            CART_CSR_STATUS = (uint32_t)cmp_res;
                        }
                        if (cmp_res == 0) {

                            a78_cart_info_t *cart = &g_cart_list[g_game_count];
                            cart->valid         = 1;
                            cart->version       = g_file_hdr_buf[A78_OFF_VERSION];
                            cart->rom_size      = read_be_u32(&g_file_hdr_buf[A78_OFF_ROM_SIZE]);
                            cart->cart_type     = read_be_u16(&g_file_hdr_buf[A78_OFF_CART_TYPE]);
                            cart->v4_mapper     = g_file_hdr_buf[A78_OFF_V4_MAPPER];
                            cart->v4_mapper_opt = g_file_hdr_buf[A78_OFF_V4_MAPPER_OPT];
                            cart->v4_audio      = read_be_u16(&g_file_hdr_buf[A78_OFF_V4_AUDIO]);
                            cart->v4_interrupts = read_be_u16(&g_file_hdr_buf[A78_OFF_V4_INTERRUPTS]);
                            cart->first_cluster = first_clus;

                            // Extract title (32 bytes)
                            for (uint32_t i = 0; i < 32; i++) {
                                char c = (char)g_file_hdr_buf[A78_OFF_TITLE + i];
                                if (c < 32 || c > 126) c = ' ';
                                cart->title[i] = c;
                            }
                            // Populate $E800 through $E8E0 in Menu ROM space (32 bytes per slot)
                            uint16_t slot_offset = 0xE800 + (g_game_count * 32);
                            for (uint32_t i = 0; i < 32; i++) {
                                write_cart_ram(slot_offset + i, (uint8_t)cart->title[i]);
                            }

                            CART_CSR_STATUS = 0x40 + g_game_count; // Game title written

                            g_game_count++;
                            if (g_game_count >= MAX_MENU_GAMES) break;
                        }
                    }
                }
            }
        }
    }

    // 5. Signal Menu Population Complete to 6502 at $7FF0
    CART_CSR_STATUS = 0x80;

    // 6. Monitor $2200 Trigger Register to Stop Updates on Game Handover
    while (1) {
        uint32_t trigger_val = CART_CSR_TRIGGER;
        if (trigger_val & 0x80) {
            // Trigger received from 6502 menu ($2200). Stop updating $E800-$E8FF buffer.
            break;
        }
    }

    // Idle loop post-handover trigger
    while (1) {
    }

    return 0;
}
