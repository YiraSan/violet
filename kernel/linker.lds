ENTRY(kernel_entry)

PHDRS
{
    text            PT_LOAD     FLAGS((1 << 0) | (1 << 2)) ;
    rodata          PT_LOAD     FLAGS((1 << 2)) ;
    data            PT_LOAD     FLAGS((1 << 1) | (1 << 2)) ;
}

SECTIONS
{
    . = 0xffffffff80000000;

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))

        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
    }
}
