MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K }
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .data : { *(.data*) *(.sdata*) *(.rodata*) *(.bss*) *(.sbss*) } > RAM
}
