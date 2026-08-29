const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.fixup);
const triplet = @import("triplet.zig");

/// Initializes the standard sysroot directory structure, merged-usr symlinks, and ld.so.conf.
pub fn initSysrootLayout(io: std.Io, target_root: []const u8, arch: []const u8) !void {
    const trp = triplet.archToTriplet(arch);

    var target_dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer target_dir.close(io);

    // 1. Standard directories
    try target_dir.createDirPath(io, "usr/bin");
    try target_dir.createDirPath(io, "usr/sbin");
    try target_dir.createDirPath(io, "usr/lib");
    try target_dir.createDirPath(io, "usr/include");
    try target_dir.createDirPath(io, "etc/ld.so.conf.d");
    try target_dir.createDirPath(io, "var/cache/debsys");

    var triplet_inc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const triplet_inc = try std.fmt.bufPrint(&triplet_inc_buf, "usr/include/{s}", .{trp});
    try target_dir.createDirPath(io, triplet_inc);

    var triplet_lib_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const triplet_lib = try std.fmt.bufPrint(&triplet_lib_buf, "usr/lib/{s}", .{trp});
    try target_dir.createDirPath(io, triplet_lib);

    if (triplet.is64BitArch(arch)) {
        try target_dir.createDirPath(io, "usr/lib64");
    }

    // 2. Merged-usr symlinks
    _ = target_dir.symLink(io, "usr/bin", "bin", .{}) catch {};
    _ = target_dir.symLink(io, "usr/sbin", "sbin", .{}) catch {};
    _ = target_dir.symLink(io, "usr/lib", "lib", .{}) catch {};
    if (triplet.is64BitArch(arch)) {
        _ = target_dir.symLink(io, "usr/lib64", "lib64", .{}) catch {};
    }

    // 3. Write etc/ld.so.conf and etc/ld.so.conf.d/{triplet}.conf
    var ld_conf_file = try target_dir.createFile(io, "etc/ld.so.conf", .{ .exclusive = false });
    defer ld_conf_file.close(io);

    var ld_buf: [2048]u8 = undefined;
    const ld_content = try std.fmt.bufPrint(&ld_buf,
        \\/usr/local/lib
        \\/usr/local/lib/{s}
        \\/usr/lib/{s}
        \\/lib/{s}
        \\/usr/lib
        \\/lib
        \\include /etc/ld.so.conf.d/*.conf
        \\
    , .{ trp, trp, trp });
    try ld_conf_file.writeStreamingAll(io, ld_content);

    var triplet_conf_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const triplet_conf_path = try std.fmt.bufPrint(&triplet_conf_buf, "etc/ld.so.conf.d/{s}.conf", .{trp});
    var multiarch_conf = try target_dir.createFile(io, triplet_conf_path, .{ .exclusive = false });
    defer multiarch_conf.close(io);

    const multiarch_content = try std.fmt.bufPrint(&ld_buf,
        \\# Multiarch support
        \\/usr/local/lib/{s}
        \\/lib/{s}
        \\/usr/lib/{s}
        \\
    , .{ trp, trp, trp });
    try multiarch_conf.writeStreamingAll(io, multiarch_content);

    // 4. Create multiarch pkgconfig directories
    var triplet_pkgcfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const triplet_pkgcfg = try std.fmt.bufPrint(&triplet_pkgcfg_buf, "usr/lib/{s}/pkgconfig", .{trp});
    try target_dir.createDirPath(io, triplet_pkgcfg);
    try target_dir.createDirPath(io, "usr/lib/pkgconfig");
    try target_dir.createDirPath(io, "usr/share/pkgconfig");

    // 5. Write cross-compilation environment helper script (environment.sh)
    var env_file = try target_dir.createFile(io, "environment.sh", .{ .exclusive = false });
    defer env_file.close(io);

    var env_buf: [4096]u8 = undefined;
    const env_content = try std.fmt.bufPrint(&env_buf,
        \\# Source this script to configure cross-compilation environment for {s} ({s})
        \\export SYSROOT="$(cd "$(dirname "${{BASH_SOURCE[0]}}" )" >/dev/null 2>&1 && pwd)"
        \\export TARGET_TRIPLET="{s}"
        \\export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
        \\export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/{s}/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
        \\export PKG_CONFIG_PATH=""
        \\export CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include -I$SYSROOT/usr/include/{s}"
        \\export CXXFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include -I$SYSROOT/usr/include/{s}"
        \\export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib/{s} -L$SYSROOT/usr/lib"
        \\
    , .{ arch, trp, trp, trp, trp, trp, trp });
    try env_file.writeStreamingAll(io, env_content);
}

/// Computes the relative path from a directory path (relative to root) to a target path (relative to root).
pub fn computeRelativePath(gpa: Allocator, from_dir: []const u8, to_target: []const u8) ![]u8 {
    const clean_from = mem.trim(u8, from_dir, "/");
    const clean_to = mem.trim(u8, to_target, "/");

    var from_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer from_parts.deinit(gpa);
    if (clean_from.len > 0 and !mem.eql(u8, clean_from, ".")) {
        var it = mem.tokenizeScalar(u8, clean_from, '/');
        while (it.next()) |p| try from_parts.append(gpa, p);
    }

    var to_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_parts.deinit(gpa);
    if (clean_to.len > 0 and !mem.eql(u8, clean_to, ".")) {
        var it = mem.tokenizeScalar(u8, clean_to, '/');
        while (it.next()) |p| try to_parts.append(gpa, p);
    }

    // Find common prefix
    var common_len: usize = 0;
    while (common_len < from_parts.items.len and common_len < to_parts.items.len) {
        if (!mem.eql(u8, from_parts.items[common_len], to_parts.items[common_len])) break;
        common_len += 1;
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(gpa);

    const up_count = from_parts.items.len - common_len;
    for (0..up_count) |_| {
        try result.appendSlice(gpa, "../");
    }

    for (to_parts.items[common_len..], 0..) |part, idx| {
        if (idx > 0 or up_count > 0 and result.items[result.items.len - 1] != '/') {
            try result.append(gpa, '/');
        }
        try result.appendSlice(gpa, part);
    }

    if (result.items.len == 0) {
        try result.appendSlice(gpa, ".");
    }

    return result.toOwnedSlice(gpa);
}

/// Recursively scans target_root for symlinks and converts absolute symlinks into relative ones.
pub fn relativizeSymlinks(gpa: Allocator, io: std.Io, target_root: []const u8) !usize {
    var fixed_count: usize = 0;
    var root_dir = try std.Io.Dir.cwd().openDir(io, target_root, .{ .iterate = true });
    defer root_dir.close(io);

    var walker = try root_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) {
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const target_len = entry.dir.readLink(io, entry.basename, &target_buf) catch continue;
            const link_target = target_buf[0..target_len];

            // If the link points to an absolute path (starts with /), rewrite it
            if (mem.startsWith(u8, link_target, "/")) {
                const clean_target = mem.trimStart(u8, link_target, "/");
                const dirname = std.fs.path.dirname(entry.path) orelse "";
                const rel_link = try computeRelativePath(gpa, dirname, clean_target);
                defer gpa.free(rel_link);

                log.debug("Relativizing symlink: {s} -> {s} (was {s})", .{ entry.path, rel_link, link_target });

                // Remove existing absolute symlink and recreate as relative
                entry.dir.deleteFile(io, entry.basename) catch {};
                try entry.dir.symLink(io, rel_link, entry.basename, .{});
                fixed_count += 1;
            }
        }
    }

    return fixed_count;
}

/// Patches GNU ld scripts (e.g. libc.so, libpthread.so) by stripping hardcoded absolute paths inside GROUP(...)
pub fn patchLdScripts(gpa: Allocator, io: std.Io, target_root: []const u8) !usize {
    var patched_count: usize = 0;
    var root_dir = try std.Io.Dir.cwd().openDir(io, target_root, .{ .iterate = true });
    defer root_dir.close(io);

    var walker = try root_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and (mem.endsWith(u8, entry.basename, ".so") or mem.endsWith(u8, entry.basename, ".ld"))) {
            const content = entry.dir.readFileAlloc(io, entry.basename, gpa, .unlimited) catch continue;
            defer gpa.free(content);

            if (isGnuLdScript(content)) {
                if (patchLdScriptContent(gpa, content)) |patched| {
                    defer gpa.free(patched);
                    if (!mem.eql(u8, content, patched)) {
                        log.info("Patching GNU ld script: {s}", .{entry.path});
                        var f = try entry.dir.createFile(io, entry.basename, .{ .exclusive = false });
                        defer f.close(io);
                        try f.writeStreamingAll(io, patched);
                        patched_count += 1;
                    }
                }
            }
        }
    }

    return patched_count;
}

pub fn isGnuLdScript(content: []const u8) bool {
    return mem.indexOf(u8, content, "/* GNU ld script") != null or
        mem.indexOf(u8, content, "GROUP (") != null or
        mem.indexOf(u8, content, "GROUP(") != null;
}

pub fn patchLdScriptContent(gpa: Allocator, content: []const u8) ?[]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(gpa);

    var i: usize = 0;
    while (i < content.len) {
        // Look for tokens starting with '/' inside GROUP or general script
        if (content[i] == '/' and i + 1 < content.len and isPathChar(content[i + 1])) {
            // Start of an absolute path
            const start = i;
            while (i < content.len and isPathChar(content[i])) : (i += 1) {}
            const path = content[start..i];
            const base = std.fs.path.basename(path);
            result.appendSlice(gpa, base) catch return null;
        } else {
            result.append(gpa, content[i]) catch return null;
            i += 1;
        }
    }

    return result.toOwnedSlice(gpa) catch null;
}

fn isPathChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', '+' => true,
        else => false,
    };
}

test "computeRelativePath test cases" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const r1 = try computeRelativePath(gpa, "usr/lib/x86_64-linux-gnu", "lib/x86_64-linux-gnu/libm.so.6");
    defer gpa.free(r1);
    try testing.expectEqualStrings("../../../lib/x86_64-linux-gnu/libm.so.6", r1);

    const r2 = try computeRelativePath(gpa, "usr/lib/x86_64-linux-gnu", "usr/lib/x86_64-linux-gnu/libfoo.so.1");
    defer gpa.free(r2);
    try testing.expectEqualStrings("libfoo.so.1", r2);

    const r3 = try computeRelativePath(gpa, "usr/include", "usr/include/x86_64-linux-gnu/asm");
    defer gpa.free(r3);
    try testing.expectEqualStrings("x86_64-linux-gnu/asm", r3);
}

test "patchLdScriptContent strips absolute paths" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const script =
        \\/* GNU ld script
        \\   Use the shared library */
        \\OUTPUT_FORMAT(elf64-x86-64)
        \\GROUP ( /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc_nonshared.a AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )
    ;

    const patched = patchLdScriptContent(gpa, script).?;
    defer gpa.free(patched);

    const expected =
        \\/* GNU ld script
        \\   Use the shared library */
        \\OUTPUT_FORMAT(elf64-x86-64)
        \\GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux-x86-64.so.2 ) )
    ;

    try testing.expectEqualStrings(expected, patched);
}
