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

// A78 Header Parser & Loader
int main(void) {
    uint8_t sector_buf[512];

    // Initialize SD Card over SPI
    sd_init();

    // Read first sector containing A78 Cartridge Header
    sd_read_sector(0, sector_buf);

    // Decode 128-byte A78 Header
    uint32_t rom_bytes = ((sector_buf[48] << 24) | (sector_buf[49] << 16) |
                          (sector_buf[50] << 8)  | sector_buf[51]) * 256;
    if (rom_bytes == 0) rom_bytes = 49152; // Default to 48KB

    uint8_t pokey_present = sector_buf[53] & 0x01;

    // Stream ROM Payload (skipping 128-byte header) into FPGA Cartridge RAM
    volatile uint8_t *cart_ram = (volatile uint8_t *)CART_RAM_BASE;

    // Copy remaining bytes of first sector
    for (int i = 128; i < 512; i++) {
        *cart_ram++ = sector_buf[i];
    }

    // Read remaining sectors
    uint32_t sectors_needed = (rom_bytes - (512 - 128) + 511) / 512;
    for (uint32_t sec = 1; sec <= sectors_needed; sec++) {
        sd_read_sector(sec, sector_buf);
        for (int i = 0; i < 512; i++) {
            *cart_ram++ = sector_buf[i];
        }
    }

    // Configure Cartridge CSR: enable POKEY if specified in A78 header
    CART_CSR_CTRL = pokey_present ? 0x01 : 0x00;

    while (1) {
        // Idle loop / Wait for user selection
    }

    return 0;
}
