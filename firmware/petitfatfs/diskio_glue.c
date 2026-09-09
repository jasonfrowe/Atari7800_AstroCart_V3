// ============================================================================
// File: diskio_glue.c
// Description: Low-level Petit FatFs disk glue over the hardware SD block
//              controller (rtl/sd_controller.v, ported from AstroCart V2).
//              The whole SD init sequence (CMD0/CMD8/CMD55/CMD41) and each
//              512-byte sector transfer run autonomously in hardware; this
//              file just requests an LBA and reads the result out of the
//              controller's capture buffer. No SPI bit-banging here at all.
// ============================================================================

#include "diskio.h"

#define REG8(addr) (*(volatile BYTE *)(addr))

#define SDHW_BASE      0x50000000u
#define SDHW_BUF(i)    REG8(SDHW_BASE + (i))
#define SDHW_ADDR_B0   REG8(SDHW_BASE + 0x200u)
#define SDHW_ADDR_B1   REG8(SDHW_BASE + 0x204u)
#define SDHW_ADDR_B2   REG8(SDHW_BASE + 0x208u)
#define SDHW_ADDR_B3   REG8(SDHW_BASE + 0x20Cu)
#define SDHW_TRIGGER   REG8(SDHW_BASE + 0x210u) // write: kick off a read; read: bit0 = busy

extern void loader_set_stage(BYTE stage);

static BYTE disk_status = STA_NOINIT;

static DWORD cached_sector = 0xFFFFFFFFu;

DSTATUS disk_initialize(void) {
    // sd_controller.v runs its own CMD0/CMD8/CMD55/CMD41 init sequence as
    // soon as it comes out of reset. Bit1 of SDHW_TRIGGER mirrors its own
    // ready/IDLE state -- wait for that specifically, NOT bit0 (which only
    // reflects a firmware-requested sector read and is irrelevant here).
    UINT timeout;
    for (timeout = 0; timeout < 4000000u; ++timeout) {
        if (SDHW_TRIGGER & 0x02u) {
            disk_status = 0u;
            cached_sector = 0xFFFFFFFFu;
            loader_set_stage(0x11u);
            return disk_status;
        }
    }
    return STA_NOINIT;
}

static DRESULT sd_read_sector(DWORD sector) {
    UINT timeout;

    SDHW_ADDR_B0 = (BYTE)(sector);
    SDHW_ADDR_B1 = (BYTE)(sector >> 8);
    SDHW_ADDR_B2 = (BYTE)(sector >> 16);
    SDHW_ADDR_B3 = (BYTE)(sector >> 24);
    SDHW_TRIGGER = 1u; // any write kicks off the hardware read

    for (timeout = 0; timeout < 4000000u; ++timeout) {
        if ((SDHW_TRIGGER & 0x01u) == 0u) {
            return RES_OK;
        }
    }
    return RES_ERROR;
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
        DRESULT rr = sd_read_sector(sector);
        if (rr != RES_OK) {
            return rr;
        }
        cached_sector = sector;
    }

    if (buff != (BYTE*)0) {
        for (UINT i = 0; i < count; ++i) {
            buff[i] = SDHW_BUF(offset + i);
        }
    }

    return RES_OK;
}

DRESULT disk_writep(const BYTE* buff, DWORD sc) {
    (void)buff;
    (void)sc;
    return RES_ERROR;
}
