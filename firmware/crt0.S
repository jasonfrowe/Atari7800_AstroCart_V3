/* Startup Assembly for Hazard5 RISC-V Firmware */
.section .text.start
.global _start

_start:
    /* Set stack pointer */
    la sp, _stack_top

    /* Zero BSS section */
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b

2:
    /* Call C entry point */
    jal main

/* Infinite loop if main returns */
3:
    j 3b
