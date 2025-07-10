const build_options = @import("build_options");

pub usingnamespace switch (build_options.platform) {
    .x86_64_q35 => @import("q35_serial.zig"),
    .aarch64_virt => @import("pl011.zig"),
    .riscv64_virt => @import("pl011.zig"),
};
