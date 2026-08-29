const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const rfc822 = @import("rfc822.zig");
const Version = @import("Version.zig");
const Package = @This();

pub const Priority = enum(u8) {
    unspecified = 0,
    extra = 1,
    optional = 2,
    standard = 3,
    important = 4,
    required = 5,

    pub fn fromString(str: []const u8) Priority {
        if (std.ascii.eqlIgnoreCase(str, "required")) return .required;
        if (std.ascii.eqlIgnoreCase(str, "important")) return .important;
        if (std.ascii.eqlIgnoreCase(str, "standard")) return .standard;
        if (std.ascii.eqlIgnoreCase(str, "optional")) return .optional;
        if (std.ascii.eqlIgnoreCase(str, "extra")) return .extra;
        return .unspecified;
    }

    pub fn isAtLeast(self: Priority, min: Priority) bool {
        return @intFromEnum(self) >= @intFromEnum(min);
    }
};

pub const Status = enum(u8) {
    not_installed = 0,
    half_installed = 1,
    unpacked = 2,
    half_configured = 3,
    installed = 4,

    pub fn fromString(str: []const u8) Status {
        if (std.ascii.eqlIgnoreCase(str, "installed")) return .installed;
        if (std.ascii.eqlIgnoreCase(str, "half-configured")) return .half_configured;
        if (std.ascii.eqlIgnoreCase(str, "unpacked")) return .unpacked;
        if (std.ascii.eqlIgnoreCase(str, "half-installed")) return .half_installed;
        return .not_installed;
    }
};

pub const Relation = enum {
    any,
    exact, // =
    less_or_equal, // <=
    greater_or_equal, // >=
    less, // << or <
    greater, // >> or >

    pub fn matches(self: Relation, pkg_ver: []const u8, dep_ver: []const u8) bool {
        if (self == .any) return true;
        const ord = Version.compare(pkg_ver, dep_ver);
        return switch (self) {
            .any => true,
            .exact => ord == .eq,
            .less_or_equal => ord == .lt or ord == .eq,
            .greater_or_equal => ord == .gt or ord == .eq,
            .less => ord == .lt,
            .greater => ord == .gt,
        };
    }
};

pub const Dependency = struct {
    package_name: []const u8,
    relation: Relation = .any,
    version: []const u8 = "",

    pub fn parse(raw: []const u8) Dependency {
        const trimmed = mem.trim(u8, raw, " \t\r\n");
        if (mem.indexOfScalar(u8, trimmed, '(')) |paren_open| {
            const name = mem.trim(u8, trimmed[0..paren_open], " \t");
            const paren_close = mem.indexOfScalar(u8, trimmed[paren_open..], ')') orelse (trimmed.len - paren_open);
            const inside_paren = mem.trim(u8, trimmed[paren_open + 1 .. paren_open + paren_close], " \t");

            var rel: Relation = .any;
            var ver: []const u8 = "";

            if (mem.startsWith(u8, inside_paren, "<=")) {
                rel = .less_or_equal;
                ver = mem.trim(u8, inside_paren[2..], " \t");
            } else if (mem.startsWith(u8, inside_paren, ">=")) {
                rel = .greater_or_equal;
                ver = mem.trim(u8, inside_paren[2..], " \t");
            } else if (mem.startsWith(u8, inside_paren, "<<")) {
                rel = .less;
                ver = mem.trim(u8, inside_paren[2..], " \t");
            } else if (mem.startsWith(u8, inside_paren, ">>")) {
                rel = .greater;
                ver = mem.trim(u8, inside_paren[2..], " \t");
            } else if (mem.startsWith(u8, inside_paren, "=")) {
                rel = .exact;
                ver = mem.trim(u8, inside_paren[1..], " \t");
            } else if (mem.startsWith(u8, inside_paren, "<")) {
                rel = .less_or_equal;
                ver = mem.trim(u8, inside_paren[1..], " \t");
            } else if (mem.startsWith(u8, inside_paren, ">")) {
                rel = .greater_or_equal;
                ver = mem.trim(u8, inside_paren[1..], " \t");
            } else {
                ver = inside_paren;
            }

            return .{
                .package_name = name,
                .relation = rel,
                .version = ver,
            };
        }

        return .{
            .package_name = trimmed,
            .relation = .any,
            .version = "",
        };
    }
};

/// Represents an alternative dependency group: `pkg1 (>= 1.0) | pkg2`
pub const DependencyAlternative = struct {
    alts: std.ArrayListUnmanaged(Dependency) = .empty,

    pub fn deinit(self: *DependencyAlternative, gpa: Allocator) void {
        self.alts.deinit(gpa);
    }
};

name: []const u8,
raw_version: []const u8 = "",
version: Version = .{},
architecture: []const u8 = "",
priority: Priority = .unspecified,
section: []const u8 = "",
essential: bool = false,
filename: []const u8 = "",
size: u64 = 0,
sha256: []const u8 = "",
md5: []const u8 = "",
status: Status = .not_installed,

depends: std.ArrayListUnmanaged(DependencyAlternative) = .empty,
pre_depends: std.ArrayListUnmanaged(DependencyAlternative) = .empty,
provides: std.ArrayListUnmanaged([]const u8) = .empty,

allocated_source: ?[]const u8 = null,
allocated_filename: ?[]const u8 = null,

pub fn deinit(self: *Package, gpa: Allocator) void {
    for (self.depends.items) |*alt| alt.deinit(gpa);
    self.depends.deinit(gpa);
    for (self.pre_depends.items) |*alt| alt.deinit(gpa);
    self.pre_depends.deinit(gpa);
    self.provides.deinit(gpa);

    if (self.allocated_source) |src| {
        gpa.free(src);
        self.allocated_source = null;
    }
    if (self.allocated_filename) |fn_str| {
        gpa.free(fn_str);
        self.allocated_filename = null;
    }
}

pub fn parseDependencies(gpa: Allocator, raw: []const u8, out_list: *std.ArrayListUnmanaged(DependencyAlternative)) !void {
    var it = mem.splitScalar(u8, raw, ',');
    while (it.next()) |chunk| {
        const trimmed = mem.trim(u8, chunk, " \t\r\n");
        if (trimmed.len == 0) continue;

        var alt: DependencyAlternative = .{};
        errdefer alt.deinit(gpa);

        var alt_it = mem.splitScalar(u8, trimmed, '|');
        while (alt_it.next()) |alt_chunk| {
            const alt_trimmed = mem.trim(u8, alt_chunk, " \t\r\n");
            if (alt_trimmed.len == 0) continue;
            try alt.alts.append(gpa, Dependency.parse(alt_trimmed));
        }

        if (alt.alts.items.len > 0) {
            try out_list.append(gpa, alt);
        }
    }
}

pub fn fromParagraph(gpa: Allocator, p: *const rfc822.Paragraph) !Package {
    const name = p.get("Package") orelse return error.MissingPackageName;
    const ver_str = p.get("Version") orelse "";
    const arch = p.get("Architecture") orelse "";
    const priority_str = p.get("Priority") orelse "";
    const section = p.get("Section") orelse "";
    const essential_str = p.get("Essential") orelse "";
    const filename = p.get("Filename") orelse "";
    const size_str = p.get("Size") orelse "0";
    const sha256_str = p.get("SHA256") orelse "";
    const md5_str = p.get("MD5sum") orelse "";

    var pkg: Package = .{
        .name = name,
        .raw_version = ver_str,
        .version = Version.parse(ver_str),
        .architecture = arch,
        .priority = Priority.fromString(priority_str),
        .section = section,
        .essential = std.ascii.eqlIgnoreCase(essential_str, "yes"),
        .filename = filename,
        .size = std.fmt.parseInt(u64, size_str, 10) catch 0,
        .sha256 = sha256_str,
        .md5 = md5_str,
        .status = .not_installed,
    };
    errdefer pkg.deinit(gpa);

    if (p.get("Depends")) |dep_str| {
        try parseDependencies(gpa, dep_str, &pkg.depends);
    }
    if (p.get("Pre-Depends")) |pdep_str| {
        try parseDependencies(gpa, pdep_str, &pkg.pre_depends);
    }
    if (p.get("Provides")) |prov_str| {
        var prov_it = mem.splitScalar(u8, prov_str, ',');
        while (prov_it.next()) |prov_item| {
            const prov_trimmed = mem.trim(u8, prov_item, " \t\r\n");
            if (prov_trimmed.len > 0) {
                try pkg.provides.append(gpa, prov_trimmed);
            }
        }
    }

    return pkg;
}

pub const Index = struct {
    packages: std.StringHashMapUnmanaged(Package) = .empty,
    provides_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    pub fn deinit(self: *Index, gpa: Allocator) void {
        var it = self.packages.valueIterator();
        while (it.next()) |pkg| {
            pkg.deinit(gpa);
        }
        self.packages.deinit(gpa);

        var prov_it = self.provides_map.valueIterator();
        while (prov_it.next()) |list| {
            list.deinit(gpa);
        }
        self.provides_map.deinit(gpa);
    }

    pub fn addPackage(self: *Index, gpa: Allocator, pkg: Package) !void {
        // If package with same name exists, check if newer
        if (self.packages.getPtr(pkg.name)) |existing| {
            if (pkg.version.order(existing.version) == .gt) {
                existing.deinit(gpa);
                existing.* = pkg;
            } else {
                var mut_pkg = pkg;
                mut_pkg.deinit(gpa);
            }
            return;
        }

        try self.packages.put(gpa, pkg.name, pkg);

        // Index provides
        for (pkg.provides.items) |prov| {
            const entry = try self.provides_map.getOrPut(gpa, prov);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(gpa, pkg.name);
        }
    }

    pub fn get(self: *const Index, name: []const u8) ?*const Package {
        return self.packages.getPtr(name);
    }

    pub fn getMut(self: *Index, name: []const u8) ?*Package {
        return self.packages.getPtr(name);
    }

    pub fn getOrVirtual(self: *const Index, name: []const u8) ?Package {
        if (self.packages.get(name)) |p| return p;
        if (self.provides_map.get(name)) |providers| {
            var best: ?Package = null;
            for (providers.items) |prov_name| {
                if (self.packages.get(prov_name)) |prov_pkg| {
                    if (best == null) {
                        best = prov_pkg;
                    } else if (prov_pkg.essential and !best.?.essential) {
                        best = prov_pkg;
                    } else if (@intFromEnum(prov_pkg.priority) > @intFromEnum(best.?.priority)) {
                        best = prov_pkg;
                    }
                }
            }
            return best;
        }
        return null;
    }

    /// Resolves dependencies starting from a root list of packages.
    pub fn resolveDependencies(
        self: *const Index,
        gpa: Allocator,
        roots: []const []const u8,
        result: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer visited.deinit(gpa);

        for (roots) |root| {
            try self.resolveRecurse(gpa, root, &visited, result);
        }
    }

    fn resolveRecurse(
        self: *const Index,
        gpa: Allocator,
        pkg_name: []const u8,
        visited: *std.StringHashMapUnmanaged(void),
        result: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        if (visited.contains(pkg_name)) return;

        const pkg = self.get(pkg_name) orelse {
            // Check if it is a virtual package provided by another package
            if (self.provides_map.get(pkg_name)) |providers| {
                if (providers.items.len > 0) {
                    return try self.resolveRecurse(gpa, providers.items[0], visited, result);
                }
            }
            return;
        };

        try visited.put(gpa, pkg.name, {});

        // Recurse on Pre-Depends first, then Depends
        const dep_lists = [_][]const DependencyAlternative{ pkg.pre_depends.items, pkg.depends.items };
        for (dep_lists) |dep_list| {
            for (dep_list) |dep| {
                var best_pkg: ?Package = null;
                for (dep.alts.items) |alt| {
                    if (self.getOrVirtual(alt.package_name)) |alt_pkg| {
                        if (best_pkg == null) {
                            best_pkg = alt_pkg;
                        } else {
                            if (std.mem.eql(u8, alt_pkg.name, "usr-is-merged")) {
                                best_pkg = alt_pkg;
                            } else if (alt_pkg.essential and !best_pkg.?.essential) {
                                best_pkg = alt_pkg;
                            } else if (@intFromEnum(alt_pkg.priority) > @intFromEnum(best_pkg.?.priority)) {
                                best_pkg = alt_pkg;
                            }
                        }
                    }
                }

                if (best_pkg) |selected| {
                    try self.resolveRecurse(gpa, selected.name, visited, result);
                }
            }
        }

        try result.append(gpa, pkg.name);
    }
};

test "Package parsing and dependency resolution" {
    const raw =
        \\Package: bash
        \\Version: 5.2.15-2
        \\Priority: required
        \\Essential: yes
        \\Depends: base-files (>= 1.0), libc6 (>= 2.34)
        \\
        \\Package: base-files
        \\Version: 12.4
        \\Priority: required
        \\Essential: yes
        \\
        \\Package: libc6
        \\Version: 2.36-9
        \\Priority: required
        \\Depends: libgcc-s1
        \\
        \\Package: libgcc-s1
        \\Version: 12.2.0-14
        \\Priority: required
        \\
    ;

    var it = rfc822.Iterator.init(raw);
    var index: Index = .{};
    defer index.deinit(testing.allocator);

    while (try it.next(testing.allocator)) |p| {
        var mut_p = p;
        defer mut_p.deinit(testing.allocator);
        const pkg = try Package.fromParagraph(testing.allocator, &mut_p);
        try index.addPackage(testing.allocator, pkg);
    }

    try testing.expect(index.get("bash") != null);
    try testing.expect(index.get("bash").?.essential);

    var resolved: std.ArrayListUnmanaged([]const u8) = .empty;
    defer resolved.deinit(testing.allocator);

    const roots = [_][]const u8{"bash"};
    try index.resolveDependencies(testing.allocator, &roots, &resolved);

    try testing.expectEqual(@as(usize, 4), resolved.items.len);
}

test "Virtual package and alternative dependency resolution" {
    const raw =
        \\Package: base-files
        \\Version: 12.4
        \\Priority: required
        \\Depends: awk
        \\
        \\Package: mawk
        \\Version: 1.3.4
        \\Priority: required
        \\Provides: awk
        \\
        \\Package: coreutils
        \\Version: 9.1-1
        \\Depends: usr-is-merged | usrmerge
        \\
        \\Package: usr-is-merged
        \\Version: 35
        \\Priority: required
        \\
        \\Package: usrmerge
        \\Version: 35
        \\Priority: optional
        \\
    ;

    var it = rfc822.Iterator.init(raw);
    var index: Index = .{};
    defer index.deinit(testing.allocator);

    while (try it.next(testing.allocator)) |p| {
        var mut_p = p;
        defer mut_p.deinit(testing.allocator);
        const pkg = try Package.fromParagraph(testing.allocator, &mut_p);
        try index.addPackage(testing.allocator, pkg);
    }

    var resolved: std.ArrayListUnmanaged([]const u8) = .empty;
    defer resolved.deinit(testing.allocator);

    const roots = [_][]const u8{ "base-files", "coreutils" };
    try index.resolveDependencies(testing.allocator, &roots, &resolved);

    // base-files + mawk (for awk) + coreutils + usr-is-merged (chosen over usrmerge)
    try testing.expectEqual(@as(usize, 4), resolved.items.len);
}
