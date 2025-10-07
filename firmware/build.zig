const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const optimize = b.standardOptimizeOption(.{});
    const firmware = mb.add_firmware(.{
        .name = "silvia",
        .target = mb.ports.rp2xxx.boards.raspberrypi.pico,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    mb.install_firmware(firmware, .{});
    mb.install_firmware(firmware, .{ .format = .elf });
    mb.install_firmware(firmware, .{ .format = .{ .uf2 = .RP2040 } });
}
