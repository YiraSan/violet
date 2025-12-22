ENTRY(_start)

PHDRS
{
    headers PT_PHDR PHDRS ;
    text    PT_LOAD FILEHDR PHDRS FLAGS((1 << 0) | (1 << 2)) ;
    rodata  PT_LOAD FLAGS((1 << 2)) ; 
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)) ;
}

SECTIONS
{
    . = SIZEOF_HEADERS;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(4K);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4K);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.rela.*)
        *(.got)
        *(.got.plt)
    }
}