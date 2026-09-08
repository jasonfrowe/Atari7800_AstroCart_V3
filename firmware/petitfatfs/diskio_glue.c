// ============================================================================
// File: diskio_glue.c
// Description: Low-level Petit FatFs disk glue over project SPI SD MMIO.
// ============================================================================

#include "diskio.h"

#define REG8(addr) (*(volatile BYTE *)(addr))

#define SPI_BASE 0x40000000u
#define SPI_DATA REG8(SPI_BASE + 0x00u)
#define SPI_CTRL REG8(SPI_BASE + 0x04u)
#define SPI_DIV  REG8(SPI_BASE + 0x08u)

extern void loader_set_stage(BYTE stage);

static BYTE disk_status = STA_NOINIT;
static BYTE sd_is_high_capacity = 1u;

static BYTE sector_cache[512];
static DWORD cached_sector = 0xFFFFFFFFu;

static void spi_set_cs(BYTE state) {
    SPI_CTRL = state ? 1u : 0u;
}

static BYTE spi_transfer(BYTE data) {
    SPI_DATA = data;
    while (SPI_CTRL & 0x02u) {
    }
    return SPI_DATA;
}

static void sd_deselect(void) {
    spi_set_cs(1u);
    (void)spi_transfer(0xFFu);
}

static BYTE sd_cmd(BYTE cmd, DWORD arg, BYTE crc) {
    BYTE res = 0xFFu;

    spi_set_cs(0u);
    (void)spi_transfer(0xFFu);
    (void)spi_transfer((BYTE)(0x40u | cmd));
    (void)spi_transfer((BYTE)(arg >> 24));
    (void)spi_transfer((BYTE)(arg >> 16));
    (void)spi_transfer((BYTE)(arg >> 8));
    (void)spi_transfer((BYTE)arg);
    (void)spi_transfer(crc);

    for (UINT i = 0; i < 10u; ++i) {
        res = spi_transfer(0xFFu);
        if ((res & 0x80u) == 0u) {
            break;
        }
    }
    return res;
}

static DWORD sd_sector_arg(DWORD sector) {
    return sd_is_high_capacity ? sector : (sector << 9);
}

static DRESULT sd_read_sector(DWORD sector, BYTE *buf) {
    for (UINT attempt = 0; attempt < 4u; ++attempt) {
        BYTE token = 0xFFu;
        BYTE r1 = sd_cmd(17u, sd_sector_arg(sector), 0xFFu);
        if (r1 != 0x00u) {
            sd_deselect();
            continue;
        }

        for (UINT i = 0; i < 20000u; ++i) {
            token = spi_transfer(0xFFu);
            if (token == 0xFEu) {
                break;
            }
        }
        if (token != 0xFEu) {
            sd_deselect();
            continue;
        }

        for (UINT i = 0; i < 512u; ++i) {
            buf[i] = spi_transfer(0xFFu);
        }

        (void)spi_transfer(0xFFu);
        (void)spi_transfer(0xFFu);
        sd_deselect();
        return RES_OK;
    }

    sd_deselect();
    return RES_ERROR;
}

DSTATUS disk_initialize(void) {
    BYTE r1;
    BYTE r7_2;
    BYTE r7_3;
    BYTE supports_cmd8 = 0u;

    SPI_DIV = 33u;
    spi_set_cs(1u);
    for (UINT i = 0; i < 10u; ++i) {
        (void)spi_transfer(0xFFu);
    }

    r1 = sd_cmd(0u, 0u, 0x95u);
    sd_deselect();
    if (r1 != 0x01u) {
        return STA_NOINIT;
    }

    r1 = sd_cmd(8u, 0x000001AAu, 0x87u);
    if (r1 == 0x01u) {
        supports_cmd8 = 1u;
        (void)spi_transfer(0xFFu);
        (void)spi_transfer(0xFFu);
        r7_2 = spi_transfer(0xFFu);
        r7_3 = spi_transfer(0xFFu);
        if (r7_2 != 0x01u || r7_3 != 0xAAu) {
            sd_deselect();
            return STA_NOINIT;
        }
    }
    sd_deselect();

    for (UINT timeout = 0; timeout < 3000u; ++timeout) {
        (void)sd_cmd(55u, 0u, 0xFFu);
        sd_deselect();
        r1 = sd_cmd(41u, supports_cmd8 ? 0x40000000u : 0u, 0xFFu);
        sd_deselect();
        if (r1 == 0x00u) {
            break;
        }
        if (timeout == 2999u) {
            return STA_NOINIT;
        }
    }

    r1 = sd_cmd(58u, 0u, 0xFFu);
    if (r1 != 0x00u) {
        sd_deselect();
        return STA_NOINIT;
    }
    {
        BYTE ocr0 = spi_transfer(0xFFu);
        (void)spi_transfer(0xFFu);
        (void)spi_transfer(0xFFu);
        (void)spi_transfer(0xFFu);
        sd_is_high_capacity = (ocr0 & 0x40u) ? 1u : 0u;
    }
    sd_deselect();

    if (!sd_is_high_capacity) {
        r1 = sd_cmd(16u, 512u, 0xFFu);
        sd_deselect();
        if (r1 != 0x00u) {
            return STA_NOINIT;
        }
    }

    SPI_DIV = 0u;
    disk_status = 0u;
    cached_sector = 0xFFFFFFFFu;
    loader_set_stage(0x11u);
    return disk_status;
}

DRESULT disk_readp(BYTE* buff, DWORD sector, UINT offset, UINT count) {
    if (disk_status & STA_NOINIT) {
        return RES_NOTRDY;
    }
    if (offset > 511u || count > 512u || (offset + count) > 512u) {
        return RES_PARERR;
    }

    loader_set_stage(0x12u);

    if (cached_sector != sector) {
        DRESULT rr = sd_read_sector(sector, sector_cache);
        if (rr != RES_OK) {
            return rr;
        }
        cached_sector = sector;
    }

    if (buff != (BYTE*)0) {
        for (UINT i = 0; i < count; ++i) {
            buff[i] = sector_cache[offset + i];
        }
    }

    return RES_OK;
}

DRESULT disk_writep(const BYTE* buff, DWORD sc) {
    (void)buff;
    (void)sc;
    return RES_ERROR;
}
