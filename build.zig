const std = @import("std");

pub fn build(b: *std.Build) void {

    const device = 
        b.option([]const u8, "device", "target device")
        orelse @panic("-Ddevice missing");
    
    const kernel_dep = b.dependency("kernel", .{
        .device = device,
    });
    b.installArtifact(kernel_dep.artifact("kernel"));

}
