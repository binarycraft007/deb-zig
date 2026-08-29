const std = @import("std");
const testing = std.testing;
const triplet = sysroot.triplet;
const fixup = sysroot.fixup;
const sysroot = @import("sysroot.zig");
const ar = @import("ar.zig");
const tar = @import("tar.zig");
const rfc822 = @import("deb/rfc822.zig");
const Package = @import("deb/Package.zig");
const Version = @import("deb/Version.zig");

test {
    _ = ar;
    _ = tar;
    _ = rfc822;
    _ = Version;
    _ = Package;
    _ = @import("bzip2.zig");
    _ = @import("sysroot.zig");
    _ = @import("deb/Release.zig");
    _ = @import("deb/conf.zig");
    _ = @import("deb/Builder.zig");
}

test "Triplet architecture mapping" {
    try testing.expectEqualStrings("x86_64-linux-gnu", triplet.archToTriplet("amd64"));
    try testing.expectEqualStrings("aarch64-linux-gnu", triplet.archToTriplet("arm64"));
    try testing.expectEqualStrings("arm-linux-gnueabihf", triplet.archToTriplet("armhf"));
    try testing.expectEqualStrings("riscv64-linux-gnu", triplet.archToTriplet("riscv64"));
    try testing.expectEqualStrings("i386-linux-gnu", triplet.archToTriplet("i386"));
    try testing.expectEqualStrings("powerpc64le-linux-gnu", triplet.archToTriplet("ppc64el"));
    try testing.expectEqualStrings("s390x-linux-gnu", triplet.archToTriplet("s390x"));

    try testing.expect(triplet.is64BitArch("amd64"));
    try testing.expect(triplet.is64BitArch("arm64"));
    try testing.expect(!triplet.is64BitArch("armhf"));
    try testing.expect(!triplet.is64BitArch("i386"));
}

test "Sysroot layout creation and ld.so.conf generation" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const target_path = buf[0..path_len];

    try fixup.initSysrootLayout(io, target_path, "arm64");

    // Verify directories
    const inc_stat = try tmp.dir.statFile(io, "usr/include/aarch64-linux-gnu", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, inc_stat.kind);

    const lib_stat = try tmp.dir.statFile(io, "usr/lib/aarch64-linux-gnu", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, lib_stat.kind);

    // Verify ld.so.conf
    const ld_conf = try tmp.dir.readFileAlloc(io, "etc/ld.so.conf", testing.allocator, .unlimited);
    defer testing.allocator.free(ld_conf);
    try testing.expect(std.mem.indexOf(u8, ld_conf, "/usr/lib/aarch64-linux-gnu") != null);
    try testing.expect(std.mem.indexOf(u8, ld_conf, "/lib/aarch64-linux-gnu") != null);

    // Verify pkgconfig directories
    const pkgcfg_stat = try tmp.dir.statFile(io, "usr/lib/aarch64-linux-gnu/pkgconfig", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, pkgcfg_stat.kind);

    // Verify environment.sh
    const env_sh = try tmp.dir.readFileAlloc(io, "environment.sh", testing.allocator, .unlimited);
    defer testing.allocator.free(env_sh);
    try testing.expect(std.mem.indexOf(u8, env_sh, "export PKG_CONFIG_SYSROOT_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, env_sh, "aarch64-linux-gnu") != null);
}

test "Sysroot symlink relativization" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const target_path = buf[0..path_len];

    try tmp.dir.createDirPath(io, "usr/lib/x86_64-linux-gnu");
    try tmp.dir.createDirPath(io, "lib/x86_64-linux-gnu");

    // Create target file
    var target_file = try tmp.dir.createFile(io, "lib/x86_64-linux-gnu/libm.so.6", .{});
    target_file.close(io);

    // Create absolute symlink in usr/lib/x86_64-linux-gnu pointing to /lib/x86_64-linux-gnu/libm.so.6
    try tmp.dir.symLink(io, "/lib/x86_64-linux-gnu/libm.so.6", "usr/lib/x86_64-linux-gnu/libm.so", .{});

    // Run relativize
    const fixed = try fixup.relativizeSymlinks(testing.allocator, io, target_path);
    try testing.expectEqual(@as(usize, 1), fixed);

    // Verify new symlink is relative
    var read_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "usr/lib/x86_64-linux-gnu/libm.so", &read_buf);
    const new_link = read_buf[0..link_len];

    try testing.expectEqualStrings("../../../lib/x86_64-linux-gnu/libm.so.6", new_link);
}

test "GNU ld script patching" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const target_path = buf[0..path_len];

    try tmp.dir.createDirPath(io, "usr/lib/aarch64-linux-gnu");

    const raw_script =
        \\/* GNU ld script */
        \\OUTPUT_FORMAT(elf64-littleaarch64)
        \\GROUP ( /lib/aarch64-linux-gnu/libc.so.6 /usr/lib/aarch64-linux-gnu/libc_nonshared.a AS_NEEDED ( /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 ) )
    ;

    var script_file = try tmp.dir.createFile(io, "usr/lib/aarch64-linux-gnu/libc.so", .{});
    try script_file.writeStreamingAll(io, raw_script);
    script_file.close(io);

    const patched_count = try fixup.patchLdScripts(testing.allocator, io, target_path);
    try testing.expectEqual(@as(usize, 1), patched_count);

    const patched_content = try tmp.dir.readFileAlloc(io, "usr/lib/aarch64-linux-gnu/libc.so", testing.allocator, .unlimited);
    defer testing.allocator.free(patched_content);

    const expected =
        \\/* GNU ld script */
        \\OUTPUT_FORMAT(elf64-littleaarch64)
        \\GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux-aarch64.so.1 ) )
    ;

    try testing.expectEqualStrings(expected, patched_content);
}

test "Package dependency resolution with transitive C/C++ dev dependencies" {
    const raw_packages =
        \\Package: libc6-dev
        \\Version: 2.36-9
        \\Depends: libc6 (= 2.36-9), linux-libc-dev, libcrypt-dev
        \\
        \\Package: libc6
        \\Version: 2.36-9
        \\Depends: libgcc-s1
        \\
        \\Package: libgcc-s1
        \\Version: 12.2.0-14
        \\
        \\Package: linux-libc-dev
        \\Version: 6.1.27-1
        \\
        \\Package: libcrypt-dev
        \\Version: 1:4.4.33-2
        \\Depends: libcrypt1 (= 1:4.4.33-2)
        \\
        \\Package: libcrypt1
        \\Version: 1:4.4.33-2
        \\
    ;

    var p_it = rfc822.Iterator.init(raw_packages);
    var index: Package.Index = .{};
    defer index.deinit(testing.allocator);

    while (try p_it.next(testing.allocator)) |p| {
        var mut_p = p;
        defer mut_p.deinit(testing.allocator);
        const pkg = try Package.fromParagraph(testing.allocator, &mut_p);
        try index.addPackage(testing.allocator, pkg);
    }

    var resolved: std.ArrayListUnmanaged([]const u8) = .empty;
    defer resolved.deinit(testing.allocator);

    const roots = [_][]const u8{"libc6-dev"};
    try index.resolveDependencies(testing.allocator, &roots, &resolved);

    // Expected dependency closure: libgcc-s1 -> libc6 -> linux-libc-dev -> libcrypt1 -> libcrypt-dev -> libc6-dev
    try testing.expectEqual(@as(usize, 6), resolved.items.len);
}

test "Local deb package control reading and extraction" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..path_len];

    // 1. Create control.tar
    var control_tar_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer control_tar_alloc.deinit();

    var control_tar_writer: tar.Writer = .{ .underlying_writer = &control_tar_alloc.writer };
    const control_content =
        "Package: libcustom-dev\n" ++
        "Version: 1.0.0\n" ++
        "Architecture: arm64\n" ++
        "Depends: libssl-dev\n";
    try control_tar_writer.writeFileBytes("control", control_content, .{});

    // 2. Create data.tar
    var data_tar_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer data_tar_alloc.deinit();

    var data_tar_writer: tar.Writer = .{ .underlying_writer = &data_tar_alloc.writer };
    try data_tar_writer.writeFileBytes("usr/include/custom.h", "/* custom header */\n", .{});

    // 3. Create .deb (ar archive)
    var deb_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer deb_alloc.deinit();

    var ar_writer = try ar.Writer.init(&deb_alloc.writer);
    try ar_writer.addFileFromBytes("debian-binary", "2.0\n", .{ .mtime = 0 });
    try ar_writer.addFileFromBytes("control.tar", control_tar_alloc.written(), .{ .mtime = 0 });
    try ar_writer.addFileFromBytes("data.tar", data_tar_alloc.written(), .{ .mtime = 0 });

    // Write .deb to disk
    var deb_file = try tmp.dir.createFile(io, "libcustom-dev_1.0.0_arm64.deb", .{});
    try deb_file.writeStreamingAll(io, deb_alloc.written());
    deb_file.close(io);

    var deb_full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deb_full_path = try std.fmt.bufPrint(&deb_full_path_buf, "{s}/libcustom-dev_1.0.0_arm64.deb", .{tmp_path});

    // 4. Test readDebControl
    const pkg = (try sysroot.package.readDebControl(gpa, io, deb_full_path)).?;
    defer {
        var mut_pkg = pkg;
        mut_pkg.deinit(gpa);
    }

    try testing.expectEqualStrings("libcustom-dev", pkg.name);
    try testing.expectEqualStrings("1.0.0", pkg.raw_version);
    try testing.expectEqual(@as(usize, 1), pkg.depends.items.len);
    try testing.expectEqualStrings("libssl-dev", pkg.depends.items[0].alts.items[0].package_name);

    // 5. Test extraction to sysroot directory
    var sysroot_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sysroot_path = try std.fmt.bufPrint(&sysroot_dir_buf, "{s}/sysroot", .{tmp_path});
    try tmp.dir.createDirPath(io, "sysroot");

    try sysroot.package.extractDebToTarget(gpa, io, sysroot_path, deb_full_path);

    // Verify extracted file exists and has correct content
    const extracted_header = try tmp.dir.readFileAlloc(io, "sysroot/usr/include/custom.h", gpa, .unlimited);
    defer gpa.free(extracted_header);
    try testing.expectEqualStrings("/* custom header */\n", extracted_header);
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

test "Version formatting" {
    const v1 = Version.parse("2:1.0.0-1");
    var buf1: [64]u8 = undefined;
    var w1: std.Io.Writer = .fixed(&buf1);
    try v1.format(&w1);
    try testing.expectEqualStrings("2:1.0.0-1", w1.buffered());

    const v2 = Version{ .epoch = 1, .upstream = "2.3.4", .debian_revision = "5" };
    var buf2: [64]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try v2.format(&w2);
    try testing.expectEqualStrings("1:2.3.4-5", w2.buffered());
}

test "Builder with compression levels" {
    const allocator = testing.allocator;
    const Builder = @import("deb/Builder.zig");

    var builder = Builder.init(allocator);
    defer builder.deinit();

    builder.setControl(.{
        .package = "comp-test",
        .version = "1.0.0",
        .architecture = "all",
        .maintainer = "Test <test@example.com>",
        .description = "Compression level test",
    });

    try builder.addFile("usr/share/test.txt", "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ** 20, 0o644);

    var fast_out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer fast_out.deinit();
    try builder.write(allocator, &fast_out.writer, .{ .compression_level = .fastest });

    var best_out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer best_out.deinit();
    try builder.write(allocator, &best_out.writer, .{ .compression_level = .best });

    try testing.expect(fast_out.written().len > 0);
    try testing.expect(best_out.written().len > 0);
    try testing.expect(best_out.written().len <= fast_out.written().len);
}

test "Sysroot bootstrap trixie end-to-end" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const target_path = buf[0..path_len];

    var cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{target_path});

    try sysroot.buildSysroot(gpa, io, .{
        .suite = "trixie",
        .arch = "arm64",
        .target = target_path,
        .cache_dir = cache_path,
        .packages = &.{
            "libc6-dev",
        },
    });

    // Verify key directories, headers, libraries, and scripts exist
    const inc_stat = try tmp.dir.statFile(io, "usr/include/stdio.h", .{});
    try testing.expectEqual(std.Io.File.Kind.file, inc_stat.kind);

    const stubs_stat = try tmp.dir.statFile(io, "usr/include/aarch64-linux-gnu/gnu/stubs.h", .{});
    try testing.expectEqual(std.Io.File.Kind.file, stubs_stat.kind);

    const libc_stat = try tmp.dir.statFile(io, "usr/lib/aarch64-linux-gnu/libc.so", .{});
    try testing.expectEqual(std.Io.File.Kind.file, libc_stat.kind);

    const env_stat = try tmp.dir.statFile(io, "environment.sh", .{});
    try testing.expectEqual(std.Io.File.Kind.file, env_stat.kind);

    const ld_conf_stat = try tmp.dir.statFile(io, "etc/ld.so.conf", .{});
    try testing.expectEqual(std.Io.File.Kind.file, ld_conf_stat.kind);
}

test "unpackDeb and unpackDebs into existing sysroot" {
    const io = testing.io;
    const gpa = testing.allocator;
    const Builder = @import("deb/Builder.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &buf);
    const target_path = buf[0..path_len];

    var sysroot_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sysroot_path = try std.fmt.bufPrint(&sysroot_dir_buf, "{s}/sysroot", .{target_path});
    try tmp.dir.createDirPath(io, "sysroot");

    // 1. Initialize sysroot layout
    try fixup.initSysrootLayout(io, sysroot_path, "arm64");

    // 2. Create custom .deb package with Builder
    var builder = Builder.init(gpa);
    defer builder.deinit();

    builder.setControl(.{
        .package = "libmytest-dev",
        .version = "1.2.3",
        .architecture = "arm64",
        .maintainer = "Test <test@example.com>",
        .description = "Custom unpacked library",
    });

    try builder.addFile("usr/include/mytest.h", "#define MYTEST_VERSION 123\n", 0o644);
    try builder.addFile("usr/lib/aarch64-linux-gnu/libmytest.so.1.2.3", "BINARY_LIB_DATA", 0o755);
    try builder.addSymlink("usr/lib/aarch64-linux-gnu/libmytest.so", "libmytest.so.1.2.3");

    var deb_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deb_path = try std.fmt.bufPrint(&deb_path_buf, "{s}/libmytest-dev_1.2.3_arm64.deb", .{target_path});
    try builder.writeFile(io, gpa, deb_path, .{});

    // 3. Unpack into the existing sysroot
    try sysroot.unpackDeb(gpa, io, sysroot_path, deb_path, .{ .fixup = true });

    // 4. Verify extracted files in the existing sysroot
    const hdr = try tmp.dir.readFileAlloc(io, "sysroot/usr/include/mytest.h", gpa, .unlimited);
    defer gpa.free(hdr);
    try testing.expectEqualStrings("#define MYTEST_VERSION 123\n", hdr);

    const lib_stat = try tmp.dir.statFile(io, "sysroot/usr/lib/aarch64-linux-gnu/libmytest.so.1.2.3", .{});
    try testing.expectEqual(std.Io.File.Kind.file, lib_stat.kind);

    // 5. Test directory unpacking with unpackDebs
    var extra_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const extra_dir = try std.fmt.bufPrint(&extra_dir_buf, "{s}/extra_pkgs", .{target_path});
    try tmp.dir.createDirPath(io, "extra_pkgs");

    var builder2 = Builder.init(gpa);
    defer builder2.deinit();

    builder2.setControl(.{
        .package = "libextra-dev",
        .version = "2.0.0",
        .architecture = "arm64",
        .maintainer = "Test <test@example.com>",
        .description = "Extra library",
    });
    try builder2.addFile("usr/include/extra.h", "#define EXTRA 1\n", 0o644);

    var extra_deb_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const extra_deb_path = try std.fmt.bufPrint(&extra_deb_buf, "{s}/extra_pkgs/libextra-dev_2.0.0_arm64.deb", .{target_path});
    try builder2.writeFile(io, gpa, extra_deb_path, .{});

    try sysroot.unpackDebs(gpa, io, sysroot_path, &.{extra_dir}, .{ .fixup = true });

    const extra_hdr = try tmp.dir.readFileAlloc(io, "sysroot/usr/include/extra.h", gpa, .unlimited);
    defer gpa.free(extra_hdr);
    try testing.expectEqualStrings("#define EXTRA 1\n", extra_hdr);
}
