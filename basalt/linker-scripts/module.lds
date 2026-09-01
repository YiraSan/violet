ENTRY(_start)

PHDRS
{
    rodata  PT_LOAD  FILEHDR  PHDRS  FLAGS((1 << 2)) ;
    text    PT_LOAD                  FLAGS((1 << 0) | (1 << 2)) ;
    data    PT_LOAD                  FLAGS((1 << 1) | (1 << 2)) ;
    dynamic PT_DYNAMIC               FLAGS((1 << 2)) ;
}

SECTIONS
{
    . = 0;

    . += SIZEOF_HEADERS;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    .dynamic : { 
        *(.dynamic) 
    } :rodata :dynamic

    .rela.dyn : {
        *(.rela.dyn)
        *(.rela.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        *(.data .data.*)
        *(.data.rel.ro .data.rel.ro.*)
        *(.got)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    /DISCARD/ : {
        *(.eh_frame) *(.note .note.*) *(.comment) *(.interp)
        *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
        *(.got.plt)
    }
}
