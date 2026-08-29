const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.package);
const ar = @import("../ar.zig");
const tar = @import("../tar.zig");
const bzip2 = @import("../bzip2.zig");
const rfc822 = @import("../deb/rfc822.zig");
const Package = @import("../deb/Package.zig");

fn extractSelfGz(gpa: Allocator, io: std.Io, target_root: []const u8, reader: *std.Io.Reader, len: usize) !void {
    _ = len;
    _ = gpa;
    var dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer dir.close(io);

    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(reader, .gzip, &flate_buffer);
    try tar.extract(io, dir, &decompress.reader, .{
        .mode_mode = .preserve,
    });
}

fn extractSelfBz2(gpa: Allocator, io: std.Io, target_root: []const u8, reader: *std.Io.Reader, len: usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer dir.close(io);

    const comp_bytes = try reader.readAlloc(gpa, len);
    defer gpa.free(comp_bytes);

    var decomp_writer: std.Io.Writer.Allocating = .init(gpa);
    defer decomp_writer.deinit();

    try bzip2.decompress(gpa, comp_bytes, &decomp_writer.writer);
    const tar_bytes = try decomp_writer.toOwnedSlice();
    defer gpa.free(tar_bytes);

    var tar_reader: std.Io.Reader = .fixed(tar_bytes);
    try tar.extract(io, dir, &tar_reader, .{
        .mode_mode = .preserve,
    });
}

fn extractSelfXz(gpa: Allocator, io: std.Io, target_root: []const u8, reader: *std.Io.Reader, len: usize) !void {
    _ = len;
    var dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer dir.close(io);

    var decompress = try std.compress.xz.Decompress.init(reader, gpa, &.{});
    defer decompress.deinit();
    try tar.extract(io, dir, &decompress.reader, .{
        .mode_mode = .preserve,
    });
}

fn extractSelfZst(gpa: Allocator, io: std.Io, target_root: []const u8, reader: *std.Io.Reader, len: usize) !void {
    _ = len;
    var dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer dir.close(io);

    const buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(buffer);

    var decompress = std.compress.zstd.Decompress.init(reader, buffer, .{});
    try tar.extract(io, dir, &decompress.reader, .{
        .mode_mode = .preserve,
    });
}

fn extractSelfNull(gpa: Allocator, io: std.Io, target_root: []const u8, reader: *std.Io.Reader, len: usize) !void {
    _ = len;
    _ = gpa;
    var dir = try std.Io.Dir.cwd().openDir(io, target_root, .{});
    defer dir.close(io);

    try tar.extract(io, dir, reader, .{
        .mode_mode = .preserve,
    });
}

const DEBIAN_BINARY_CONTENT = "2.0\n";

pub const PackageExtractError = error{
    InvalidArchiveFormat,
    InvalidMemberFormat,
    InvalidMemberSize,
    InvalidDebianBinary,
    InvalidDebianPackage,
};

pub fn extractSelf(gpa: Allocator, io: std.Io, target_root: []const u8, file: std.Io.File) !void {
    var read_buffer: [4 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    const reader = &file_reader.interface;
    var it = try ar.Iterator.init(gpa, reader);
    defer it.deinit();

    var found_debian_binary: bool = false;
    var found_data_file: bool = false;

    while (try it.next()) |f| {
        log.debug("Found ar member: '{s}', size={d}", .{ f.name, f.size });
        if (std.mem.eql(u8, f.name, "debian-binary")) {
            found_debian_binary = true;
            if (f.size != DEBIAN_BINARY_CONTENT.len) return error.InvalidDebianBinary;
            var info_buf: [DEBIAN_BINARY_CONTENT.len]u8 = undefined;
            var info_writer: std.Io.Writer = .fixed(&info_buf);
            try it.streamRemaining(f, &info_writer);
            if (!std.mem.eql(u8, &info_buf, DEBIAN_BINARY_CONTENT)) {
                return error.InvalidDebianBinary;
            }
        } else if (std.mem.eql(u8, f.name, "data.tar.gz")) {
            found_data_file = true;
            defer it.unread_file_bytes = 0;
            return try extractSelfGz(gpa, io, target_root, reader, f.size);
        } else if (std.mem.eql(u8, f.name, "data.tar.bz2")) {
            found_data_file = true;
            defer it.unread_file_bytes = 0;
            return try extractSelfBz2(gpa, io, target_root, reader, f.size);
        } else if (std.mem.eql(u8, f.name, "data.tar.xz")) {
            found_data_file = true;
            defer it.unread_file_bytes = 0;
            return extractSelfXz(gpa, io, target_root, reader, f.size);
        } else if (std.mem.eql(u8, f.name, "data.tar.zst")) {
            found_data_file = true;
            defer it.unread_file_bytes = 0;
            return extractSelfZst(gpa, io, target_root, reader, f.size);
        } else if (std.mem.eql(u8, f.name, "data.tar")) {
            found_data_file = true;
            defer it.unread_file_bytes = 0;
            return try extractSelfNull(gpa, io, target_root, reader, f.size);
        }
    }

    if (!found_data_file or !found_debian_binary) {
        log.err("Invalid deb package: data={any}, binary={any}", .{ found_data_file, found_debian_binary });
        return error.InvalidDebianPackage;
    }
}

pub fn extractDebToTarget(gpa: Allocator, io: std.Io, target_root: []const u8, deb_path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, deb_path, .{});
    defer file.close(io);

    try extractSelf(gpa, io, target_root, file);
}

/// Reads package control metadata from a .deb file
pub fn readDebControl(gpa: Allocator, io: std.Io, deb_path: []const u8) !?Package {
    var file = std.Io.Dir.cwd().openFile(io, deb_path, .{}) catch |err| {
        log.warn("Could not open .deb file '{s}': {any}", .{ deb_path, err });
        return null;
    };
    defer file.close(io);

    var read_buffer: [4 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    const reader = &file_reader.interface;
    var it = try ar.Iterator.init(gpa, reader);
    defer it.deinit();

    while (try it.next()) |f| {
        if (mem.startsWith(u8, f.name, "control.tar")) {
            const comp_bytes = try reader.readAlloc(gpa, f.size);
            defer gpa.free(comp_bytes);
            it.unread_file_bytes = 0;

            var tar_bytes: ?[]u8 = null;
            if (mem.eql(u8, f.name, "control.tar.gz")) {
                var in_reader: std.Io.Reader = .fixed(comp_bytes);
                var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress: std.compress.flate.Decompress = .init(&in_reader, .gzip, &flate_buf);
                var out_writer: std.Io.Writer.Allocating = .init(gpa);
                defer out_writer.deinit();
                _ = try decompress.reader.streamRemaining(&out_writer.writer);
                tar_bytes = try out_writer.toOwnedSlice();
            } else if (mem.eql(u8, f.name, "control.tar.xz")) {
                var in_reader: std.Io.Reader = .fixed(comp_bytes);
                var decompress = try std.compress.xz.Decompress.init(&in_reader, gpa, &.{});
                defer decompress.deinit();
                var out_writer: std.Io.Writer.Allocating = .init(gpa);
                defer out_writer.deinit();
                _ = try decompress.reader.streamRemaining(&out_writer.writer);
                tar_bytes = try out_writer.toOwnedSlice();
            } else if (mem.eql(u8, f.name, "control.tar.zst")) {
                var in_reader: std.Io.Reader = .fixed(comp_bytes);
                const zstd_buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
                defer gpa.free(zstd_buf);
                var decompress = std.compress.zstd.Decompress.init(&in_reader, zstd_buf, .{});
                var out_writer: std.Io.Writer.Allocating = .init(gpa);
                defer out_writer.deinit();
                _ = try decompress.reader.streamRemaining(&out_writer.writer);
                tar_bytes = try out_writer.toOwnedSlice();
            } else if (mem.eql(u8, f.name, "control.tar")) {
                tar_bytes = try gpa.dupe(u8, comp_bytes);
            }

            if (tar_bytes) |tb| {
                defer gpa.free(tb);
                var tar_reader: std.Io.Reader = .fixed(tb);
                var file_name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var link_name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var tar_it: tar.Iterator = .init(&tar_reader, .{
                    .file_name_buffer = &file_name_buf,
                    .link_name_buffer = &link_name_buf,
                });
                while (try tar_it.next()) |tf| {
                    if (mem.eql(u8, tf.name, "control") or mem.eql(u8, tf.name, "./control")) {
                        const control_text = try tar_reader.readAlloc(gpa, tf.size);
                        errdefer gpa.free(control_text);
                        tar_it.unread_file_bytes = 0;

                        var p_it = rfc822.Iterator.init(control_text);
                        if (try p_it.next(gpa)) |p| {
                            var mut_p = p;
                            defer mut_p.deinit(gpa);
                            var pkg = try Package.fromParagraph(gpa, &mut_p);
                            const duped_fn = try gpa.dupe(u8, deb_path);
                            pkg.filename = duped_fn;
                            pkg.allocated_filename = duped_fn;
                            pkg.allocated_source = control_text;
                            return pkg;
                        } else {
                            gpa.free(control_text);
                        }
                    }
                }
            }
        }
    }
    return null;
}
