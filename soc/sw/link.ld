/* Linker script cho SoC: ROM 16 KB tai 0x0, RAM 16 KB tai 0x1000_0000 (khop soc/soc_bus.v). .data nam trong ROM, crt0 chep sang RAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 16K
}
SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4);
    } > ROM
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ROM
    .data : {
        _sdata = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > ROM
    _sidata = LOADADDR(.data);
    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM
    _estack = ORIGIN(RAM) + LENGTH(RAM);
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
