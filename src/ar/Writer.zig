const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const testing = std.testing;
const ar = @import("../ar.zig");

/// A writer for the 'ar' archive format.
///
/// This writer implements the common variant of the 'ar' format,
/// including support for long filenames using the BSD convention.
pub const Writer = @This();

pub const Header = ar.Header;

/// Options for writing a file entry to the archive.
pub const Options = struct {
    /// Modification time in seconds since the Unix epoch.
    mtime: i64,
    /// User ID.
    uid: posix.uid_t = 0,
    /// Group ID.
    gid: posix.gid_t = 0,
    /// File mode (e.g., 0o644).
    mode: posix.mode_t = 0o644,
};

writer: *std.Io.Writer,

pub const Error = std.Io.Writer.Error || std.fmt.BufPrintError || error{NameTooLong};

/// Initializes a new ar archive writer.
/// This writes the global 'ar' header to the underlying writer.
pub fn init(underlying_writer: *std.Io.Writer) !Writer {
    try underlying_writer.writeAll(ar.magic);
    return .{
        .writer = underlying_writer,
    };
}

/// Adds a file to the archive. The file content is read from the provided reader.
/// Handles long filenames using the BSD `ar` format convention.
pub fn addFile(
    self: *Writer,
    name: []const u8,
    size: u64,
    options: Options,
    reader: *std.Io.Reader,
) !void {
    if (name.len > 16) {
        return error.NameTooLong;
    } else {
        try self.addFileShort(name, size, options, reader);
    }
}

/// A convenience function to add a file to the archive from a byte slice.
pub fn addFileFromBytes(
    self: *Writer,
    name: []const u8,
    content: []const u8,
    options: Options,
) !void {
    var reader: std.Io.Reader = .fixed(content);
    try self.addFile(name, content.len, options, &reader);
}

fn addFileShort(
    self: *Writer,
    name: []const u8,
    size: u64,
    options: Options,
    reader: *std.Io.Reader,
) !void {
    var header: Header = .{};
    try header.setName(name);
    try header.setUid(options.uid);
    try header.setGid(options.gid);
    try header.setMtime(options.mtime);
    try header.setMode(options.mode);
    try header.setSize(size);

    try self.writer.writeStruct(header, .big);
    try reader.streamExact64(self.writer, size);

    if (size % 2 != 0) {
        try self.writer.writeByte('\n');
    }
}

test "ar writer with short filenames" {
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();

    var ar_writer = try Writer.init(&allocating.writer);

    const file1_options = Options{
        .mtime = 1234567890,
        .uid = 1000,
        .gid = 1000,
        .mode = 0o644,
    };
    try ar_writer.addFileFromBytes("hello.txt", "hello", file1_options);

    const file2_options = Options{
        .mtime = 1234567891,
        .uid = 500,
        .gid = 500,
        .mode = 0o755,
    };
    try ar_writer.addFileFromBytes("world.txt", "world!", file2_options);

    const expected_header1 = "hello.txt       1234567890  1000  1000  644     5         `\n";
    const expected_header2 = "world.txt       1234567891  500   500   755     6         `\n";

    var expected_content: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_content.deinit();

    try expected_content.writer.writeAll(ar.magic);
    try expected_content.writer.writeAll(expected_header1);
    try expected_content.writer.writeAll("hello\n"); // content + padding
    try expected_content.writer.writeAll(expected_header2);
    try expected_content.writer.writeAll("world!");

    try testing.expectEqualSlices(u8, expected_content.written(), allocating.written());
}
