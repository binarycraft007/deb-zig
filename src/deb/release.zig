const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const rfc822 = @import("rfc822.zig");

pub const ReleaseFile = struct {
    path: []const u8,
    size: u64 = 0,
    sha256: []const u8 = "",
    md5: []const u8 = "",
};

pub const Release = struct {
    origin: []const u8 = "",
    label: []const u8 = "",
    suite: []const u8 = "",
    codename: []const u8 = "",
    architectures: std.ArrayListUnmanaged([]const u8) = .empty,
    components: std.ArrayListUnmanaged([]const u8) = .empty,
    files: std.StringHashMapUnmanaged(ReleaseFile) = .empty,

    pub fn deinit(self: *Release, gpa: Allocator) void {
        self.architectures.deinit(gpa);
        self.components.deinit(gpa);
        self.files.deinit(gpa);
    }

    pub fn parse(gpa: Allocator, raw: []const u8) !Release {
        var it = rfc822.Iterator.init(raw);
        var p = (try it.next(gpa)) orelse return error.EmptyReleaseFile;
        defer p.deinit(gpa);

        var rel: Release = .{
            .origin = p.get("Origin") orelse "",
            .label = p.get("Label") orelse "",
            .suite = p.get("Suite") orelse "",
            .codename = p.get("Codename") orelse "",
        };
        errdefer rel.deinit(gpa);

        if (p.get("Architectures")) |archs| {
            var a_it = mem.tokenizeAny(u8, archs, " \t\r\n");
            while (a_it.next()) |arch| {
                try rel.architectures.append(gpa, arch);
            }
        }

        if (p.get("Components")) |comps| {
            var c_it = mem.tokenizeAny(u8, comps, " \t\r\n");
            while (c_it.next()) |comp| {
                try rel.components.append(gpa, comp);
            }
        }

        // Parse SHA256 block
        if (p.get("SHA256")) |sha_block| {
            var line_it = mem.splitScalar(u8, sha_block, '\n');
            while (line_it.next()) |line| {
                var tok_it = mem.tokenizeAny(u8, line, " \t\r");
                const hash = tok_it.next() orelse continue;
                const size_str = tok_it.next() orelse continue;
                const path = tok_it.next() orelse continue;
                const size = std.fmt.parseInt(u64, size_str, 10) catch 0;

                const entry = try rel.files.getOrPut(gpa, path);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .path = path,
                        .size = size,
                        .sha256 = hash,
                    };
                } else {
                    entry.value_ptr.sha256 = hash;
                    entry.value_ptr.size = size;
                }
            }
        }

        // Parse MD5Sum block
        if (p.get("MD5Sum")) |md5_block| {
            var line_it = mem.splitScalar(u8, md5_block, '\n');
            while (line_it.next()) |line| {
                var tok_it = mem.tokenizeAny(u8, line, " \t\r");
                const hash = tok_it.next() orelse continue;
                const size_str = tok_it.next() orelse continue;
                const path = tok_it.next() orelse continue;
                const size = std.fmt.parseInt(u64, size_str, 10) catch 0;

                const entry = try rel.files.getOrPut(gpa, path);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .path = path,
                        .size = size,
                        .md5 = hash,
                    };
                } else {
                    entry.value_ptr.md5 = hash;
                }
            }
        }

        return rel;
    }

    pub fn getFile(self: *const Release, path: []const u8) ?ReleaseFile {
        return self.files.get(path);
    }
};

test "Release parsing" {
    const raw =
        \\Origin: Debian
        \\Label: Debian
        \\Suite: stable
        \\Codename: bookworm
        \\Architectures: all amd64 arm64
        \\Components: main contrib non-free
        \\SHA256:
        \\ e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 12345 main/binary-arm64/Packages.xz
        \\ 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 67890 main/binary-arm64/Packages.gz
        \\
    ;

    var rel = try Release.parse(testing.allocator, raw);
    defer rel.deinit(testing.allocator);

    try testing.expectEqualStrings("Debian", rel.origin);
    try testing.expectEqualStrings("bookworm", rel.codename);
    try testing.expectEqual(@as(usize, 3), rel.architectures.items.len);

    const f = rel.getFile("main/binary-arm64/Packages.xz").?;
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", f.sha256);
    try testing.expectEqual(@as(u64, 12345), f.size);
}
