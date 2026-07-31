// ============================================================================
// File: main.c
// Description: Hazard5 RISC-V Multi-Cart Firmware (SD Card Loader & A78 Parser)
// Target: Sipeed Tang Nano 9K
// ============================================================================

typedef unsigned char  uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int   uint32_t;

#define REG32(addr) (*(volatile uint32_t *)(addr))
#define REG8(addr)  (*(volatile uint8_t  *)(addr))

#define A78_HEADER_SIZE 128u

#define A78_OFF_VERSION      0u
#define A78_OFF_MAGIC        1u
#define A78_OFF_ROM_SIZE     49u
#define A78_OFF_CART_TYPE    53u
#define A78_OFF_V4_MAPPER    64u
#define A78_OFF_V4_AUDIO     66u

#define CART_FLAG_POKEY_4000   (1u << 0)
#define CART_FLAG_POKEY_450    (1u << 6)
#define CART_FLAG_POKEY_440    (1u << 10)
#define CART_FLAG_POKEY_800    (1u << 15)
#define CART_FLAG_SUPERGAME    (1u << 1)

#define V4_MAPPER_LINEAR       0u
#define V4_MAPPER_SUPERGAME    1u

#define V4_AUDIO_POKEY_MASK    0x0007u
#define V4_AUDIO_POKEY_440     1u
#define V4_AUDIO_POKEY_450     2u
#define V4_AUDIO_POKEY_450_440 3u
#define V4_AUDIO_POKEY_800     4u
#define V4_AUDIO_POKEY_4000    5u

#define POKEY_ADDR_4000        0u
#define POKEY_ADDR_450         1u
#define POKEY_ADDR_800         2u

// Hardware Base Addresses
#define SPI_BASE       0x40000000
#define SPI_DATA       REG8(SPI_BASE + 0x00)
#define SPI_CTRL       REG8(SPI_BASE + 0x04)
#define SPI_DIV        REG8(SPI_BASE + 0x08)

#define CART_RAM_BASE  0x80000000
#define CART_CSR_CTRL  REG32(0xC0000000)

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
static int sd_read_sector(uint32_t sector, uint8_t *buf) {
    if (sd_cmd(17, sector, 0xFF) != 0x00) return -1;

    // Wait for data token (0xFE)
    while (spi_transfer(0xFF) != 0xFE);

    for (int i = 0; i < 512; i++) {
        buf[i] = spi_transfer(0xFF);
    }
    // Read 16-bit CRC
    spi_transfer(0xFF);
    spi_transfer(0xFF);
    spi_set_cs(1);
    return 0;
}

static uint32_t read_be_u32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint16_t read_be_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

// A78 Header Parser & Loader
int main(void) {
    uint8_t sector_buf[512];

    // Initialize SD Card over SPI
    sd_init();

    // Read first sector containing A78 Cartridge Header
    sd_read_sector(0, sector_buf);

    // Decode 128-byte A78 Header per spec.
    uint8_t  header_version = sector_buf[A78_OFF_VERSION];
    uint32_t rom_bytes = read_be_u32(&sector_buf[A78_OFF_ROM_SIZE]);
    if (rom_bytes == 0) rom_bytes = 49152; // Default to 48KB

    uint16_t cart_type = read_be_u16(&sector_buf[A78_OFF_CART_TYPE]);
    uint8_t  v4_mapper = sector_buf[A78_OFF_V4_MAPPER];
    uint16_t v4_audio  = read_be_u16(&sector_buf[A78_OFF_V4_AUDIO]);

    uint8_t mapper_type = 0; // 0=Flat 48K, 1=SuperGame, 2=Flat 32K
    if (header_version >= 4) {
        if (v4_mapper == V4_MAPPER_SUPERGAME) {
            mapper_type = 1;
        } else if (v4_mapper == V4_MAPPER_LINEAR && rom_bytes <= 32768u) {
            mapper_type = 2;
        }
    } else {
        if (cart_type & CART_FLAG_SUPERGAME) {
            mapper_type = 1;
        } else if (rom_bytes <= 32768u) {
            mapper_type = 2;
        }
    }

    uint8_t pokey_present = 0;
    uint8_t pokey_addr_sel = POKEY_ADDR_4000;
    if (header_version >= 4) {
        uint16_t pokey_mode = (v4_audio & V4_AUDIO_POKEY_MASK);
        if (pokey_mode == V4_AUDIO_POKEY_4000) {
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_4000;
        } else if (pokey_mode == V4_AUDIO_POKEY_450 || pokey_mode == V4_AUDIO_POKEY_450_440) {
            // For combined @450+@440, use @450 (current RTL does not implement @440).
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_450;
        } else if (pokey_mode == V4_AUDIO_POKEY_800) {
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_800;
        } else if (pokey_mode == V4_AUDIO_POKEY_440) {
            // Unsupported location in current RTL; leave disabled.
            pokey_present = 0u;
        }
    } else {
        if (cart_type & CART_FLAG_POKEY_4000) {
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_4000;
        } else if (cart_type & CART_FLAG_POKEY_450) {
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_450;
        } else if (cart_type & CART_FLAG_POKEY_800) {
            pokey_present = 1u;
            pokey_addr_sel = POKEY_ADDR_800;
        } else if (cart_type & CART_FLAG_POKEY_440) {
            // Unsupported location in current RTL; leave disabled.
            pokey_present = 0u;
        }
    }

    // Stream ROM Payload (skipping 128-byte header) into FPGA Cartridge RAM
    volatile uint8_t *cart_ram = (volatile uint8_t *)CART_RAM_BASE;

    // Copy remaining bytes of first sector after 128-byte header.
    uint32_t copied = 0;
    for (uint32_t i = A78_HEADER_SIZE; i < 512u && copied < rom_bytes; i++) {
        *cart_ram++ = sector_buf[i];
        copied++;
    }

    // Read remaining sectors, copying exactly rom_bytes payload bytes.
    for (uint32_t sec = 1; copied < rom_bytes; sec++) {
        sd_read_sector(sec, sector_buf);
        for (uint32_t i = 0; i < 512u && copied < rom_bytes; i++) {
            *cart_ram++ = sector_buf[i];
            copied++;
        }
    }

    // Configure Cartridge CSR: [7:4]=mapper_type, [2:1]=pokey_addr_sel, [0]=pokey_enable
    CART_CSR_CTRL = ((uint32_t)(mapper_type & 0x0F) << 4)
                  | ((uint32_t)(pokey_addr_sel & 0x03) << 1)
                  | (uint32_t)(pokey_present & 0x01);

    while (1) {
        // Idle loop / Wait for user selection
    }

    return 0;
}
