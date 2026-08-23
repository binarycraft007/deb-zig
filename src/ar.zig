const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const testing = std.testing;
const assert = std.debug.assert;
const native_endian = @import("builtin").cpu.arch.endian();

pub const Writer = @import("ar/Writer.zig");

/// ar archive format global header magic string.
pub const magic = "!<arch>\n";

comptime {
    assert(@sizeOf(Header) == 60);
}

/// Represents the 60-byte header of a file member in an 'ar' archive.
/// All fields are left-aligned and padded with ASCII spaces. Numeric fields
/// are represented as decimal strings, except for the file mode, which is octal.
pub const Header = extern struct {
    name: [16]u8 align(1) = @splat(' '),
    mtime: [12]u8 align(1) = @splat(' '),
    uid: [6]u8 align(1) = @splat(' '),
    gid: [6]u8 align(1) = @splat(' '),
    mode: [8]u8 align(1) = @splat(' '),
    size: [10]u8 align(1) = @splat(' '),
    end: [2]u8 align(1) = [_]u8{ '`', '\n' },

    pub const SIZE = @sizeOf(@This());

    pub fn setName(w: *Header, value: []const u8) std.fmt.BufPrintError!void {
        @memset(&w.name, ' ');
        _ = try std.fmt.bufPrint(&w.name, "{s}", .{value});
    }

    pub fn setMtime(w: *Header, value: i64) std.fmt.BufPrintError!void {
        @memset(&w.mtime, ' ');
        _ = try std.fmt.bufPrint(&w.mtime, "{d}", .{value});
    }

    pub fn setUid(w: *Header, value: posix.uid_t) std.fmt.BufPrintError!void {
        @memset(&w.uid, ' ');
        _ = try std.fmt.bufPrint(&w.uid, "{d}", .{value});
    }

    pub fn setGid(w: *Header, value: posix.gid_t) std.fmt.BufPrintError!void {
        @memset(&w.gid, ' ');
        _ = try std.fmt.bufPrint(&w.gid, "{d}", .{value});
    }

    pub fn setMode(w: *Header, value: posix.mode_t) std.fmt.BufPrintError!void {
        @memset(&w.mode, ' ');
        _ = try std.fmt.bufPrint(&w.mode, "{o}", .{value});
    }

    pub fn setSize(w: *Header, value: usize) std.fmt.BufPrintError!void {
        @memset(&w.size, ' ');
        _ = try std.fmt.bufPrint(&w.size, "{d}", .{value});
    }

    pub fn getName(w: *const Header) []const u8 {
        return mem.trimEnd(u8, &w.name, " /");
    }

    pub fn getSize(w: *const Header) !u64 {
        const size_buf = mem.trimEnd(u8, &w.size, " ");
        return try std.fmt.parseInt(u64, size_buf, 10);
    }
};

/// Iterator over entries in the tar file represented by reader.
pub const Iterator = struct {
    reader: *std.Io.Reader,
    arena: std.heap.ArenaAllocator,
    header: Header = .{},

    // bytes of padding to the end of the block
    padding: bool = false,

    // not consumed bytes of file from last next iteration
    unread_file_bytes: u64 = 0,

    pub const File = struct {
        name: []const u8,
        size: u64 = 0,
    };

    pub fn init(gpa: mem.Allocator, reader: *std.Io.Reader) !Iterator {
        const magic_buf = try reader.takeArray(magic.len);
        if (!mem.eql(u8, magic_buf, magic))
            return error.InvalidArchiveMagic;
        return .{
            .arena = .init(gpa),
            .reader = reader,
        };
    }

    pub fn deinit(self: *Iterator) void {
        self.arena.deinit();
    }

    pub fn readHeader(self: *Iterator) !?*const Header {
        if (self.padding) {
            try self.reader.discardAll(1);
        }
        self.header = self.reader.takeStruct(Header, native_endian) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        return &self.header;
    }

    pub fn streamRemaining(it: *Iterator, file: File, w: *std.Io.Writer) std.Io.Reader.StreamError!void {
        try it.reader.streamExact64(w, file.size);
        it.unread_file_bytes = 0;
    }

    pub fn next(self: *Iterator) !?File {
        if (self.unread_file_bytes > 0) {
            // If file content was not consumed by caller
            try self.reader.discardAll64(self.unread_file_bytes);
            self.unread_file_bytes = 0;
        }
        const arena = self.arena.allocator();
        if (try self.readHeader()) |header| {
            const size = try header.getSize();
            self.padding = size % 2 != 0;
            self.unread_file_bytes = size;
            return .{
                .name = try arena.dupe(u8, header.getName()),
                .size = size,
            };
        }
        return null;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Iterator {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    var ar_writer = try Writer.init(&buffer.writer);
    try ar_writer.addFileFromBytes("hello.txt", "hello", .{
        .mtime = 1234567890,
        .uid = 1000,
        .gid = 1000,
        .mode = 0o644,
    });
    try ar_writer.addFileFromBytes("world.txt", "world!", .{
        .mtime = 1234567891,
        .uid = 500,
        .gid = 500,
        .mode = 0o755,
    });

    var reader: std.Io.Reader = .fixed(buffer.written());

    var it: Iterator = try .init(testing.allocator, &reader);
    defer it.deinit();
    {
        const file = (try it.next()).?;
        var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
        defer allocating.deinit();
        try it.streamRemaining(file, &allocating.writer);
        try testing.expectEqualStrings("hello.txt", file.name);
        try testing.expectEqualStrings("hello", allocating.written());
    }
    {
        const file = (try it.next()).?;
        var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
        defer allocating.deinit();
        try it.streamRemaining(file, &allocating.writer);
        try testing.expectEqualStrings("world.txt", file.name);
        try testing.expectEqualStrings("world!", allocating.written());
    }
}

