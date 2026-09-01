ENTRY(_start)

PHDRS
{
    rodata  PT_LOAD  FILEHDR  PHDRS  FLAGS((1 << 2)) ;
    text    PT_LOAD                  FLAGS((1 << 0) | (1 << 2)) ;
    data    PT_LOAD                  FLAGS((1 << 1) | (1 << 2)) ;
}

SECTIONS
{
    . = 0x200000;

    . += SIZEOF_HEADERS;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.gcc_except_table*)
        *(.note.*)
        *(.comment)
        *(.interp)
        *(.dynamic)
    }
}
