const std = @import("std");

pub fn build(b: *std.Build) !void {
    const opt = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const sphwayland_dep = b.dependency("sphwayland", .{});

    const BindingsGenerator = @import("sphwayland").BindingsGenerator;
    const wl_writer = sphwayland_dep.module("wl_writer");
    const wl_reader = sphwayland_dep.module("wl_reader");
    const wlgen = sphwayland_dep.artifact("wlgen");
    const sphwayland = sphwayland_dep.module("sphwayland");
    const bindings_gen = BindingsGenerator {
        .b = b,
        .target = target,
        .optimize = opt,
        .wlgen = wlgen,
        .wl_writer = wl_writer,
        .wl_reader = wl_reader,
    };

    const wl_bindings = bindings_gen.generate("wl_bindings.zig", &.{
        b.path("res/wayland.xml"),
        b.path("res/wlr-data-control-unstable-v1.xml"),
    });

    const exe = b.addExecutable(.{
        .name = "sphclip",
        .root_source_file = b.path("src/main.zig"),
        .optimize = opt,
        .target = target,
    });
    exe.root_module.addImport("wl_bindings", wl_bindings);
    exe.root_module.addImport("sphwayland", sphwayland);
    exe.addIncludePath(b.path("src"));
    exe.addCSourceFile(.{
        .file = b.path("src/stb_image.c"),
    });
    exe.linkLibC();

    b.installArtifact(exe);
}
