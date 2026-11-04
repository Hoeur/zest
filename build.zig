const std = @import("std");

const package: struct {
    name: @EnumLiteral(),
    version: []const u8,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
    fingerprint: u64,
} = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No target or optimize here, so projects importing zest choose their own.
    const zest = b.addModule("zest", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const self_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(self_tests).step);

    addExample(b, "demo", "Run the example tests", zest, target, optimize);
    addExample(b, "failures", "Show failure output (these tests fail on purpose)", zest, target, optimize);

    addUiTest(b, test_step, "src/ui/state.zig", target, optimize);
    addUiTest(b, test_step, "src/ui/layout.zig", target, optimize);
    if (target.result.os.tag == .windows) {
        addUi(b, target, optimize);
        const rich_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/rich_edit.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        for ([_][]const u8{ "user32", "ole32" }) |lib| rich_tests.root_module.linkSystemLibrary(lib, .{});
        test_step.dependOn(&b.addRunArtifact(rich_tests).step);
    }
    addCli(b, test_step, target, optimize);

    const tool_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/package.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(tool_tests).step);

    addRelease(b);
}

/// Every platform `zig build release` packages. Linux builds use musl, so the
/// one static binary runs on any distribution.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

/// Files shipped next to the executables in every archive.
const release_docs = [_][]const u8{ "README.md", "LICENSE", "CHANGELOG.md" };

/// `zig build release`: cross-compiles every release target with ReleaseSafe,
/// packages each into `zig-out/release/ztest-<version>-<arch>-<os>.(zip|tar.gz)`
/// and writes `SHA256SUMS` beside them. The host's own build is run once to
/// check that it reports the right version.
fn addRelease(b: *std.Build) void {
    const release_step = b.step("release", "Build release archives and SHA256SUMS for every platform");
    const packager = b.addExecutable(.{
        .name = "package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/package.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    // An option, not the SOURCE_DATE_EPOCH variable, because the build caches
    // its configuration and does not see environment changes.
    const epoch = b.option(u64, "source-date-epoch", "Release archive file times, in Unix seconds (default 1980-01-01)") orelse 315532800;
    const mtime = b.fmt("{d}", .{epoch});
    const checksums = b.addRunArtifact(packager);
    checksums.addArg("checksums");
    const sums = checksums.addOutputFileArg("SHA256SUMS");

    for (release_targets) |query| {
        const target = b.resolveTargetQuery(query);
        const os = target.result.os.tag;
        const name = b.fmt("ztest-{s}-{s}-{s}", .{ package.version, @tagName(target.result.cpu.arch), @tagName(os) });
        const archive_name = b.fmt("{s}.{s}", .{ name, if (os == .windows) "zip" else "tar.gz" });

        const cli = cliExecutable(b, target, .ReleaseSafe);
        cli.root_module.strip = true;

        const archive = b.addRunArtifact(packager);
        archive.addArgs(&.{ "archive", if (os == .windows) "zip" else "tar.gz" });
        const output = archive.addOutputFileArg(archive_name);
        archive.addArgs(&.{ name, mtime });
        archive.addArgs(&.{ "755", cli.out_filename });
        archive.addArtifactArg(cli);
        if (os == .windows) {
            const ui = uiExecutable(b, target, .ReleaseSafe);
            ui.root_module.strip = true;
            archive.addArgs(&.{ "755", ui.out_filename });
            archive.addArtifactArg(ui);
        }
        for (release_docs) |doc| {
            archive.addArgs(&.{ "644", doc });
            archive.addFileArg(b.path(doc));
        }

        release_step.dependOn(&b.addInstallFileWithDir(output, .{ .custom = "release" }, archive_name).step);
        checksums.addFileArg(output);

        if (b.graph.host.result.os.tag == os and b.graph.host.result.cpu.arch == target.result.cpu.arch) {
            const smoke = b.addRunArtifact(cli);
            smoke.addArg("--version");
            smoke.expectStdOutEqual(b.fmt("ztest {s}\n", .{package.version}));
            release_step.dependOn(&smoke.step);
        }
    }
    release_step.dependOn(&b.addInstallFileWithDir(sums, .{ .custom = "release" }, "SHA256SUMS").step);
}

fn addCli(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = cliExecutable(b, target, optimize);
    b.installArtifact(exe);

    const run_cli = b.addRunArtifact(exe);
    run_cli.addPassthruArgs();
    b.step("run", "Run the ztest CLI").dependOn(&run_cli.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn cliExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", package.version);
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", options);
    return b.addExecutable(.{ .name = "ztest", .root_module = root });
}

fn addUiTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addUi(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = uiExecutable(b, target, optimize);
    b.installArtifact(exe);
    b.step("ui", "Run the desktop app").dependOn(&b.addRunArtifact(exe).step);
}

/// The Windows desktop app.
fn uiExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "ztest-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/desktop.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", package.version);
    exe.root_module.addOptions("build_options", options);
    exe.subsystem = .windows;
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/ui/assets/ztest.rc") });
    for ([_][]const u8{ "user32", "gdi32", "gdiplus", "dwmapi", "shlwapi", "ole32", "comctl32", "comdlg32", "uxtheme" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
    return exe;
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    description: []const u8,
    zest: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zest", .module = zest }},
        }),
    });
    const run_example = b.addRunArtifact(exe);
    run_example.addPassthruArgs();
    b.step(name, description).dependOn(&run_example.step);
}
