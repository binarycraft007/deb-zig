//! Debian Package Assembler & Builder
//!
//! Provides high-level functionality to build and assemble valid, reproducible
//! Debian binary packages (`.deb`) either from a filesystem artifact directory or
//! programmatically in code.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Io = std.Io;
const Allocator = mem.Allocator;
const testing = std.testing;

const ar = @import("../ar.zig");
const tar = @import("../tar.zig");
const rfc822 = @import("rfc822.zig");
const version = @import("version.zig");
const package = @import("package.zig");

const Builder = @This();

raw_control: ?[]const u8 = null,
control_info: ?ControlInfo = null,

control_files: std.ArrayListUnmanaged(ControlFileEntry) = .empty,
payload_files: std.ArrayListUnmanaged(FileEntry) = .empty,
payload_dirs: std.ArrayListUnmanaged(DirEntry) = .empty,
payload_links: std.ArrayListUnmanaged(LinkEntry) = .empty,

arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator) Builder {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
}

/// Initializes a Builder directly from a ZON specification.
pub fn initFromZon(gpa: Allocator, zon: anytype) !Builder {
    var b = Builder.init(gpa);
    errdefer b.deinit();

    const T = @TypeOf(zon);
    if (@hasField(T, "control")) {
        try b.setControlZon(@field(zon, "control"));
    } else {
        try b.setControlZon(zon);
    }

    if (@hasField(T, "postinst")) {
        try b.setPostinst(@field(zon, "postinst"));
    }
    if (@hasField(T, "preinst")) {
        try b.setPreinst(@field(zon, "preinst"));
    }
    if (@hasField(T, "prerm")) {
        try b.setPrerm(@field(zon, "prerm"));
    }
    if (@hasField(T, "postrm")) {
        try b.setPostrm(@field(zon, "postrm"));
    }

    return b;
}

pub fn deinit(self: *Builder) void {
    self.arena.deinit();
}

pub fn setControl(self: *Builder, info: ControlInfo) void {
    self.control_info = info;
}

pub fn setControlZon(self: *Builder, zon: anytype) !void {
    const formatted = try rfc822.formatZon(self.arena.allocator(), zon);
    self.raw_control = formatted;
}

pub fn setRawControl(self: *Builder, raw: []const u8) void {
    self.raw_control = raw;
}

pub fn addFile(self: *Builder, sub_path: []const u8, content: []const u8, mode: u32) !void {
    const allocator = self.arena.allocator();
    const norm_path = try normalizeSubPath(allocator, sub_path);
    const dup_content = try allocator.dupe(u8, content);
    try self.payload_files.append(allocator, .{
        .sub_path = norm_path,
        .content = dup_content,
        .mode = mode,
    });
}

pub fn addDir(self: *Builder, sub_path: []const u8, mode: u32) !void {
    const allocator = self.arena.allocator();
    const norm_path = try normalizeSubPath(allocator, sub_path);
    try self.payload_dirs.append(allocator, .{
        .sub_path = norm_path,
        .mode = mode,
    });
}

pub fn addSymlink(self: *Builder, sub_path: []const u8, target: []const u8) !void {
    const allocator = self.arena.allocator();
    const norm_path = try normalizeSubPath(allocator, sub_path);
    const dup_target = try allocator.dupe(u8, target);
    try self.payload_links.append(allocator, .{
        .sub_path = norm_path,
        .target = dup_target,
    });
}

pub fn addControlFile(self: *Builder, name: []const u8, content: []const u8, mode: u32) !void {
    const allocator = self.arena.allocator();
    const dup_name = try allocator.dupe(u8, name);
    const dup_content = try allocator.dupe(u8, content);
    try self.control_files.append(allocator, .{
        .name = dup_name,
        .content = dup_content,
        .mode = mode,
    });
}

pub fn setPreinst(self: *Builder, script: []const u8) !void {
    try self.addControlFile("preinst", script, 0o755);
}

pub fn setPostinst(self: *Builder, script: []const u8) !void {
    try self.addControlFile("postinst", script, 0o755);
}

pub fn setPrerm(self: *Builder, script: []const u8) !void {
    try self.addControlFile("prerm", script, 0o755);
}

pub fn setPostrm(self: *Builder, script: []const u8) !void {
    try self.addControlFile("postrm", script, 0o755);
}

pub fn setConffiles(self: *Builder, content: []const u8) !void {
    try self.addControlFile("conffiles", content, 0o644);
}

/// Assembles the complete Debian package and writes it to `out_writer`.
pub fn write(self: *Builder, gpa: Allocator, out_writer: *std.Io.Writer, options: Options) !void {
    const arena = self.arena.allocator();

    if (options.validate) {
        try self.validate();
    }

    // 1. Determine Control file content
    var control_content: []const u8 = "";
    if (self.raw_control) |raw| {
        control_content = raw;
    } else if (self.control_info) |info| {
        var mut_info = info;
        if (options.auto_installed_size and mut_info.installed_size == null) {
            var total_bytes: u64 = 0;
            for (self.payload_files.items) |f| total_bytes += f.content.len;
            mut_info.installed_size = (total_bytes + 1023) / 1024;
        }
        control_content = try mut_info.format(arena);
    } else {
        return error.MissingControlMetadata;
    }

    // If auto_installed_size is enabled and raw_control was used without Installed-Size
    if (options.auto_installed_size and self.raw_control != null) {
        if (mem.indexOf(u8, control_content, "Installed-Size:") == null) {
            var total_bytes: u64 = 0;
            for (self.payload_files.items) |f| total_bytes += f.content.len;
            const sz_kib = (total_bytes + 1023) / 1024;
            var cb: std.Io.Writer.Allocating = try .initCapacity(arena, control_content.len + 64);
            try cb.writer.writeAll(control_content);
            if (control_content.len > 0 and control_content[control_content.len - 1] != '\n') {
                try cb.writer.writeByte('\n');
            }
            try cb.writer.print("Installed-Size: {d}\n", .{sz_kib});
            control_content = try cb.toOwnedSlice();
        }
    }

    // 2. Generate md5sums if enabled and not explicitly provided
    var has_md5sums = false;
    for (self.control_files.items) |cf| {
        if (mem.eql(u8, cf.name, "md5sums")) {
            has_md5sums = true;
            break;
        }
    }

    var md5sums_content: ?[]const u8 = null;
    if (options.auto_md5sums and !has_md5sums) {
        var md5_buf: std.Io.Writer.Allocating = try .initCapacity(arena, self.payload_files.items.len * 64);
        for (self.payload_files.items) |f| {
            var md5 = std.crypto.hash.Md5.init(.{});
            md5.update(f.content);
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            try md5_buf.writer.print("{s}  {s}\n", .{ hex, f.sub_path });
        }
        md5sums_content = try md5_buf.toOwnedSlice();
    }

    // 2. Build control.tar.gz
    var control_tar_buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer control_tar_buf.deinit();

    {
        var tw: tar.Writer = .{ .underlying_writer = &control_tar_buf.writer };
        const mtime = options.mtime;
        const uid = options.uid;
        const gid = options.gid;
        const uname = options.uname;
        const gname = options.gname;

        // Write ./
        try tw.writeDir(".", .{
            .mode = 0o755,
            .mtime = mtime,
            .uid = uid,
            .gid = gid,
            .uname = uname,
            .gname = gname,
        });

        // Write ./control
        try tw.writeFileBytes("./control", control_content, .{
            .mode = 0o644,
            .mtime = mtime,
            .uid = uid,
            .gid = gid,
            .uname = uname,
            .gname = gname,
        });

        // Write ./md5sums if generated
        if (md5sums_content) |md5_text| {
            try tw.writeFileBytes("./md5sums", md5_text, .{
                .mode = 0o644,
                .mtime = mtime,
                .uid = uid,
                .gid = gid,
                .uname = uname,
                .gname = gname,
            });
        }

        // Write all other control files
        for (self.control_files.items) |cf| {
            var path_buf: [128]u8 = undefined;
            const full_p = try std.fmt.bufPrint(&path_buf, "./{s}", .{cf.name});
            try tw.writeFileBytes(full_p, cf.content, .{
                .mode = cf.mode,
                .mtime = mtime,
                .uid = uid,
                .gid = gid,
                .uname = uname,
                .gname = gname,
            });
        }

        try tw.finishPedantically();
    }

    var control_gz: std.Io.Writer.Allocating = try .initCapacity(gpa, control_tar_buf.written().len + 512);
    defer control_gz.deinit();
    try gzipCompress(gpa, control_tar_buf.written(), &control_gz);

    // 3. Build data.tar.gz with automatic parent directory synthesis and deterministic sorting
    var data_tar_buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 16384);
    defer data_tar_buf.deinit();

    {
        var tw: tar.Writer = .{ .underlying_writer = &data_tar_buf.writer };
        const mtime = options.mtime;
        const uid = options.uid;
        const gid = options.gid;
        const uname = options.uname;
        const gname = options.gname;

        // Collect explicit and synthesized parent directory paths
        var dir_map: std.StringHashMapUnmanaged(u32) = .empty;

        for (self.payload_dirs.items) |d| {
            try dir_map.put(arena, d.sub_path, d.mode);
            var cur: []const u8 = d.sub_path;
            while (std.fs.path.dirname(cur)) |parent| {
                if (parent.len == 0 or mem.eql(u8, parent, ".")) break;
                if (!dir_map.contains(parent)) {
                    try dir_map.put(arena, parent, 0o755);
                }
                cur = parent;
            }
        }

        for (self.payload_files.items) |f| {
            var cur: []const u8 = f.sub_path;
            while (std.fs.path.dirname(cur)) |parent| {
                if (parent.len == 0 or mem.eql(u8, parent, ".")) break;
                if (!dir_map.contains(parent)) {
                    try dir_map.put(arena, parent, 0o755);
                }
                cur = parent;
            }
        }

        for (self.payload_links.items) |l| {
            var cur: []const u8 = l.sub_path;
            while (std.fs.path.dirname(cur)) |parent| {
                if (parent.len == 0 or mem.eql(u8, parent, ".")) break;
                if (!dir_map.contains(parent)) {
                    try dir_map.put(arena, parent, 0o755);
                }
                cur = parent;
            }
        }

        var sorted_dirs: std.ArrayListUnmanaged(DirEntry) = .empty;
        var dir_it = dir_map.iterator();
        while (dir_it.next()) |entry| {
            try sorted_dirs.append(arena, .{ .sub_path = entry.key_ptr.*, .mode = entry.value_ptr.* });
        }
        std.mem.sort(DirEntry, sorted_dirs.items, {}, struct {
            fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
                return mem.order(u8, a.sub_path, b.sub_path) == .lt;
            }
        }.lessThan);

        // Write ./
        try tw.writeDir(".", .{
            .mode = 0o755,
            .mtime = mtime,
            .uid = uid,
            .gid = gid,
            .uname = uname,
            .gname = gname,
        });

        // Write directories
        for (sorted_dirs.items) |d| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_p = try std.fmt.bufPrint(&path_buf, "./{s}", .{d.sub_path});
            try tw.writeDir(full_p, .{
                .mode = d.mode,
                .mtime = mtime,
                .uid = uid,
                .gid = gid,
                .uname = uname,
                .gname = gname,
            });
        }

        // Write files sorted
        const sorted_files = try arena.dupe(FileEntry, self.payload_files.items);
        std.mem.sort(FileEntry, sorted_files, {}, struct {
            fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
                return mem.order(u8, a.sub_path, b.sub_path) == .lt;
            }
        }.lessThan);

        for (sorted_files) |f| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_p = try std.fmt.bufPrint(&path_buf, "./{s}", .{f.sub_path});
            try tw.writeFileBytes(full_p, f.content, .{
                .mode = f.mode,
                .mtime = mtime,
                .uid = uid,
                .gid = gid,
                .uname = uname,
                .gname = gname,
            });
        }

        // Write symlinks sorted
        const sorted_links = try arena.dupe(LinkEntry, self.payload_links.items);
        std.mem.sort(LinkEntry, sorted_links, {}, struct {
            fn lessThan(_: void, a: LinkEntry, b: LinkEntry) bool {
                return mem.order(u8, a.sub_path, b.sub_path) == .lt;
            }
        }.lessThan);

        for (sorted_links) |l| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_p = try std.fmt.bufPrint(&path_buf, "./{s}", .{l.sub_path});
            try tw.writeLink(full_p, l.target, .{
                .mode = 0o777,
                .mtime = mtime,
                .uid = uid,
                .gid = gid,
                .uname = uname,
                .gname = gname,
            });
        }

        try tw.finishPedantically();
    }

    var data_gz: std.Io.Writer.Allocating = try .initCapacity(gpa, data_tar_buf.written().len + 512);
    defer data_gz.deinit();
    try gzipCompress(gpa, data_tar_buf.written(), &data_gz);

    // 4. Assemble final .deb via ar.Writer
    var aw = try ar.Writer.init(out_writer);
    const ar_opts = ar.Writer.Options{
        .mtime = @intCast(options.mtime),
        .uid = options.uid,
        .gid = options.gid,
        .mode = 0o100644,
    };

    try aw.addFileFromBytes("debian-binary", "2.0\n", ar_opts);
    try aw.addFileFromBytes("control.tar.gz", control_gz.written(), ar_opts);
    try aw.addFileFromBytes("data.tar.gz", data_gz.written(), ar_opts);
}

/// Assembles the Debian package and writes it directly to an on-disk file.
pub fn writeFile(self: *Builder, io: Io, gpa: Allocator, out_path: []const u8, options: Options) !void {
    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);

    var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 65536);
    defer buf.deinit();

    try self.write(gpa, &buf.writer, options);
    try out_file.writeStreamingAll(io, buf.written());
}

pub const Options = struct {
    /// Modification time for reproducible archives (0 = Unix epoch).
    mtime: u64 = 0,
    /// Owner UID for archive entries (0 = root).
    uid: u32 = 0,
    /// Owner GID for archive entries (0 = root).
    gid: u32 = 0,
    /// Owner username (default "root").
    uname: []const u8 = "root",
    /// Owner group name (default "root").
    gname: []const u8 = "root",
    /// Automatically calculate and inject `Installed-Size` into control if missing.
    auto_installed_size: bool = true,
    /// Automatically generate `md5sums` file if missing in control directory.
    auto_md5sums: bool = true,
    /// Validate package name, version, architecture, maintainer email, and control metadata.
    validate: bool = true,
};

pub const ValidationError = error{
    InvalidPackageName,
    InvalidPackageVersion,
    InvalidArchitecture,
    MissingMaintainer,
    InvalidMaintainerEmail,
    MissingDescription,
    InvalidConffilePath,
};

pub fn validatePackageName(name: []const u8) ValidationError!void {
    if (name.len < 2) return error.InvalidPackageName;
    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or (first >= '0' and first <= '9'))) {
        return error.InvalidPackageName;
    }
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.')) {
            return error.InvalidPackageName;
        }
    }
}

pub fn validatePackageVersion(ver: []const u8) ValidationError!void {
    if (ver.len == 0) return error.InvalidPackageVersion;

    var upstream = ver;
    if (mem.indexOfScalar(u8, ver, ':')) |colon| {
        if (colon == 0) return error.InvalidPackageVersion;
        for (ver[0..colon]) |c| {
            if (c < '0' or c > '9') return error.InvalidPackageVersion;
        }
        upstream = ver[colon + 1 ..];
        if (upstream.len == 0) return error.InvalidPackageVersion;
    }

    const first = upstream[0];
    if (first < '0' or first > '9') return error.InvalidPackageVersion;

    for (upstream) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '+' or c == '-' or c == '~'))
        {
            return error.InvalidPackageVersion;
        }
    }
}

pub fn validateArchitecture(arch: []const u8) ValidationError!void {
    if (arch.len == 0) return error.InvalidArchitecture;
    for (arch) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) {
            return error.InvalidArchitecture;
        }
    }
}

pub fn validateMaintainer(m: []const u8) ValidationError!void {
    if (m.len == 0) return error.MissingMaintainer;
    const start = mem.indexOfScalar(u8, m, '<') orelse return error.InvalidMaintainerEmail;
    const end = mem.indexOfScalar(u8, m, '>') orelse return error.InvalidMaintainerEmail;
    if (start >= end) return error.InvalidMaintainerEmail;
    const email = m[start + 1 .. end];
    if (mem.indexOfScalar(u8, email, '@') == null or email.len < 3) {
        return error.InvalidMaintainerEmail;
    }
}

pub fn validateDescription(desc: []const u8) ValidationError!void {
    if (desc.len == 0) return error.MissingDescription;
    const first_line = if (mem.indexOfScalar(u8, desc, '\n')) |i| desc[0..i] else desc;
    if (mem.trim(u8, first_line, " \t\r").len == 0) return error.MissingDescription;
}

pub fn validateConffiles(content: []const u8) ValidationError!void {
    var it = mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != '/') return error.InvalidConffilePath;
    }
}

pub fn validate(self: *const Builder) ValidationError!void {
    if (self.control_info) |info| {
        try info.validate();
    }
    for (self.control_files.items) |cf| {
        if (mem.eql(u8, cf.name, "conffiles")) {
            try validateConffiles(cf.content);
        }
    }
}

pub const ControlInfo = struct {
    package: []const u8,
    version: []const u8,
    architecture: []const u8 = "all",
    maintainer: []const u8,
    description: []const u8,
    section: ?[]const u8 = null,
    priority: ?[]const u8 = "optional",
    essential: bool = false,
    installed_size: ?u64 = null,
    homepage: ?[]const u8 = null,
    depends: ?[]const u8 = null,
    pre_depends: ?[]const u8 = null,
    recommends: ?[]const u8 = null,
    suggests: ?[]const u8 = null,
    enhances: ?[]const u8 = null,
    conflicts: ?[]const u8 = null,
    breaks: ?[]const u8 = null,
    provides: ?[]const u8 = null,
    replaces: ?[]const u8 = null,
    extra_fields: std.ArrayListUnmanaged(rfc822.Field) = .empty,

    pub fn deinit(self: *ControlInfo, gpa: Allocator) void {
        self.extra_fields.deinit(gpa);
    }

    pub fn validate(self: ControlInfo) ValidationError!void {
        try validatePackageName(self.package);
        try validatePackageVersion(self.version);
        try validateArchitecture(self.architecture);
        try validateMaintainer(self.maintainer);
        try validateDescription(self.description);
    }

    pub fn format(self: ControlInfo, gpa: Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        errdefer buf.deinit();

        var rw: rfc822.Writer = .init(&buf.writer);

        try rw.writeField("Package", self.package);
        try rw.writeField("Version", self.version);
        try rw.writeField("Architecture", self.architecture);
        try rw.writeField("Maintainer", self.maintainer);
        try rw.writeFieldOptional("Section", self.section);
        try rw.writeFieldOptional("Priority", self.priority);
        try rw.writeFieldBool("Essential", self.essential, "yes");
        try rw.writeFieldOptionalInt("Installed-Size", self.installed_size);
        try rw.writeFieldOptional("Homepage", self.homepage);
        try rw.writeFieldOptional("Depends", self.depends);
        try rw.writeFieldOptional("Pre-Depends", self.pre_depends);
        try rw.writeFieldOptional("Recommends", self.recommends);
        try rw.writeFieldOptional("Suggests", self.suggests);
        try rw.writeFieldOptional("Enhances", self.enhances);
        try rw.writeFieldOptional("Conflicts", self.conflicts);
        try rw.writeFieldOptional("Breaks", self.breaks);
        try rw.writeFieldOptional("Provides", self.provides);
        try rw.writeFieldOptional("Replaces", self.replaces);
        for (self.extra_fields.items) |f| {
            try rw.writeField(f.name, f.value);
        }
        try rw.writeField("Description", self.description);

        return buf.toOwnedSlice();
    }

    /// Constructs a ControlInfo from a ZON struct or anonymous struct literal.
    pub fn fromZon(zon: anytype) ControlInfo {
        const T = @TypeOf(zon);
        return .{
            .package = if (@hasField(T, "package")) @field(zon, "package") else "",
            .version = if (@hasField(T, "version")) @field(zon, "version") else "",
            .architecture = if (@hasField(T, "architecture"))
                @field(zon, "architecture")
            else if (@hasField(T, "arch"))
                @field(zon, "arch")
            else
                "all",
            .maintainer = if (@hasField(T, "maintainer")) @field(zon, "maintainer") else "",
            .description = if (@hasField(T, "description")) @field(zon, "description") else "",
            .section = if (@hasField(T, "section")) @field(zon, "section") else null,
            .priority = if (@hasField(T, "priority")) @field(zon, "priority") else "optional",
            .essential = if (@hasField(T, "essential")) @field(zon, "essential") else false,
            .installed_size = if (@hasField(T, "installed_size")) @field(zon, "installed_size") else null,
            .homepage = if (@hasField(T, "homepage")) @field(zon, "homepage") else null,
            .depends = if (@hasField(T, "depends")) @field(zon, "depends") else null,
            .pre_depends = if (@hasField(T, "pre_depends")) @field(zon, "pre_depends") else null,
            .recommends = if (@hasField(T, "recommends")) @field(zon, "recommends") else null,
            .suggests = if (@hasField(T, "suggests")) @field(zon, "suggests") else null,
            .enhances = if (@hasField(T, "enhances")) @field(zon, "enhances") else null,
            .conflicts = if (@hasField(T, "conflicts")) @field(zon, "conflicts") else null,
            .breaks = if (@hasField(T, "breaks")) @field(zon, "breaks") else null,
            .provides = if (@hasField(T, "provides")) @field(zon, "provides") else null,
            .replaces = if (@hasField(T, "replaces")) @field(zon, "replaces") else null,
        };
    }
};

pub const ZonControl = struct {
    package: []const u8 = "",
    version: []const u8 = "",
    architecture: []const u8 = "all",
    maintainer: []const u8 = "",
    description: []const u8 = "",
    section: ?[]const u8 = null,
    priority: ?[]const u8 = "optional",
    essential: bool = false,
    installed_size: ?u64 = null,
    homepage: ?[]const u8 = null,
    depends: ?[]const u8 = null,
    pre_depends: ?[]const u8 = null,
    recommends: ?[]const u8 = null,
    suggests: ?[]const u8 = null,
    enhances: ?[]const u8 = null,
    conflicts: ?[]const u8 = null,
    breaks: ?[]const u8 = null,
    provides: ?[]const u8 = null,
    replaces: ?[]const u8 = null,
};

pub const FileEntry = struct {
    sub_path: []const u8,
    content: []const u8,
    mode: u32 = 0o644,
};

pub const DirEntry = struct {
    sub_path: []const u8,
    mode: u32 = 0o755,
};

pub const LinkEntry = struct {
    sub_path: []const u8,
    target: []const u8,
};

pub const ControlFileEntry = struct {
    name: []const u8,
    content: []const u8,
    mode: u32 = 0o644,
};

/// Converts a ZON text buffer into an RFC-822 formatted control string.
pub fn convertZonToRfc822(gpa: Allocator, zon_source: [:0]const u8) ![]u8 {
    const parsed = std.zon.parse.fromSliceAlloc(ZonControl, gpa, zon_source, null, .{ .ignore_unknown_fields = true }) catch {
        return error.InvalidZonControl;
    };
    return rfc822.formatZon(gpa, parsed);
}

/// Assembles a Debian binary package from an on-disk artifact directory.
///
/// The directory structure should follow standard Debian layout:
/// - `<root>/DEBIAN/control` (or `deb.zon` / `control.zon`) containing package metadata
/// - `<root>/DEBIAN/postinst`, `preinst`, `prerm`, `postrm`, `conffiles` (optional)
/// - All other files in `<root>/` form the package payload (e.g. `usr/bin/hello`).
pub fn buildFromIoDir(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    out_writer: *std.Io.Writer,
    options: Options,
) !void {
    var builder = Builder.init(gpa);
    defer builder.deinit();

    // 1. Locate DEBIAN (or debian) control directory or root-level deb.zon
    var control_dir_name: ?[]const u8 = null;
    var control_dir_opt: ?Io.Dir = null;

    if (root_dir.openDir(io, "DEBIAN", .{ .iterate = true })) |d| {
        control_dir_name = "DEBIAN";
        control_dir_opt = d;
    } else |_| {
        if (root_dir.openDir(io, "debian", .{ .iterate = true })) |d| {
            control_dir_name = "debian";
            control_dir_opt = d;
        } else |_| {}
    }

    if (control_dir_opt) |control_dir| {
        defer control_dir.close(io);

        // Read control file or deb.zon/control.zon
        if (control_dir.readFileAlloc(io, "control", builder.arena.allocator(), .unlimited)) |control_content| {
            builder.setRawControl(control_content);
        } else |_| {
            if (control_dir.readFileAllocOptions(io, "deb.zon", builder.arena.allocator(), .unlimited, .of(u8), 0)) |zon_data| {
                const converted = try convertZonToRfc822(builder.arena.allocator(), zon_data);
                builder.setRawControl(converted);
            } else |_| {
                if (control_dir.readFileAllocOptions(io, "control.zon", builder.arena.allocator(), .unlimited, .of(u8), 0)) |zon_data| {
                    const converted = try convertZonToRfc822(builder.arena.allocator(), zon_data);
                    builder.setRawControl(converted);
                } else |_| {
                    return error.MissingControlFile;
                }
            }
        }

        // Read other files in control directory
        var ctrl_it = control_dir.iterate();
        while (try ctrl_it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (mem.eql(u8, entry.name, "control") or mem.eql(u8, entry.name, "deb.zon") or mem.eql(u8, entry.name, "control.zon")) continue;

            const content = try control_dir.readFileAlloc(io, entry.name, builder.arena.allocator(), .unlimited);
            const is_script = mem.eql(u8, entry.name, "preinst") or
                mem.eql(u8, entry.name, "postinst") or
                mem.eql(u8, entry.name, "prerm") or
                mem.eql(u8, entry.name, "postrm") or
                mem.eql(u8, entry.name, "config");

            const mode: u32 = if (is_script) 0o755 else 0o644;
            try builder.addControlFile(entry.name, content, mode);
        }
    } else {
        // No DEBIAN directory: check for root-level deb.zon or control.zon
        if (root_dir.readFileAllocOptions(io, "deb.zon", builder.arena.allocator(), .unlimited, .of(u8), 0)) |zon_data| {
            const converted = try convertZonToRfc822(builder.arena.allocator(), zon_data);
            builder.setRawControl(converted);
        } else |_| {
            if (root_dir.readFileAllocOptions(io, "control.zon", builder.arena.allocator(), .unlimited, .of(u8), 0)) |zon_data| {
                const converted = try convertZonToRfc822(builder.arena.allocator(), zon_data);
                builder.setRawControl(converted);
            } else |_| {
                return error.ControlDirectoryNotFound;
            }
        }
    }

    // 2. Walk payload files (everything outside DEBIAN / debian and *.zon metadata)
    var walk_dir = root_dir.openDir(io, ".", .{ .iterate = true }) catch root_dir;
    defer if (walk_dir.handle != root_dir.handle) walk_dir.close(io);

    var walker = try walk_dir.walk(builder.arena.allocator());
    defer walker.deinit();

    var collected_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var collected_files: std.ArrayListUnmanaged(CollectedFile) = .empty;
    var collected_links: std.ArrayListUnmanaged([]const u8) = .empty;

    while (try walker.next(io)) |entry| {
        const path_str = entry.path;
        if (control_dir_name) |cname| {
            if (mem.eql(u8, path_str, cname) or
                mem.startsWith(u8, path_str, "DEBIAN/") or
                mem.startsWith(u8, path_str, "DEBIAN\\") or
                mem.startsWith(u8, path_str, "debian/") or
                mem.startsWith(u8, path_str, "debian\\"))
            {
                continue;
            }
        }
        if (mem.eql(u8, path_str, "deb.zon") or mem.eql(u8, path_str, "control.zon")) {
            continue;
        }

        const dup_path = try builder.arena.allocator().dupe(u8, path_str);

        switch (entry.kind) {
            .directory => {
                try collected_dirs.append(builder.arena.allocator(), dup_path);
            },
            .file => {
                const stat = root_dir.statFile(io, path_str, .{}) catch |err| return err;
                const is_exec = (stat.permissions.toMode() & 0o111) != 0;
                try collected_files.append(builder.arena.allocator(), .{ .path = dup_path, .is_exec = is_exec });
            },
            .sym_link => {
                try collected_links.append(builder.arena.allocator(), dup_path);
            },
            else => {},
        }
    }

    // Sort entries deterministically
    std.mem.sort([]const u8, collected_dirs.items, {}, stringLessThan);
    for (collected_dirs.items) |dp| {
        try builder.addDir(dp, 0o755);
    }

    std.mem.sort(CollectedFile, collected_files.items, {}, fileStructLessThan);
    for (collected_files.items) |f| {
        const content = try root_dir.readFileAlloc(io, f.path, builder.arena.allocator(), .unlimited);
        const mode: u32 = if (f.is_exec) 0o755 else 0o644;
        try builder.addFile(f.path, content, mode);
    }

    std.mem.sort([]const u8, collected_links.items, {}, stringLessThan);
    var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (collected_links.items) |lp| {
        const target_len = try root_dir.readLink(io, lp, &link_target_buf);
        try builder.addSymlink(lp, link_target_buf[0..target_len]);
    }

    // 3. Write package
    try builder.write(gpa, out_writer, options);
}

/// Builds a Debian package directly from an on-disk artifact directory and writes to an output .deb file path.
pub fn buildFromDir(
    io: Io,
    gpa: Allocator,
    dir_path: []const u8,
    out_deb_path: []const u8,
    options: Options,
) !void {
    var root_dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer root_dir.close(io);

    var out_file = try Io.Dir.cwd().createFile(io, out_deb_path, .{});
    defer out_file.close(io);

    var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 65536);
    defer buf.deinit();

    try buildFromIoDir(io, gpa, root_dir, &buf.writer, options);
    try out_file.writeStreamingAll(io, buf.written());
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return mem.order(u8, a, b) == .lt;
}

const CollectedFile = struct {
    path: []const u8,
    is_exec: bool,
};

fn fileStructLessThan(_: void, a: CollectedFile, b: CollectedFile) bool {
    return mem.order(u8, a.path, b.path) == .lt;
}

fn normalizeSubPath(allocator: Allocator, sub_path: []const u8) ![]const u8 {
    var p = sub_path;
    while (mem.startsWith(u8, p, "./")) p = p[2..];
    while (mem.startsWith(u8, p, "/")) p = p[1..];
    while (mem.endsWith(u8, p, "/")) p = p[0 .. p.len - 1];
    return try allocator.dupe(u8, p);
}

/// Helper function to compress data using Gzip
pub fn gzipCompress(gpa: Allocator, uncompressed: []const u8, out_allocating: *std.Io.Writer.Allocating) !void {
    _ = gpa;
    var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(
        &out_allocating.writer,
        &window_buffer,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );
    try comp.writer.writeAll(uncompressed);
    try comp.finish();
}

test "PackageBuilder programmatic build" {
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    builder.setControl(.{
        .package = "hello-world",
        .version = "1.0.0-1",
        .architecture = "amd64",
        .maintainer = "Test Maintainer <test@example.com>",
        .description = "Hello World CLI package\n A sample package built with pure Zig deb assembler.",
        .section = "utils",
        .priority = "optional",
        .homepage = "https://example.com/hello",
    });

    try builder.addDir("usr", 0o755);
    try builder.addDir("usr/bin", 0o755);
    try builder.addFile("usr/bin/hello", "#!/bin/sh\necho 'Hello from Zig deb!'\n", 0o755);
    try builder.addSymlink("usr/bin/hello-alias", "hello");
    try builder.setPostinst("#!/bin/sh\necho 'Package installed successfully'\n");

    var out_deb: std.Io.Writer.Allocating = try .initCapacity(allocator, 8192);
    defer out_deb.deinit();

    try builder.write(allocator, &out_deb.writer, .{});

    // Inspect the generated .deb using ar.Iterator and tar.Iterator
    var ar_reader: std.Io.Reader = .fixed(out_deb.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    // 1. debian-binary
    const entry1 = (try ar_it.next()).?;
    try testing.expectEqualStrings("debian-binary", entry1.name);

    var db_buf: std.Io.Writer.Allocating = .init(allocator);
    defer db_buf.deinit();
    try ar_it.streamRemaining(entry1, &db_buf.writer);
    try testing.expectEqualStrings("2.0\n", db_buf.written());

    // 2. control.tar.gz
    const entry2 = (try ar_it.next()).?;
    try testing.expectEqualStrings("control.tar.gz", entry2.name);

    var ctar_gz: std.Io.Writer.Allocating = .init(allocator);
    defer ctar_gz.deinit();
    try ar_it.streamRemaining(entry2, &ctar_gz.writer);

    // Decompress control.tar.gz
    var c_in_reader: std.Io.Reader = .fixed(ctar_gz.written());
    var decomp_window: [std.compress.flate.max_window_len]u8 = undefined;
    var c_decomp = std.compress.flate.Decompress.init(&c_in_reader, .gzip, &decomp_window);
    var c_tar_data: std.Io.Writer.Allocating = .init(allocator);
    defer c_tar_data.deinit();
    var c_buf: [4096]u8 = undefined;
    while (true) {
        const n = try c_decomp.reader.readSliceShort(&c_buf);
        if (n == 0) break;
        try c_tar_data.writer.writeAll(c_buf[0..n]);
    }

    // Verify control tar entries
    var c_reader: std.Io.Reader = .fixed(c_tar_data.written());
    var fn_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ln_buf: [std.fs.max_path_bytes]u8 = undefined;
    var c_it: std.tar.Iterator = .init(&c_reader, .{
        .file_name_buffer = &fn_buf,
        .link_name_buffer = &ln_buf,
    });

    var has_control = false;
    var has_md5sums = false;
    var has_postinst = false;

    while (try c_it.next()) |c_ent| {
        if (mem.eql(u8, c_ent.name, "./control")) {
            has_control = true;
            var val_buf: std.Io.Writer.Allocating = .init(allocator);
            defer val_buf.deinit();
            try c_it.streamRemaining(c_ent, &val_buf.writer);
            try testing.expect(mem.indexOf(u8, val_buf.written(), "Package: hello-world") != null);
            try testing.expect(mem.indexOf(u8, val_buf.written(), "Installed-Size:") != null);
        } else if (mem.eql(u8, c_ent.name, "./md5sums")) {
            has_md5sums = true;
            var val_buf: std.Io.Writer.Allocating = .init(allocator);
            defer val_buf.deinit();
            try c_it.streamRemaining(c_ent, &val_buf.writer);
            try testing.expect(mem.indexOf(u8, val_buf.written(), "usr/bin/hello") != null);
        } else if (mem.eql(u8, c_ent.name, "./postinst")) {
            has_postinst = true;
        }
    }

    try testing.expect(has_control);
    try testing.expect(has_md5sums);
    try testing.expect(has_postinst);

    // 3. data.tar.gz
    const entry3 = (try ar_it.next()).?;
    try testing.expectEqualStrings("data.tar.gz", entry3.name);
}

test "buildFromIoDir end-to-end artifact assemble" {
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create an artifact tree:
    // tmp/DEBIAN/control
    // tmp/DEBIAN/postinst
    // tmp/usr/bin/mytool
    // tmp/usr/share/doc/mytool/copyright
    try tmp.dir.createDirPath(io, "DEBIAN");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.createDirPath(io, "usr/share/doc/mytool");

    {
        var f = try tmp.dir.createFile(io, "DEBIAN/control", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\Package: mytool
            \\Version: 2.1.0-1
            \\Architecture: amd64
            \\Maintainer: Developer <dev@example.com>
            \\Description: Fast native CLI tool
            \\
        );
    }

    {
        var f = try tmp.dir.createFile(io, "DEBIAN/postinst", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\necho configured\n");
    }

    {
        var f = try tmp.dir.createFile(io, "usr/bin/mytool", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "binary-data-here");
        try tmp.dir.setFilePermissions(io, "usr/bin/mytool", .executable_file, .{});
    }

    {
        var f = try tmp.dir.createFile(io, "usr/share/doc/mytool/copyright", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "MIT License\n");
    }

    // Assemble .deb directly from the directory
    var out_deb: std.Io.Writer.Allocating = try .initCapacity(allocator, 16384);
    defer out_deb.deinit();

    try buildFromIoDir(io, allocator, tmp.dir, &out_deb.writer, .{});

    // Verify .deb can be read back
    var ar_reader: std.Io.Reader = .fixed(out_deb.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    const m1 = (try ar_it.next()).?;
    try testing.expectEqualStrings("debian-binary", m1.name);

    const m2 = (try ar_it.next()).?;
    try testing.expectEqualStrings("control.tar.gz", m2.name);

    const m3 = (try ar_it.next()).?;
    try testing.expectEqualStrings("data.tar.gz", m3.name);

    try testing.expect((try ar_it.next()) == null);
}

test "ControlInfo multiline description formatting" {
    const allocator = testing.allocator;

    var info = ControlInfo{
        .package = "sample-pkg",
        .version = "1.0-1",
        .maintainer = "Jane Doe <jane@example.com>",
        .description =
        \\Sample short description
        \\Extended description paragraph 1.
        \\
        \\Extended description paragraph 2.
        ,
    };
    defer info.deinit(allocator);

    const formatted = try info.format(allocator);
    defer allocator.free(formatted);

    const expected =
        \\Package: sample-pkg
        \\Version: 1.0-1
        \\Architecture: all
        \\Maintainer: Jane Doe <jane@example.com>
        \\Priority: optional
        \\Description: Sample short description
        \\ Extended description paragraph 1.
        \\ .
        \\ Extended description paragraph 2.
        \\
    ;

    try testing.expectEqualStrings(expected, formatted);
}

test "buildFromDir file-to-file assemble and inspection" {
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "pkg_root/DEBIAN");
    try tmp.dir.createDirPath(io, "pkg_root/usr/bin");
    try tmp.dir.createDirPath(io, "pkg_root/etc");

    {
        var f = try tmp.dir.createFile(io, "pkg_root/DEBIAN/control", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\Package: myapp
            \\Version: 3.0.0
            \\Architecture: all
            \\Maintainer: Test <test@example.org>
            \\Description: My awesome app
            \\
        );
    }

    {
        var f = try tmp.dir.createFile(io, "pkg_root/usr/bin/myapp", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "echo 'Running myapp'\n");
    }

    {
        var f = try tmp.dir.createFile(io, "pkg_root/etc/myapp.conf", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "key = value\n");
    }

    var pkg_dir = try tmp.dir.openDir(io, "pkg_root", .{ .iterate = true });
    defer pkg_dir.close(io);

    var out_deb: std.Io.Writer.Allocating = try .initCapacity(allocator, 16384);
    defer out_deb.deinit();

    try buildFromIoDir(io, allocator, pkg_dir, &out_deb.writer, .{});

    // Verify generated payload in data.tar.gz
    var ar_reader: std.Io.Reader = .fixed(out_deb.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    _ = try ar_it.next(); // debian-binary
    _ = try ar_it.next(); // control.tar.gz

    const data_entry = (try ar_it.next()).?;
    try testing.expectEqualStrings("data.tar.gz", data_entry.name);

    var data_tar_gz: std.Io.Writer.Allocating = .init(allocator);
    defer data_tar_gz.deinit();
    try ar_it.streamRemaining(data_entry, &data_tar_gz.writer);

    var d_in_reader: std.Io.Reader = .fixed(data_tar_gz.written());
    var decomp_window: [std.compress.flate.max_window_len]u8 = undefined;
    var d_decomp = std.compress.flate.Decompress.init(&d_in_reader, .gzip, &decomp_window);
    var d_tar_data: std.Io.Writer.Allocating = .init(allocator);
    defer d_tar_data.deinit();
    var d_buf: [4096]u8 = undefined;
    while (true) {
        const n = try d_decomp.reader.readSliceShort(&d_buf);
        if (n == 0) break;
        try d_tar_data.writer.writeAll(d_buf[0..n]);
    }

    var d_reader: std.Io.Reader = .fixed(d_tar_data.written());
    var fn_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ln_buf: [std.fs.max_path_bytes]u8 = undefined;
    var d_it: std.tar.Iterator = .init(&d_reader, .{
        .file_name_buffer = &fn_buf,
        .link_name_buffer = &ln_buf,
    });

    var has_bin = false;
    var has_conf = false;

    while (try d_it.next()) |entry| {
        if (mem.eql(u8, entry.name, "./usr/bin/myapp")) {
            has_bin = true;
        } else if (mem.eql(u8, entry.name, "./etc/myapp.conf")) {
            has_conf = true;
        }
    }

    try testing.expect(has_bin);
    try testing.expect(has_conf);
}

test "PackageBuilder initFromZon and setControlZon" {
    const allocator = testing.allocator;

    var builder = try Builder.initFromZon(allocator, .{
        .control = .{
            .package = "zon-configured-pkg",
            .version = "1.0.0",
            .architecture = "all",
            .maintainer = "ZON Maintainer <zon@example.com>",
            .depends = .{ "libc6 (>= 2.34)", "libssl3" },
            .description =
            \\Configured via ZON
            \\Converted to RFC-822 during packaging.
            ,
        },
        .postinst =
        \\#!/bin/sh
        \\echo 'Configured via ZON'
        \\
        ,
    });
    defer builder.deinit();

    try builder.addFile("usr/bin/zon-app", "#!/bin/sh\necho zon\n", 0o755);

    var out_deb: std.Io.Writer.Allocating = try .initCapacity(allocator, 8192);
    defer out_deb.deinit();

    try builder.write(allocator, &out_deb.writer, .{});

    // Inspect control.tar.gz
    var ar_reader: std.Io.Reader = .fixed(out_deb.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    _ = try ar_it.next(); // debian-binary
    const c_entry = (try ar_it.next()).?;

    var ctar_gz: std.Io.Writer.Allocating = .init(allocator);
    defer ctar_gz.deinit();
    try ar_it.streamRemaining(c_entry, &ctar_gz.writer);

    var c_in_reader: std.Io.Reader = .fixed(ctar_gz.written());
    var decomp_window: [std.compress.flate.max_window_len]u8 = undefined;
    var c_decomp = std.compress.flate.Decompress.init(&c_in_reader, .gzip, &decomp_window);
    var c_tar_data: std.Io.Writer.Allocating = .init(allocator);
    defer c_tar_data.deinit();
    var c_buf: [4096]u8 = undefined;
    while (true) {
        const n = try c_decomp.reader.readSliceShort(&c_buf);
        if (n == 0) break;
        try c_tar_data.writer.writeAll(c_buf[0..n]);
    }

    var c_reader: std.Io.Reader = .fixed(c_tar_data.written());
    var fn_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ln_buf: [std.fs.max_path_bytes]u8 = undefined;
    var c_it: std.tar.Iterator = .init(&c_reader, .{
        .file_name_buffer = &fn_buf,
        .link_name_buffer = &ln_buf,
    });

    var found_control = false;
    while (try c_it.next()) |entry| {
        if (mem.eql(u8, entry.name, "./control")) {
            found_control = true;
            var ctrl_buf: std.Io.Writer.Allocating = .init(allocator);
            defer ctrl_buf.deinit();
            try c_it.streamRemaining(entry, &ctrl_buf.writer);

            try testing.expect(mem.indexOf(u8, ctrl_buf.written(), "Package: zon-configured-pkg\n") != null);
            try testing.expect(mem.indexOf(u8, ctrl_buf.written(), "Depends: libc6 (>= 2.34), libssl3\n") != null);
            try testing.expect(mem.indexOf(u8, ctrl_buf.written(), "Description: Configured via ZON\n Converted to RFC-822 during packaging.\n") != null);
        }
    }
    try testing.expect(found_control);
}

test "buildFromIoDir with deb.zon artifact" {
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "zon_pkg/usr/bin");

    // Write deb.zon at root of package directory
    {
        var f = try tmp.dir.createFile(io, "zon_pkg/deb.zon", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\.{
            \\    .package = "zon-artifact-pkg",
            \\    .version = "1.5.0",
            \\    .architecture = "amd64",
            \\    .maintainer = "Packager <packager@example.com>",
            \\    .description = "Built from deb.zon",
            \\}
        );
    }

    {
        var f = try tmp.dir.createFile(io, "zon_pkg/usr/bin/tool", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "tool-content");
    }

    var pkg_dir = try tmp.dir.openDir(io, "zon_pkg", .{ .iterate = true });
    defer pkg_dir.close(io);

    var out_deb: std.Io.Writer.Allocating = try .initCapacity(allocator, 16384);
    defer out_deb.deinit();

    try buildFromIoDir(io, allocator, pkg_dir, &out_deb.writer, .{});

    // Verify .deb members
    var ar_reader: std.Io.Reader = .fixed(out_deb.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    const m1 = (try ar_it.next()).?;
    try testing.expectEqualStrings("debian-binary", m1.name);

    const m2 = (try ar_it.next()).?;
    try testing.expectEqualStrings("control.tar.gz", m2.name);

    const m3 = (try ar_it.next()).?;
    try testing.expectEqualStrings("data.tar.gz", m3.name);
}

test "PackageBuilder Lintian policy validation" {
    const allocator = testing.allocator;

    // 1. Valid control metadata passes
    const valid_info = ControlInfo{
        .package = "my-awesome-tool",
        .version = "1:2.0.0-1~deb12",
        .architecture = "amd64",
        .maintainer = "Jane Doe <jane@example.com>",
        .description = "Awesome tool synopsis\nExtended description line.",
    };
    try valid_info.validate();

    // 2. Invalid package names
    const invalid_names = [_][]const u8{
        "MyTool", // uppercase
        "a", // too short (< 2)
        "-mytool", // starts with non-alphanumeric
        "my_tool", // contains underscore
        "tool name", // contains space
    };
    for (invalid_names) |bad_name| {
        var info = valid_info;
        info.package = bad_name;
        try testing.expectError(error.InvalidPackageName, info.validate());
    }

    // 3. Invalid versions
    const invalid_versions = [_][]const u8{
        "", // empty
        "v1.0.0", // does not start with digit
        ":1.0.0", // empty epoch
        "1.0.0:2.0", // invalid colon position
        "1.0 0", // contains space
    };
    for (invalid_versions) |bad_ver| {
        var info = valid_info;
        info.version = bad_ver;
        try testing.expectError(error.InvalidPackageVersion, info.validate());
    }

    // 4. Invalid architectures
    const invalid_archs = [_][]const u8{
        "", // empty
        "AMD64", // uppercase
        "arm 64", // contains space
        "x86_64", // contains underscore (Debian uses amd64)
    };
    for (invalid_archs) |bad_arch| {
        var info = valid_info;
        info.architecture = bad_arch;
        try testing.expectError(error.InvalidArchitecture, info.validate());
    }

    // 5. Invalid maintainer
    var bad_maint_info = valid_info;
    bad_maint_info.maintainer = "No Email Here";
    try testing.expectError(error.InvalidMaintainerEmail, bad_maint_info.validate());

    bad_maint_info.maintainer = "";
    try testing.expectError(error.MissingMaintainer, bad_maint_info.validate());

    // 6. Invalid description
    var bad_desc_info = valid_info;
    bad_desc_info.description = "";
    try testing.expectError(error.MissingDescription, bad_desc_info.validate());

    // 7. Invalid conffiles (must be absolute paths)
    var b = Builder.init(allocator);
    defer b.deinit();
    b.setControl(valid_info);
    try b.setConffiles("etc/myapp.conf\n"); // missing leading '/'
    try testing.expectError(error.InvalidConffilePath, b.validate());
}

test "PackageBuilder automatic parent directory synthesis" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    defer b.deinit();

    b.setControl(.{
        .package = "parent-dir-pkg",
        .version = "1.0.0",
        .architecture = "all",
        .maintainer = "Dev <dev@example.com>",
        .description = "Test parent dir auto-synthesis",
    });

    // Add nested files without explicitly adding their parent directories
    try b.addFile("usr/local/share/doc/myapp/guide.txt", "guide text", 0o644);
    try b.addFile("etc/opt/myapp/cfg.ini", "key=val", 0o640);
    try b.addSymlink("usr/local/bin/myapp-link", "myapp");

    var deb_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 16384);
    defer deb_buf.deinit();

    try b.write(allocator, &deb_buf.writer, .{});

    // Inspect data.tar.gz
    var ar_reader: std.Io.Reader = .fixed(deb_buf.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    _ = (try ar_it.next()).?; // debian-binary
    _ = (try ar_it.next()).?; // control.tar.gz
    const data_member = (try ar_it.next()).?; // data.tar.gz

    var data_gz_buf: std.Io.Writer.Allocating = .init(allocator);
    defer data_gz_buf.deinit();
    try ar_it.streamRemaining(data_member, &data_gz_buf.writer);

    var data_in_reader: std.Io.Reader = .fixed(data_gz_buf.written());
    var decomp_window: [std.compress.flate.max_window_len]u8 = undefined;
    var d_decomp = std.compress.flate.Decompress.init(&data_in_reader, .gzip, &decomp_window);
    var d_tar_buf: std.Io.Writer.Allocating = .init(allocator);
    defer d_tar_buf.deinit();
    var tmp_buf: [4096]u8 = undefined;
    while (true) {
        const n = try d_decomp.reader.readSliceShort(&tmp_buf);
        if (n == 0) break;
        try d_tar_buf.writer.writeAll(tmp_buf[0..n]);
    }

    var tar_r: std.Io.Reader = .fixed(d_tar_buf.written());
    var fn_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ln_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_r, .{
        .file_name_buffer = &fn_buf,
        .link_name_buffer = &ln_buf,
    });

    var has_etc = false;
    var has_etc_opt = false;
    var has_etc_opt_myapp = false;
    var has_usr = false;
    var has_usr_local = false;
    var has_usr_local_bin = false;
    var has_usr_local_share = false;
    var has_usr_local_share_doc = false;
    var has_usr_local_share_doc_myapp = false;

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            if (mem.eql(u8, entry.name, "./etc")) has_etc = true;
            if (mem.eql(u8, entry.name, "./etc/opt")) has_etc_opt = true;
            if (mem.eql(u8, entry.name, "./etc/opt/myapp")) has_etc_opt_myapp = true;
            if (mem.eql(u8, entry.name, "./usr")) has_usr = true;
            if (mem.eql(u8, entry.name, "./usr/local")) has_usr_local = true;
            if (mem.eql(u8, entry.name, "./usr/local/bin")) has_usr_local_bin = true;
            if (mem.eql(u8, entry.name, "./usr/local/share")) has_usr_local_share = true;
            if (mem.eql(u8, entry.name, "./usr/local/share/doc")) has_usr_local_share_doc = true;
            if (mem.eql(u8, entry.name, "./usr/local/share/doc/myapp")) has_usr_local_share_doc_myapp = true;
        }
    }

    try testing.expect(has_etc);
    try testing.expect(has_etc_opt);
    try testing.expect(has_etc_opt_myapp);
    try testing.expect(has_usr);
    try testing.expect(has_usr_local);
    try testing.expect(has_usr_local_bin);
    try testing.expect(has_usr_local_share);
    try testing.expect(has_usr_local_share_doc);
    try testing.expect(has_usr_local_share_doc_myapp);
}

test "PackageBuilder long path payload support" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    defer b.deinit();

    b.setControl(.{
        .package = "long-path-pkg",
        .version = "1.0.0",
        .architecture = "all",
        .maintainer = "Dev <dev@example.com>",
        .description = "Test long paths exceeding 256 bytes in debian package",
    });

    const long_sub_dir = "usr/share/my_extraordinarily_long_application_directory_structure_designed_specifically_to_exceed_posix_ustar_256_byte_path_limits_and_ensure_seamless_debian_packaging/nested_directory_level_two_with_further_path_depth/nested_directory_level_three";
    const long_file_path = long_sub_dir ++ "/long_named_resource_file_at_the_deepest_leaf_node.dat";
    const file_payload = "supercalifragilisticexpialidocious payload content";

    try b.addFile(long_file_path, file_payload, 0o644);

    var deb_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 32768);
    defer deb_buf.deinit();

    try b.write(allocator, &deb_buf.writer, .{});

    // Verify .deb can be read back and full long path is preserved
    var ar_reader: std.Io.Reader = .fixed(deb_buf.written());
    var ar_it = try ar.Iterator.init(allocator, &ar_reader);
    defer ar_it.deinit();

    _ = (try ar_it.next()).?; // debian-binary
    _ = (try ar_it.next()).?; // control.tar.gz
    const data_member = (try ar_it.next()).?; // data.tar.gz

    var data_gz_buf: std.Io.Writer.Allocating = .init(allocator);
    defer data_gz_buf.deinit();
    try ar_it.streamRemaining(data_member, &data_gz_buf.writer);

    var data_in_reader: std.Io.Reader = .fixed(data_gz_buf.written());
    var decomp_window: [std.compress.flate.max_window_len]u8 = undefined;
    var d_decomp = std.compress.flate.Decompress.init(&data_in_reader, .gzip, &decomp_window);
    var d_tar_buf: std.Io.Writer.Allocating = .init(allocator);
    defer d_tar_buf.deinit();
    var tmp_buf: [4096]u8 = undefined;
    while (true) {
        const n = try d_decomp.reader.readSliceShort(&tmp_buf);
        if (n == 0) break;
        try d_tar_buf.writer.writeAll(tmp_buf[0..n]);
    }

    var tar_r: std.Io.Reader = .fixed(d_tar_buf.written());
    var fn_buf: [1024]u8 = undefined;
    var ln_buf: [1024]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_r, .{
        .file_name_buffer = &fn_buf,
        .link_name_buffer = &ln_buf,
    });

    var found_long_file = false;
    while (try it.next()) |entry| {
        if (mem.eql(u8, entry.name, "./" ++ long_file_path)) {
            found_long_file = true;
            var val_buf: std.Io.Writer.Allocating = .init(allocator);
            defer val_buf.deinit();
            try it.streamRemaining(entry, &val_buf.writer);
            try testing.expectEqualStrings(file_payload, val_buf.written());
        }
    }

    try testing.expect(found_long_file);
}
