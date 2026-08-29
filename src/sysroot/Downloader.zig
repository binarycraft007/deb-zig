const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Uri = std.Uri;
const Sha256 = std.crypto.hash.sha2.Sha256;
const log = std.log.scoped(.download);
const Downloader = @This();

mirror: []const u8,
io: std.Io,

pub fn init(io: std.Io, mirror: []const u8) Downloader {
    return .{
        .mirror = mem.trimEnd(u8, mirror, "/"),
        .io = io,
    };
}

/// Parses the base mirror string into a `std.Uri`.
pub fn parseMirrorUri(mirror: []const u8) !Uri {
    if (mem.startsWith(u8, mirror, "/")) {
        return Uri.parseAfterScheme("file", mirror);
    }
    return Uri.parse(mirror);
}

/// Builds a structured `std.Uri` representing the full resource location.
pub fn buildUri(self: *const Downloader, gpa: Allocator, path: []const u8) !Uri {
    const base_uri = try parseMirrorUri(self.mirror);
    const base_path = base_uri.path.percent_encoded;
    const trimmed_base = mem.trimEnd(u8, base_path, "/");
    const trimmed_rel = mem.trimStart(u8, path, "/");

    const combined_path = if (trimmed_base.len == 0)
        try std.fmt.allocPrint(gpa, "/{s}", .{trimmed_rel})
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ trimmed_base, trimmed_rel });

    var target_uri = base_uri;
    target_uri.path = .{ .percent_encoded = combined_path };
    return target_uri;
}

/// Formats the resource location as a URL string using `std.Uri`.
pub fn buildUrl(self: *const Downloader, gpa: Allocator, path: []const u8) ![]u8 {
    const uri = try self.buildUri(gpa, path);
    defer if (uri.path == .percent_encoded) gpa.free(uri.path.percent_encoded);

    return std.fmt.allocPrint(gpa, "{f}", .{Uri.fmt(&uri, .all)});
}

/// Streams the requested resource directly to a Writer without buffering into memory.
pub fn fetchToWriter(self: *const Downloader, gpa: Allocator, path: []const u8, writer: *std.Io.Writer) anyerror!void {
    // Support local files (e.g. file:///path or /path)
    if (mem.startsWith(u8, self.mirror, "file://") or mem.startsWith(u8, self.mirror, "/")) {
        const local_prefix = if (mem.startsWith(u8, self.mirror, "file://")) self.mirror[7..] else self.mirror;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_local = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ local_prefix, mem.trimStart(u8, path, "/") });

        var file = try std.Io.Dir.cwd().openFile(self.io, full_local, .{});
        defer file.close(self.io);

        var read_buf: [65536]u8 = undefined;
        var file_reader = file.reader(self.io, &read_buf);
        var stream_buf: [65536]u8 = undefined;
        while (true) {
            const n = try file_reader.interface.readSliceShort(&stream_buf);
            if (n == 0) break;
            try writer.writeAll(stream_buf[0..n]);
        }
        return;
    }

    const uri = try self.buildUri(gpa, path);
    defer if (uri.path == .percent_encoded) gpa.free(uri.path.percent_encoded);

    var client: std.http.Client = .{
        .allocator = gpa,
        .io = self.io,
    };
    defer client.deinit();

    const res = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = writer,
        .headers = .{
            .user_agent = .{ .override = "deb-zig/0.1.0" },
        },
    });

    if (res.status != .ok) {
        log.debug("HTTP status {d} for {f}", .{ @intFromEnum(res.status), Uri.fmt(&uri, .all) });
        return error.HttpError;
    }
}

/// Fetches the requested resource and streams it directly to a file on disk.
pub fn fetchToFile(self: *const Downloader, gpa: Allocator, path: []const u8, dest_path: []const u8) anyerror!void {
    if (std.fs.path.dirname(dest_path)) |dir_name| {
        std.Io.Dir.cwd().createDirPath(self.io, dir_name) catch {};
    }

    var file = try std.Io.Dir.cwd().createFile(self.io, dest_path, .{ .exclusive = false });
    defer file.close(self.io);

    var buf: [65536]u8 = undefined;
    var file_writer = file.writer(self.io, &buf);

    try self.fetchToWriter(gpa, path, &file_writer.interface);
    try file_writer.interface.flush();
}

/// Convenience helper to fetch a small resource (such as Release or control metadata) into memory.
pub fn fetchToMemory(self: *const Downloader, gpa: Allocator, path: []const u8) anyerror![]u8 {
    var body_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer body_writer.deinit();

    try self.fetchToWriter(gpa, path, &body_writer.writer);
    return body_writer.toOwnedSlice();
}

/// Fetches a package, streaming it directly to disk while computing its SHA-256 checksum on the fly,
/// and verifies the checksum without buffering the full file payload in memory.
pub fn fetchAndVerify(
    self: *const Downloader,
    gpa: Allocator,
    path: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8,
    pkg_name: []const u8,
) !void {
    // Check if destination file already exists and has matching hash using streaming SHA-256
    if (expected_sha256.len > 0) {
        if (std.Io.Dir.cwd().openFile(self.io, dest_path, .{})) |*file| {
            defer file.close(self.io);
            var hash_stream = Sha256.init(.{});
            var buf: [65536]u8 = undefined;
            var reader = file.reader(self.io, &buf);
            var match = true;
            while (true) {
                const n = reader.interface.readSliceShort(&buf) catch {
                    match = false;
                    break;
                };
                if (n == 0) break;
                hash_stream.update(buf[0..n]);
            }
            if (match) {
                var hash: [Sha256.digest_length]u8 = undefined;
                hash_stream.final(&hash);
                const hash_hex = std.fmt.bytesToHex(hash, .lower);
                if (mem.eql(u8, &hash_hex, expected_sha256[0..hash_hex.len])) {
                    log.debug("Using cached package for {s}", .{pkg_name});
                    return;
                }
            }
        } else |_| {}
    }

    log.info("Retrieving {s}", .{pkg_name});

    if (std.fs.path.dirname(dest_path)) |dir_name| {
        std.Io.Dir.cwd().createDirPath(self.io, dir_name) catch {};
    }

    var file = try std.Io.Dir.cwd().createFile(self.io, dest_path, .{ .exclusive = false });
    var file_closed = false;
    defer {
        if (!file_closed) file.close(self.io);
    }

    var file_buf: [65536]u8 = undefined;
    var file_writer = file.writer(self.io, &file_buf);

    if (expected_sha256.len > 0) {
        var hash_buf: [4096]u8 = undefined;
        var hashed = std.Io.Writer.Hashed(Sha256).initHasher(&file_writer.interface, Sha256.init(.{}), &hash_buf);

        self.fetchToWriter(gpa, path, &hashed.writer) catch |err| {
            file_closed = true;
            file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
            return err;
        };

        try hashed.writer.flush();
        try file_writer.interface.flush();

        var hash: [Sha256.digest_length]u8 = undefined;
        hashed.hasher.final(&hash);
        const hash_hex = std.fmt.bytesToHex(hash, .lower);

        if (!mem.eql(u8, &hash_hex, expected_sha256[0..hash_hex.len])) {
            log.debug("Checksum mismatch for {s}: expected {s}, got {s}", .{ pkg_name, expected_sha256, hash_hex });
            file_closed = true;
            file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
            return error.ChecksumMismatch;
        }
    } else {
        self.fetchToWriter(gpa, path, &file_writer.interface) catch |err| {
            file_closed = true;
            file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
            return err;
        };
        try file_writer.interface.flush();
    }
}

test "Downloader buildUrl and local file fetch" {
    const testing = std.testing;
    const io = testing.io;

    const dl = Downloader.init(io, "http://deb.debian.org/debian/");
    const url = try dl.buildUrl(testing.allocator, "/dists/bookworm/Release");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://deb.debian.org/debian/dists/bookworm/Release", url);

    const dl2 = Downloader.init(io, "https://deb.debian.org:8080/debian");
    const uri2 = try dl2.buildUri(testing.allocator, "pool/main/h/hello/hello_2.10.deb");
    defer if (uri2.path == .percent_encoded) testing.allocator.free(uri2.path.percent_encoded);
    try testing.expectEqualStrings("https", uri2.scheme);
    try testing.expectEqualStrings("deb.debian.org", uri2.host.?.percent_encoded);
    try testing.expectEqual(@as(?u16, 8080), uri2.port);
    try testing.expectEqualStrings("/debian/pool/main/h/hello/hello_2.10.deb", uri2.path.percent_encoded);

    const url2 = try dl2.buildUrl(testing.allocator, "pool/main/h/hello/hello_2.10.deb");
    defer testing.allocator.free(url2);
    try testing.expectEqualStrings("https://deb.debian.org:8080/debian/pool/main/h/hello/hello_2.10.deb", url2);


    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPath(io, &buf);
    const tmp_path = buf[0..path_len];

    // Create a local dummy file
    var f = try tmp_dir.dir.createFile(io, "dummy.txt", .{});
    var write_buf: [64]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    try writer.interface.writeAll("debsys local test content");
    try writer.interface.flush();
    f.close(io);

    var file_url_buf: [std.Io.Dir.max_path_bytes + 10]u8 = undefined;
    const file_url = try std.fmt.bufPrint(&file_url_buf, "file://{s}", .{tmp_path});

    const local_dl = Downloader.init(io, file_url);
    const content = try local_dl.fetchToMemory(testing.allocator, "dummy.txt");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("debsys local test content", content);
}

test "Downloader fetchToWriter and fetchToFile streaming" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPath(io, &buf);
    const tmp_path = buf[0..path_len];

    // Create source file
    {
        var f = try tmp_dir.dir.createFile(io, "source.bin", .{});
        defer f.close(io);
        var write_buf: [64]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll("streamed binary payload 12345");
        try writer.interface.flush();
    }

    var file_url_buf: [std.Io.Dir.max_path_bytes + 10]u8 = undefined;
    const file_url = try std.fmt.bufPrint(&file_url_buf, "file://{s}", .{tmp_path});
    const dl = Downloader.init(io, file_url);

    // 1. Test fetchToWriter
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    try dl.fetchToWriter(allocator, "source.bin", &alloc_writer.writer);
    try testing.expectEqualStrings("streamed binary payload 12345", alloc_writer.written());

    // 2. Test fetchToFile
    var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrint(&dest_buf, "{s}/dest.bin", .{tmp_path});
    try dl.fetchToFile(allocator, "source.bin", dest_path);

    const read_back = try tmp_dir.dir.readFileAlloc(io, "dest.bin", allocator, .unlimited);
    defer allocator.free(read_back);
    try testing.expectEqualStrings("streamed binary payload 12345", read_back);
}

test "Downloader fetchAndVerify streaming verification and caching" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPath(io, &buf);
    const tmp_path = buf[0..path_len];

    const payload = "verifiable package payload";
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &hash, .{});
    const hash_hex = std.fmt.bytesToHex(hash, .lower);

    // Create source file
    {
        var f = try tmp_dir.dir.createFile(io, "pkg.deb", .{});
        defer f.close(io);
        var write_buf: [64]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
    }

    var file_url_buf: [std.Io.Dir.max_path_bytes + 10]u8 = undefined;
    const file_url = try std.fmt.bufPrint(&file_url_buf, "file://{s}", .{tmp_path});
    const dl = Downloader.init(io, file_url);

    var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrint(&dest_buf, "{s}/verified.deb", .{tmp_path});

    // Fetch and verify with correct hash
    try dl.fetchAndVerify(allocator, "pkg.deb", dest_path, &hash_hex, "pkg");

    // Verify it was written correctly
    const read_back = try tmp_dir.dir.readFileAlloc(io, "verified.deb", allocator, .unlimited);
    defer allocator.free(read_back);
    try testing.expectEqualStrings(payload, read_back);

    // Call again to test cache path
    try dl.fetchAndVerify(allocator, "pkg.deb", dest_path, &hash_hex, "pkg");

    // Try fetchAndVerify with invalid hash
    var bad_dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bad_dest_path = try std.fmt.bufPrint(&bad_dest_buf, "{s}/bad.deb", .{tmp_path});
    const bad_hash = "0000000000000000000000000000000000000000000000000000000000000000";

    const err = dl.fetchAndVerify(allocator, "pkg.deb", bad_dest_path, bad_hash, "bad_pkg");
    try testing.expectError(error.ChecksumMismatch, err);

    // Ensure corrupted/mismatched file was cleaned up
    try testing.expectError(error.FileNotFound, tmp_dir.dir.openFile(io, "bad.deb", .{}));
}

