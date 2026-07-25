const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dependencies
    const conzole_mod = b.dependency("conzole", .{
        .target = target,
        .optimize = optimize,
    }).module("conzole");

    const lsp_kit_mod = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    }).module("lsp");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compiler_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    compiler_mod.addImport("lib", lib_mod);

    const interpreter_mod = b.createModule(.{
        .root_source_file = b.path("src/interpreter/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    interpreter_mod.addImport("conzole", conzole_mod);
    interpreter_mod.addImport("compiler", compiler_mod);
    interpreter_mod.addImport("lib", lib_mod);

    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_mod.addImport("conzole", conzole_mod);
    lsp_mod.addImport("lsp_kit", lsp_kit_mod);
    lsp_mod.addImport("lib", lib_mod);
    lsp_mod.addImport("compiler", compiler_mod);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("conzole", conzole_mod);
    cli_mod.addImport("lib", lib_mod);
    cli_mod.addImport("compiler", compiler_mod);
    cli_mod.addImport("interpreter", interpreter_mod);
    cli_mod.addImport("lsp", lsp_mod);

    const exe = b.addExecutable(.{
        .name = "tasq",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("lib", lib_mod);
    exe.root_module.addImport("compiler", compiler_mod);
    exe.root_module.addImport("cli", cli_mod);
    exe.root_module.addImport("lsp", lsp_mod);

    b.installArtifact(exe);

    //----- run step -----

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tsq");
    run_step.dependOn(&run_cmd.step);
}
