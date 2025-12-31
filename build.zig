const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const no_bin = b.option(bool, "no_bin", "Skip emitting binary. Use this for incremental compilation") orelse false;
    var use_llvm = b.option(bool, "use_llvm", "Use LLVM instead of x86 backend") orelse false;
    if (optimize == .ReleaseFast) use_llvm = true;

    const game_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "snake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/snake.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
    });
    game_lib.linkLibC();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "snake",
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = std.builtin.OptimizeMode.ReleaseFast,
        .preferred_linkage = .dynamic,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    exe_mod.linkLibrary(sdl_lib);

    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
        b.getInstallStep().dependOn(&game_lib.step);
    } else {
        b.installArtifact(game_lib);
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}
