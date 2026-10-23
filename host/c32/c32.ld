/* c32.ld — one flat i386 image for host/c32/*.c (docs/c32.md), linked by ld.lld.
 * The host maps the raw binary at C32_BASE: between the game image (0x3F0000-0x67A000)
 * and our low region (0x10000000), below the arena (0x20000000). Nothing else is there
 * (host/README.md); the host refuses to start if the range is taken. */
OUTPUT_FORMAT("elf32-i386")
ENTRY(c32_base)

C32_BASE = 0x0F000000;
C32_MAX  = 0x00100000;                  /* 1 MB: image + bss */

/* the game's MSVC CRT (re/functions.csv), for the calls clang emits by itself */
PROVIDE(memcpy  = 0x4D9400);
PROVIDE(memset  = 0x4E02A0);
PROVIDE(memmove = 0x4D6EB0);

SECTIONS
{
    . = C32_BASE;
    c32_base = .;
    .head : { KEEP(*(.c32.head)) }      /* struct c32_header, first */
    .text : { *(.text .text.*) }
    /* hook trampolines (rt.c): code written once at init, on pages of their own */
    .tramp : ALIGN(4096) { KEEP(*(.c32.tramp)) . = ALIGN(4096); }
    .rodata : {
        *(.rodata .rodata.*)
        . = ALIGN(4);
        c32_inits = .;
        KEEP(*(.c32.init))
        c32_inits_end = .;
        c32_exports = .;
        KEEP(*(.c32.exports))
        c32_exports_end = .;
    }
    /* everything written at run time starts on a fresh page: no code shares it (Rosetta
     * retranslates a code page on every store into it; docs/c32.md "Pitfalls") */
    .data : ALIGN(4096) { *(.data .data.*) }
    . = ALIGN(4);
    c32_image_end = .;
    .bss : {
        c32_bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(4);
        c32_bss_end = .;
    }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(c32_bss_end - C32_BASE <= C32_MAX, "C32 image + bss larger than C32_MAX")
