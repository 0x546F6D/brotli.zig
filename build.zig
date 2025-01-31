const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        // .linkage = .static,
        .name = "brotli",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();

    const upstream = b.dependency("brotli", .{});
    lib.addIncludePath(upstream.path("c/include"));
    lib.installHeadersDirectory(upstream.path("c/include/brotli"), "brotli", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // get c_sources according to c_root
    const c_root = upstream.path("c");
    const cr_path = c_root.getPath3(b, null);
    const csources_exclude = [_][]const u8{ "fuzz", "tools" };
    const c_sources = getCSources(allocator, cr_path, &csources_exclude);
    defer allocator.free(c_sources);

    if (c_sources.len == 0) {
        std.debug.print("Error: no .c source files were returned from {}\n", .{cr_path});
        return;
    }

    lib.addCSourceFiles(.{
        .root = c_root,
        .files = c_sources,
    });

    switch (target.result.os.tag) {
        .linux => lib.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => lib.root_module.addCMacro("OS_FREEBSD", "1"),
        .macos => lib.root_module.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "brotli",
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{ .file = upstream.path("c/tools/brotli.c") });
    exe.linkLibrary(lib);
    b.installArtifact(exe);
}

/// get relevant .c files to add as sources
fn getCSources(allocator: std.mem.Allocator, cr_path: std.Build.Cache.Path, exclude: []const []const u8) [][]const u8 {
    // get a walker for cr_path directory
    const crp_str = std.fmt.allocPrint(allocator, "{}", .{cr_path}) catch "";
    const cr_dir = std.fs.openDirAbsolute(crp_str, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: {}, while trying to open dir '{s}'\n", .{ err, crp_str });
        return &[_][]const u8{};
    };
    var walker = cr_dir.walk(allocator) catch |err| {
        std.debug.print("Error: {}, while trying to get walker for dir '{s}'\n", .{ err, crp_str });
        return &[_][]const u8{};
    };
    defer walker.deinit();

    // arraylist to populate with .c files path
    var source_list = std.ArrayList([]const u8).init(allocator);
    defer source_list.deinit();

    blk: while (walker.next() catch null) |entry| {
        switch (entry.kind) {
            std.fs.File.Kind.file => {
                for (exclude) |x| {
                    if (std.mem.indexOf(u8, entry.path, x) != null) continue :blk;
                }
                if (std.mem.indexOf(u8, entry.basename, ".c") != null) {
                    const path = allocator.dupe(u8, entry.path) catch |err| {
                        std.debug.print("Error: {}, while trying to duplicate '{s}'\n", .{ err, entry.path });
                        continue;
                    };
                    source_list.append(path) catch |err| {
                        std.debug.print("Error: {}, while trying to append '{s}' to source_list\n", .{ err, path });
                        continue;
                    };
                }
            },
            else => {},
        }
    }

    return source_list.toOwnedSlice() catch |err| {
        std.debug.print("Error: {}, while converting source_list to owned slice\n", .{err});
        return &[_][]const u8{};
    };
}
