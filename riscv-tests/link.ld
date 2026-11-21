OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) }
  . = ALIGN(0x40);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
