//! Build graph for the executable, package tests, and local run workflow.
//!
//! The app is wired as both module and executable so tests compile the reusable
//! import surface as well as the process entry point.
const std = @import("std");

const sqlite_flags = &.{
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_THREADSAFE=1",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = resolveVersion(b);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const lib = b.addModule("evilblog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    lib.addOptions("build_options", build_options);
    addSqlite(b, lib);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "evilblog",
        .root_module = exe_module,
    });
    addSqlite(b, exe.root_module);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Run the installed binary so relative paths match normal execution.
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = lib,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn addSqlite(b: *std.Build, module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
}

const VersionTag = struct {
    name: []const u8,
    version: std.SemanticVersion,
};

fn resolveVersion(b: *std.Build) []const u8 {
    if (b.option([]const u8, "version", "Override the generated application version")) |override| {
        return normalizeOverrideVersion(override);
    }

    return gitVersion(b) orelse "0.0.0+unknown";
}

fn normalizeOverrideVersion(raw: []const u8) []const u8 {
    const version = stripVersionPrefix(std.mem.trim(u8, raw, " \t\r\n"));
    if (version.len == 0) {
        std.process.fatal("-Dversion must not be empty", .{});
    }
    _ = std.SemanticVersion.parse(version) catch {
        std.process.fatal("-Dversion must be a valid SemVer string, got: {s}", .{raw});
    };
    return version;
}

fn gitVersion(b: *std.Build) ?[]const u8 {
    const dirty = isGitDirty(b);
    const short_hash = gitOutput(b, &.{
        "git",
        "rev-parse",
        "--short",
        "HEAD",
    });

    if (latestReleaseTag(b)) |tag| {
        const range = b.fmt("{s}..HEAD", .{tag.name});
        const distance_text = gitOutput(b, &.{
            "git",
            "rev-list",
            "--count",
            range,
        }) orelse return null;
        const distance = std.fmt.parseUnsigned(usize, distance_text, 10) catch return null;

        if (distance == 0) {
            if (!dirty) {
                return b.fmt("{d}.{d}.{d}", .{ tag.version.major, tag.version.minor, tag.version.patch });
            }
            if (short_hash) |hash| {
                return b.fmt("{d}.{d}.{d}+g{s}.dirty", .{ tag.version.major, tag.version.minor, tag.version.patch, hash });
            }
            return b.fmt("{d}.{d}.{d}+dirty", .{ tag.version.major, tag.version.minor, tag.version.patch });
        }

        const hash = short_hash orelse return null;
        return b.fmt("{d}.{d}.{d}-dev.{d}+g{s}{s}", .{
            tag.version.major,
            tag.version.minor,
            tag.version.patch + 1,
            distance,
            hash,
            if (dirty) ".dirty" else "",
        });
    }

    const commit_count_text = gitOutput(b, &.{
        "git",
        "rev-list",
        "--count",
        "HEAD",
    }) orelse return null;
    const commit_count = std.fmt.parseUnsigned(usize, commit_count_text, 10) catch return null;
    const hash = short_hash orelse return null;

    return b.fmt("0.0.{d}+g{s}{s}", .{
        commit_count,
        hash,
        if (dirty) ".dirty" else "",
    });
}

fn latestReleaseTag(b: *std.Build) ?VersionTag {
    const tags = gitOutput(b, &.{
        "git",
        "tag",
        "--merged",
        "HEAD",
        "--sort=-v:refname",
        "--list",
    }) orelse return null;

    var latest: ?VersionTag = null;
    var lines = std.mem.splitScalar(u8, tags, '\n');
    while (lines.next()) |line| {
        const tag_name = std.mem.trim(u8, line, " \t\r\n");
        const version = parseReleaseTag(tag_name) orelse continue;
        if (latest == null or version.order(latest.?.version) == .gt) {
            latest = .{ .name = tag_name, .version = version };
        }
    }
    return latest;
}

fn parseReleaseTag(tag_name: []const u8) ?std.SemanticVersion {
    const raw_version = stripVersionPrefix(tag_name);
    const version = std.SemanticVersion.parse(raw_version) catch return null;
    if (version.pre != null or version.build != null) return null;
    return version;
}

fn stripVersionPrefix(version: []const u8) []const u8 {
    if (version.len > 1 and version[0] == 'v' and std.ascii.isDigit(version[1])) {
        return version[1..];
    }
    return version;
}

fn isGitDirty(b: *std.Build) bool {
    const status = gitOutput(b, &.{
        "git",
        "status",
        "--porcelain",
        "--untracked-files=normal",
        "--",
        "build.zig",
        "build.zig.zon",
        "evilblog.zon",
        "src",
        "statics",
        "public",
        "vendor",
        "Makefile",
        "README.md",
        "AGENTS.md",
        "agents-files",
    }) orelse return false;
    return status.len > 0;
}

fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = 0;
    const stdout = b.runAllowFail(argv, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}
