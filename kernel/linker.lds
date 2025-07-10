ENTRY(kernel_entry)

PHDRS
{
    limine_requests     PT_LOAD ;
    text                PT_LOAD     FLAGS((1 << 0) | (1 << 2)) ;
    rodata              PT_LOAD     FLAGS((1 << 2)) ;
    data                PT_LOAD     FLAGS((1 << 1) | (1 << 2)) ;
    dynamic             PT_DYNAMIC  FLAGS((1 << 1) | (1 << 2)) ; # should be removed when not-PIE will be possible
}

SECTIONS
{
    . = 0xffffffff80000000;

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text* .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        *(.data .data.*)
    } :data

    .dynamic : {
        *(.dynamic)
    } :data :dynamic

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment .comment.*)
    }
}
