ENTRY(_start)

PHDRS
{
    text    PT_LOAD FLAGS((1 << 0) | (1 << 2)) ; /* PF_X | PF_R */
    rodata  PT_LOAD FLAGS((1 << 2)) ;            /* PF_R */
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)) ; /* PF_W | PF_R */
    dynamic PT_DYNAMIC FLAGS((1 << 2)) ;         /* PF_R */
}

SECTIONS
{
    . = 0;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

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

    .data : {
        *(.data .data.*)

        *(.data.rel.ro .data.rel.ro.*)
        *(.got)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame) *(.note .note.*) *(.comment) *(.interp)
        *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
        *(.got.plt)
    }
}
