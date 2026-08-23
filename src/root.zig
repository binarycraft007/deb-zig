//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const ar = @import("ar.zig");
pub const tar = @import("tar.zig");

pub const bzip2 = @import("bzip2.zig");

test {
    std.testing.refAllDecls(@This());
}

test "interop generate tar and ar" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. Tar writer test with ownership and permissions
    var tar_buf: std.Io.Writer.Allocating = .init(allocator);
    defer tar_buf.deinit();

    var tw: tar.Writer = .{ .underlying_writer = &tar_buf.writer };
    try tw.writeDir("usr", .{ .mode = 0o755, .uid = 0, .gid = 0, .uname = "root", .gname = "root" });
    try tw.writeDir("usr/bin", .{ .mode = 0o755, .uid = 0, .gid = 0, .uname = "root", .gname = "root" });
    try tw.writeFileBytes("usr/bin/hello", "#!/bin/sh\necho hello\n", .{
        .mode = 0o755,
        .mtime = 1700000000,
        .uid = 0,
        .gid = 0,
        .uname = "root",
        .gname = "root",
    });
    try tw.writeLink("usr/bin/hello_symlink", "hello", .{
        .mode = 0o777,
        .uid = 0,
        .gid = 0,
        .uname = "root",
        .gname = "root",
    });
    try tw.finishPedantically();

    {
        var f = try tmp.dir.createFile(io, "test_out.tar", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, tar_buf.written());
    }

    // 2. AR writer (.deb structure)
    var deb_buf: std.Io.Writer.Allocating = .init(allocator);
    defer deb_buf.deinit();

    var aw = try ar.Writer.init(&deb_buf.writer);
    // Uses default options (.mtime = 0, .mode = 0o100644, .uid = 0, .gid = 0)
    try aw.addFileFromBytes("debian-binary", "2.0\n", .{});
    try aw.addFileFromBytes("control.tar.gz", "fake-control", .{});
    try aw.addFileFromBytes("data.tar.gz", "fake-data", .{});

    {
        var f = try tmp.dir.createFile(io, "test_out.deb", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, deb_buf.written());
    }

    // 3. Read back using tar.Iterator and ar.Iterator
    var tar_reader: std.Io.Reader = .fixed(tar_buf.written());
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var tar_it: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    const ent1 = (try tar_it.next()).?;
    try std.testing.expectEqualStrings("usr", ent1.name);
    try std.testing.expectEqual(std.tar.FileKind.directory, ent1.kind);
    const ent2 = (try tar_it.next()).?;
    try std.testing.expectEqualStrings("usr/bin", ent2.name);
    const ent3 = (try tar_it.next()).?;
    try std.testing.expectEqualStrings("usr/bin/hello", ent3.name);
    try std.testing.expectEqual(std.tar.FileKind.file, ent3.kind);
    const ent4 = (try tar_it.next()).?;
    try std.testing.expectEqualStrings("usr/bin/hello_symlink", ent4.name);
    try std.testing.expectEqual(std.tar.FileKind.sym_link, ent4.kind);
    try std.testing.expectEqualStrings("hello", ent4.link_name);

    var ar_reader: std.Io.Reader = .fixed(deb_buf.written());
    var ar_it: ar.Iterator = try .init(allocator, &ar_reader);
    defer ar_it.deinit();
    const deb1 = (try ar_it.next()).?;
    try std.testing.expectEqualStrings("debian-binary", deb1.name);
    const deb2 = (try ar_it.next()).?;
    try std.testing.expectEqualStrings("control.tar.gz", deb2.name);
    const deb3 = (try ar_it.next()).?;
    try std.testing.expectEqualStrings("data.tar.gz", deb3.name);
}

