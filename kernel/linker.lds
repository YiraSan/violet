ENTRY(kernel_entry)

PHDRS
{
    rodata  PT_LOAD  FILEHDR  PHDRS  FLAGS((1 << 2)) ;
    text    PT_LOAD                  FLAGS((1 << 0) | (1 << 2)) ;
    data    PT_LOAD                  FLAGS((1 << 1) | (1 << 2)) ;
}

SECTIONS
{
    . = 0xffffffff80000000;

    __rodata_start = .;

    . += SIZEOF_HEADERS;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    
    __text_start = .;
    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    
    __data_start = .;
    .data : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))

        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)

        . = ALIGN(CONSTANT(MAXPAGESIZE));
    } :data

    __kernel_end = .;

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
