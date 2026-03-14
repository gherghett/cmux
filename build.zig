const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Main GUI binary ---
    const exe = b.addExecutable(.{
        .name = "cmux",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("gtk4");
    exe.linkSystemLibrary("libadwaita-1");
    exe.linkSystemLibrary("vte-2.91-gtk4");
    exe.linkSystemLibrary("libnotify");
    b.installArtifact(exe);

    // --- CLI binary ---
    const cli = b.addExecutable(.{
        .name = "cmux-cli",
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.linkLibC();
    b.installArtifact(cli);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run cmux");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const split_tree_tests = b.addTest(.{
        .root_source_file = b.path("src/split_tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    split_tree_tests.linkLibC();
    split_tree_tests.linkSystemLibrary("gtk4");

    const socket_tests = b.addTest(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = target,
        .optimize = optimize,
    });
    socket_tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(split_tree_tests).step);
    test_step.dependOn(&b.addRunArtifact(socket_tests).step);
}
