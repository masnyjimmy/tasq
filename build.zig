const std = @import("std");

const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version: []const u8 = blk: {
        const raw = b.option(
            []const u8,
            "version",
            "Version stamped into the binary and release archive names (default: 0.0.0-dev)",
        ) orelse "0.0.0-dev";
        break :blk if (std.mem.startsWith(u8, raw, "v")) raw[1..] else raw;
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const tasq = addTasq(b, target, optimize, null, build_options);
    b.installArtifact(tasq.exe);

    //----- test step ------
    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_]*std.Build.Module{
        tasq.interpreter_mod,
    };

    for (test_modules) |mod| {
        const mod_test = b.addTest(.{
            .root_module = mod,
        });
        const run_mod_test = b.addRunArtifact(mod_test);
        test_step.dependOn(&run_mod_test.step);
    }

    //----- run step -----

    const run_cmd = b.addRunArtifact(tasq.exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run tsq");
    run_step.dependOn(&run_cmd.step);

    // ---- release step -----

}

fn addReleaseStep(
    b: *std.Build,
    version: []const u8,
    build_options: *std.Build.Step.Options,
) void {
    const release_optimize = b.option(
        std.builtin.OptimizeMode,
        "release-optimize",
        "Optimize mode for `zig build release` (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    const release_step = b.step("release", "Cross-compile, package and checksum all release targets");

    const sums_tool = b.addExecutable(.{
        .name = "sha256sums",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sha256sums.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const sums = b.addRunArtifact(sums_tool);
    const sums_file = sums.addOutputFileArg("SHA256SUMS");

    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const arch = @tagName(query.cpu_arch.?);
        const os = @tagName(query.os_tag.?);
        const is_windows = query.os_tag.? == .windows;

        const tasq = addTasq(
            b,
            resolved,
            release_optimize,
            true,
            build_options,
        );

        const exe_name = if (is_windows) "tasq.exe" else "tasq";
        const stage = b.addWriteFiles();
        _ = stage.addCopyFile(tasq.exe.getEmittedBin(), exe_name);
        const staged_dir = stage.getDirectory();

        const archive_name = b.fmt("tasq-v{s}-{s}-{s}.{s}", .{
            version,
            arch,
            os,
            if (is_windows) "zip" else "tar.gz",
        });

        const archive: std.Build.LazyPath = if (is_windows) blk: {
            const zip = b.addSystemCommand(&.{ "zip", "-q", "-j" });
            const out = zip.addOutputFileArg(archive_name);
            zip.addFileArg(staged_dir.path(b, exe_name));
            break :blk out;
        } else blk: {
            const tar = b.addSystemCommand(&.{ "tar", "-czf" });
            const out = tar.addOutputDirectoryArg(archive_name);
            tar.addArg("-C");
            tar.addDirectoryArg(staged_dir);
            tar.addArg(exe_name);
            break :blk out;
        };

        const install = b.addInstallFileWithDir(archive, .{ .custom = "release" }, archive_name);
        release_step.dependOn(&install.step);

        sums.addFileArg(archive);
    }

    const sums_install = b.addInstallFileWithDir(sums_file, .{ .custom = "release" }, "SHA256SUMS");
    release_step.dependOn(&sums_install.step);
}

const Tasq = struct {
    exe: *std.Build.Step.Compile,
    interpreter_mod: *std.Build.Module,
};

fn createModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
}

fn addTasq(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    build_options: *std.Build.Step.Options,
) Tasq {
    //============= dependencies ===============//
    const conzole_mod = b.dependency("conzole", .{
        .target = target,
        .optimize = optimize,
    }).module("conzole");

    const lsp_kit_mod = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    }).module("lsp");

    const glob_mod = b.dependency("libglob", .{
        .target = target,
        .optimize = optimize,
    }).module("libglob");

    //============= modules ===============//

    const lib_mod = createModule(
        b,
        "src/lib/root.zig",
        target,
        optimize,
        strip,
    );

    const compiler_mod = createModule(b, "src/compiler//root.zig", target, optimize, strip);
    compiler_mod.addImport("lib", lib_mod);

    const interpreter_mod = createModule(b, "src/interpreter/root.zig", target, optimize, strip);
    interpreter_mod.addImport("conzole", conzole_mod);
    interpreter_mod.addImport("compiler", compiler_mod);
    interpreter_mod.addImport("lib", lib_mod);
    interpreter_mod.addImport("libglob", glob_mod);

    const lsp_mod = createModule(b, "src/lsp/root.zig", target, optimize, strip);
    lsp_mod.addImport("conzole", conzole_mod);
    lsp_mod.addImport("lsp_kit", lsp_kit_mod);
    lsp_mod.addImport("lib", lib_mod);
    lsp_mod.addImport("compiler", compiler_mod);

    const cli_mod = createModule(b, "src/cli/root.zig", target, optimize, strip);
    cli_mod.addImport("conzole", conzole_mod);
    cli_mod.addImport("lib", lib_mod);
    cli_mod.addImport("compiler", compiler_mod);
    cli_mod.addImport("interpreter", interpreter_mod);
    cli_mod.addImport("lsp", lsp_mod);
    cli_mod.addOptions("build_options", build_options);

    const exe_mod = createModule(b, "src/main.zig", target, optimize, strip);
    cli_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "tasq",
        .use_llvm = true,
        .use_lld = true,
        .root_module = exe_mod,
    });
    exe.root_module.addImport("lib", lib_mod);
    exe.root_module.addImport("compiler", compiler_mod);
    exe.root_module.addImport("conzole", conzole_mod);
    exe.root_module.addImport("cli", cli_mod);
    exe.root_module.addImport("lsp", lsp_mod);

    return .{ .exe = exe, .interpreter_mod = interpreter_mod };
}
