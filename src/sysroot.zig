const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Release = @import("deb/Release.zig");
const Package = @import("deb/Package.zig");
const rfc822 = @import("deb/rfc822.zig");
pub const Downloader = @import("sysroot/Downloader.zig");
pub const package = @import("sysroot/package.zig");
pub const fixup = @import("sysroot/fixup.zig");
pub const triplet = @import("sysroot/triplet.zig");
const bzip2 = @import("bzip2.zig");

const log = std.log.scoped(.sysroot);

pub const SysrootOptions = struct {
    suite: []const u8 = "bookworm",
    target: []const u8,
    mirror: []const u8 = "http://deb.debian.org/debian",
    arch: []const u8 = "amd64",
    packages: []const []const u8 = &.{},
    extra_debs: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    cache_dir: ?[]const u8 = null,
    download_only: bool = false,
    no_fixup: bool = false,
};

pub fn buildSysroot(gpa: Allocator, io: std.Io, options: SysrootOptions) !void {
    const deb_arch = triplet.normalizeDebianArch(options.arch);
    const trp = triplet.archToTriplet(options.arch);

    log.info("Building Debian sysroot for suite '{s}' (arch: {s}, triplet: {s}) at '{s}'", .{
        options.suite,
        deb_arch,
        trp,
        options.target,
    });

    // 1. Initialize sysroot directory layout and ld.so.conf
    try fixup.initSysrootLayout(io, options.target, options.arch);

    // 2. Setup download cache directory
    var default_cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_dir = if (options.cache_dir) |cd|
        cd
    else
        try std.fmt.bufPrint(&default_cache_buf, "{s}/var/cache/debsys", .{options.target});

    try std.Io.Dir.cwd().createDirPath(io, cache_dir);

    // 3. Setup downloader
    const downloader = Downloader.init(io, options.mirror);

    // 4. Download Release file
    var rel_path_buf: [256]u8 = undefined;
    const rel_url_path = try std.fmt.bufPrint(&rel_path_buf, "dists/{s}/Release", .{options.suite});

    log.info("Retrieving Release file for {s}...", .{options.suite});
    const release_bytes = downloader.fetchToMemory(gpa, rel_url_path) catch |err| {
        log.err("Failed to retrieve Release file: {any}", .{err});
        return err;
    };
    defer gpa.free(release_bytes);

    var release = try Release.parse(gpa, release_bytes);
    defer release.deinit(gpa);

    // 5. Download and parse Packages index
    var pkg_index: Package.Index = .{};
    defer pkg_index.deinit(gpa);

    const extensions = [_][]const u8{ ".xz", ".gz", ".bz2", ".zst", "" };
    var packages_decompressed: ?[]u8 = null;

    for (extensions) |ext| {
        var pkg_url_buf: [256]u8 = undefined;
        const pkg_rel_path = try std.fmt.bufPrint(&pkg_url_buf, "dists/{s}/main/binary-{s}/Packages{s}", .{
            options.suite,
            deb_arch,
            ext,
        });

        log.debug("Trying Packages index: {s}", .{pkg_rel_path});
        const comp_bytes = downloader.fetchToMemory(gpa, pkg_rel_path) catch continue;
        defer gpa.free(comp_bytes);

        // Validate checksum from Release if available
        var checksum_key_buf: [256]u8 = undefined;
        const checksum_key = try std.fmt.bufPrint(&checksum_key_buf, "main/binary-{s}/Packages{s}", .{
            deb_arch,
            ext,
        });
        if (release.getFile(checksum_key)) |rf| {
            if (rf.sha256.len > 0) {
                var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(comp_bytes, &hash, .{});
                const hash_hex = std.fmt.bytesToHex(hash, .lower);
                if (!mem.eql(u8, &hash_hex, rf.sha256[0..hash_hex.len])) {
                    log.warn("Checksum mismatch for Packages{s}, trying next format", .{ext});
                    continue;
                }
            }
        }

        // Decompress Packages index
        if (mem.eql(u8, ext, ".xz")) {
            var in_reader: std.Io.Reader = .fixed(comp_bytes);
            var decompress = std.compress.xz.Decompress.init(&in_reader, gpa, &.{}) catch continue;
            defer decompress.deinit();

            var out_writer: std.Io.Writer.Allocating = .init(gpa);
            defer out_writer.deinit();

            _ = decompress.reader.streamRemaining(&out_writer.writer) catch continue;
            packages_decompressed = try out_writer.toOwnedSlice();
            break;
        } else if (mem.eql(u8, ext, ".gz")) {
            var in_reader: std.Io.Reader = .fixed(comp_bytes);
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&in_reader, .gzip, &flate_buffer);

            var out_writer: std.Io.Writer.Allocating = .init(gpa);
            defer out_writer.deinit();

            _ = decompress.reader.streamRemaining(&out_writer.writer) catch continue;
            packages_decompressed = try out_writer.toOwnedSlice();
            break;
        } else if (mem.eql(u8, ext, ".bz2")) {
            var out_writer: std.Io.Writer.Allocating = .init(gpa);
            defer out_writer.deinit();

            bzip2.decompress(gpa, comp_bytes, &out_writer.writer) catch continue;
            packages_decompressed = try out_writer.toOwnedSlice();
            break;
        } else if (mem.eql(u8, ext, ".zst")) {
            var in_reader: std.Io.Reader = .fixed(comp_bytes);
            const zstd_buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
            defer gpa.free(zstd_buf);

            var decompress = std.compress.zstd.Decompress.init(&in_reader, zstd_buf, .{});
            var out_writer: std.Io.Writer.Allocating = .init(gpa);
            defer out_writer.deinit();

            _ = decompress.reader.streamRemaining(&out_writer.writer) catch continue;
            packages_decompressed = try out_writer.toOwnedSlice();
            break;
        } else {
            packages_decompressed = try gpa.dupe(u8, comp_bytes);
            break;
        }
    }

    const pkg_text = packages_decompressed orelse {
        log.err("Failed to retrieve or decompress Packages index", .{});
        return error.PackagesIndexNotFound;
    };
    defer gpa.free(pkg_text);

    // 6. Parse packages into PackageIndex
    log.info("Parsing package index...", .{});
    var p_it = rfc822.Iterator.init(pkg_text);
    while (try p_it.next(gpa)) |p| {
        var mut_p = p;
        defer mut_p.deinit(gpa);
        const pkg = Package.fromParagraph(gpa, &mut_p) catch continue;
        try pkg_index.addPackage(gpa, pkg);
    }

    // 7. Collect local .deb packages and inspect their control metadata
    var local_deb_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (local_deb_files.items) |f| gpa.free(f);
        local_deb_files.deinit(gpa);
    }

    var root_pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer root_pkgs.deinit(gpa);

    // Check extra_debs
    for (options.extra_debs) |item| {
        try collectDebFiles(gpa, io, item, &local_deb_files);
    }

    // Check packages for local file paths
    if (options.packages.len > 0) {
        for (options.packages) |p| {
            if (mem.endsWith(u8, p, ".deb") or mem.indexOfScalar(u8, p, '/') != null or mem.indexOfScalar(u8, p, '\\') != null) {
                // If it's a local path on disk
                if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| {
                    try collectDebFiles(gpa, io, p, &local_deb_files);
                    continue;
                } else |_| {}
            }
            try root_pkgs.append(gpa, p);
        }
    } else if (local_deb_files.items.len == 0) {
        // Default standard C/Linux sysroot dev packages if neither packages nor local debs specified
        try root_pkgs.append(gpa, "libc6-dev");
        try root_pkgs.append(gpa, "linux-libc-dev");
    }

    // Inspect local .deb packages: add to package index and root package list
    for (local_deb_files.items) |deb_path| {
        log.info("Inspecting local package '{s}'...", .{deb_path});
        if (try package.readDebControl(gpa, io, deb_path)) |pkg| {
            log.info("Found local package '{s}' ({s})", .{ pkg.name, pkg.raw_version });
            try root_pkgs.append(gpa, pkg.name);
            try pkg_index.addPackage(gpa, pkg);
        } else {
            log.warn("Could not read control from '{s}', will extract directly", .{deb_path});
        }
    }

    // 8. Resolve transitive dependency tree
    log.info("Resolving dependencies for {d} root packages...", .{root_pkgs.items.len});
    var resolved_pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer resolved_pkgs.deinit(gpa);

    try pkg_index.resolveDependencies(gpa, root_pkgs.items, &resolved_pkgs);

    // Filter out excludes
    var final_pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer final_pkgs.deinit(gpa);

    for (resolved_pkgs.items) |pkg_name| {
        var is_excluded = false;
        for (options.exclude) |ex| {
            if (std.ascii.eqlIgnoreCase(ex, pkg_name)) {
                is_excluded = true;
                break;
            }
        }
        if (!is_excluded) {
            try final_pkgs.append(gpa, pkg_name);
        }
    }

    log.info("Resolved {d} packages for sysroot", .{final_pkgs.items.len});
    for (final_pkgs.items) |p| {
        log.debug("  - {s}", .{p});
    }

    // 9. Download repository packages
    var deb_file_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (deb_file_paths.items) |f| gpa.free(f);
        deb_file_paths.deinit(gpa);
    }

    for (final_pkgs.items, 0..) |pkg_name, idx| {
        if (pkg_index.get(pkg_name)) |pkg| {
            if (pkg.filename.len > 0) {
                // Check if this package is one of our local files
                var is_local = false;
                for (local_deb_files.items) |ld| {
                    if (mem.eql(u8, pkg.filename, ld)) {
                        is_local = true;
                        break;
                    }
                }

                if (is_local) {
                    try deb_file_paths.append(gpa, try gpa.dupe(u8, pkg.filename));
                } else {
                    const base_fn = std.fs.path.basename(pkg.filename);
                    const local_deb_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cache_dir, base_fn });
                    try deb_file_paths.append(gpa, local_deb_path);

                    log.info("[{d}/{d}] Downloading {s}...", .{ idx + 1, final_pkgs.items.len, pkg_name });
                    try downloader.fetchAndVerify(gpa, pkg.filename, local_deb_path, pkg.sha256, pkg_name);
                }
            }
        } else {
            log.warn("Package metadata not found for {s}", .{pkg_name});
        }
    }

    // Also ensure all specified local_deb_files are included for extraction
    for (local_deb_files.items) |ld| {
        var already_included = false;
        for (deb_file_paths.items) |df| {
            if (mem.eql(u8, df, ld)) {
                already_included = true;
                break;
            }
        }
        if (!already_included) {
            try deb_file_paths.append(gpa, try gpa.dupe(u8, ld));
        }
    }

    if (options.download_only) {
        log.info("Download only requested, skipping extraction.", .{});
        return;
    }

    // 10. Extract all packages directly into target
    log.info("Extracting {d} packages into sysroot...", .{deb_file_paths.items.len});
    for (deb_file_paths.items, 0..) |deb_path, idx| {
        const pkg_display = std.fs.path.basename(deb_path);
        log.info("[{d}/{d}] Extracting {s}...", .{ idx + 1, deb_file_paths.items.len, pkg_display });
        package.extractDebToTarget(gpa, io, options.target, deb_path) catch |err| {
            log.err("Failed to extract package {s}: {any}", .{ deb_path, err });
            return err;
        };
    }

    // 11. Run sysroot fixups (relativizing symlinks & patching linker scripts)
    if (!options.no_fixup) {
        log.info("Post-processing sysroot...", .{});
        const num_links = try fixup.relativizeSymlinks(gpa, io, options.target);
        log.info("Relativized {d} absolute symlinks", .{num_links});

        const num_ld = try fixup.patchLdScripts(gpa, io, options.target);
        log.info("Patched {d} GNU ld linker scripts", .{num_ld});
    }

    log.info("Sysroot created successfully at '{s}'!", .{options.target});
}

pub const UnpackOptions = struct {
    /// Automatically relativize absolute symlinks and patch GNU ld scripts after extraction.
    fixup: bool = true,
};

/// Unpacks a single .deb package file (or all .deb files within a directory) into an existing sysroot.
pub fn unpackDeb(gpa: Allocator, io: std.Io, target_sysroot: []const u8, deb_path: []const u8, options: UnpackOptions) !void {
    try unpackDebs(gpa, io, target_sysroot, &.{deb_path}, options);
}

/// Unpacks a list of .deb package files (or directories containing .deb files) into an existing sysroot.
pub fn unpackDebs(gpa: Allocator, io: std.Io, target_sysroot: []const u8, deb_paths: []const []const u8, options: UnpackOptions) !void {
    var collected_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (collected_files.items) |f| gpa.free(f);
        collected_files.deinit(gpa);
    }

    for (deb_paths) |p| {
        try collectDebFiles(gpa, io, p, &collected_files);
    }

    if (collected_files.items.len == 0) {
        log.warn("No .deb packages found to unpack for target '{s}'", .{target_sysroot});
        return;
    }

    log.info("Unpacking {d} package(s) into sysroot '{s}'...", .{ collected_files.items.len, target_sysroot });
    for (collected_files.items, 0..) |deb_file, idx| {
        const base = std.fs.path.basename(deb_file);
        log.info("[{d}/{d}] Unpacking {s}...", .{ idx + 1, collected_files.items.len, base });
        try package.extractDebToTarget(gpa, io, target_sysroot, deb_file);
    }

    if (options.fixup) {
        log.info("Post-processing sysroot fixups...", .{});
        const num_links = try fixup.relativizeSymlinks(gpa, io, target_sysroot);
        log.info("Relativized {d} absolute symlinks", .{num_links});

        const num_ld = try fixup.patchLdScripts(gpa, io, target_sysroot);
        log.info("Patched {d} GNU ld linker scripts", .{num_ld});
    }

    log.info("Successfully unpacked packages into '{s}'!", .{target_sysroot});
}

fn collectDebFiles(gpa: Allocator, io: std.Io, input_path: []const u8, out_list: *std.ArrayListUnmanaged([]const u8)) !void {
    const stat = std.Io.Dir.cwd().statFile(io, input_path, .{}) catch |err| {
        // If single file path directly
        if (mem.endsWith(u8, input_path, ".deb")) {
            try out_list.append(gpa, try gpa.dupe(u8, input_path));
            return;
        }
        log.warn("Path '{s}' not accessible: {any}", .{ input_path, err });
        return;
    };

    if (stat.kind == .directory) {
        var dir = try std.Io.Dir.cwd().openDir(io, input_path, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.basename, ".deb")) {
                const full_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ input_path, entry.path });
                try out_list.append(gpa, full_path);
            }
        }
    } else {
        try out_list.append(gpa, try gpa.dupe(u8, input_path));
    }
}

test {
    _ = package;
    _ = fixup;
    _ = triplet;
    _ = Downloader;
}
