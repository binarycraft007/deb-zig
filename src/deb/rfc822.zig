//! RFC-822 / Debian 822 document parser, iterator, and writer.
//!
//! Complies with the Debian Policy Manual format for control files,
//! Package indices, and Release files.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Paragraph = struct {
    raw: []const u8 = "",
    fields: std.ArrayListUnmanaged(Field) = .empty,

    pub fn deinit(self: *Paragraph, gpa: Allocator) void {
        self.fields.deinit(gpa);
    }

    pub fn get(self: *const Paragraph, key: []const u8) ?[]const u8 {
        for (self.fields.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, key)) {
                return f.value;
            }
        }
        return null;
    }

    pub fn addField(self: *Paragraph, gpa: Allocator, name: []const u8, value: []const u8) !void {
        try self.fields.append(gpa, .{ .name = name, .value = value });
    }

    pub fn write(self: *const Paragraph, w: *std.Io.Writer) !void {
        var rw: Writer = .init(w);
        try rw.writeParagraph(self.fields.items);
    }

    pub fn format(self: *const Paragraph, gpa: Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        errdefer buf.deinit();
        try self.write(&buf.writer);
        return buf.toOwnedSlice();
    }
};

/// RFC-822 formatted stream writer.
///
/// Handles single-line fields, multiline field continuation (Debian policy compliant),
/// integer/optional fields, and paragraph separation.
pub const Writer = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) Writer {
        return .{ .writer = writer };
    }

    /// Writes a single field `Name: Value\n`.
    ///
    /// If `value` contains multiple lines, each continuation line is properly folded:
    /// - Non-empty continuation lines without leading whitespace receive a leading space (` `).
    /// - Empty lines are emitted as ` .\n` per Debian policy.
    pub fn writeField(self: *Writer, name: []const u8, value: []const u8) !void {
        const trimmed_val = mem.trimEnd(u8, value, "\r\n");
        if (mem.indexOfScalar(u8, trimmed_val, '\n')) |_| {
            var line_it = mem.splitScalar(u8, trimmed_val, '\n');
            var is_first = true;
            while (line_it.next()) |raw_line| {
                const line = if (mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
                if (is_first) {
                    try self.writer.print("{s}: {s}\n", .{ name, line });
                    is_first = false;
                } else {
                    const trimmed = mem.trim(u8, line, " \t");
                    if (trimmed.len == 0) {
                        try self.writer.writeAll(" .\n");
                    } else if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                        try self.writer.print("{s}\n", .{line});
                    } else {
                        try self.writer.print(" {s}\n", .{line});
                    }
                }
            }
        } else {
            try self.writer.print("{s}: {s}\n", .{ name, trimmed_val });
        }
    }

    /// Writes a field with integer value `Name: {d}\n`.
    pub fn writeFieldInt(self: *Writer, name: []const u8, val: anytype) !void {
        try self.writer.print("{s}: {d}\n", .{ name, val });
    }

    /// Writes a field if the optional slice is non-null.
    pub fn writeFieldOptional(self: *Writer, name: []const u8, val: ?[]const u8) !void {
        if (val) |v| {
            try self.writeField(name, v);
        }
    }

    /// Writes a field if the optional integer is non-null.
    pub fn writeFieldOptionalInt(self: *Writer, name: []const u8, val: anytype) !void {
        if (val) |v| {
            try self.writeFieldInt(name, v);
        }
    }

    /// Writes a boolean field (e.g. `Essential: yes`) if true.
    pub fn writeFieldBool(self: *Writer, name: []const u8, val: bool, true_str: []const u8) !void {
        if (val) {
            try self.writeField(name, true_str);
        }
    }

    /// Writes a comment line `# {comment}\n`.
    pub fn writeComment(self: *Writer, comment: []const u8) !void {
        try self.writer.print("# {s}\n", .{comment});
    }

    /// Writes all fields of a paragraph.
    pub fn writeParagraph(self: *Writer, fields: []const Field) !void {
        for (fields) |f| {
            try self.writeField(f.name, f.value);
        }
    }

    /// Ends the current paragraph with an empty line delimiter.
    pub fn endParagraph(self: *Writer) !void {
        try self.writer.writeByte('\n');
    }
};

/// Maps a Zig identifier / struct field name to a standard Debian RFC-822 field name.
pub fn rfc822FieldName(comptime field_name: []const u8) []const u8 {
    @setEvalBranchQuota(50_000);
    if (mem.indexOfScalar(u8, field_name, '-') != null) {
        return field_name;
    }
    if (std.ascii.eqlIgnoreCase(field_name, "package")) return "Package";
    if (std.ascii.eqlIgnoreCase(field_name, "version")) return "Version";
    if (std.ascii.eqlIgnoreCase(field_name, "architecture") or std.ascii.eqlIgnoreCase(field_name, "arch")) return "Architecture";
    if (std.ascii.eqlIgnoreCase(field_name, "maintainer")) return "Maintainer";
    if (std.ascii.eqlIgnoreCase(field_name, "description")) return "Description";
    if (std.ascii.eqlIgnoreCase(field_name, "section")) return "Section";
    if (std.ascii.eqlIgnoreCase(field_name, "priority")) return "Priority";
    if (std.ascii.eqlIgnoreCase(field_name, "essential")) return "Essential";
    if (std.ascii.eqlIgnoreCase(field_name, "installed_size") or std.ascii.eqlIgnoreCase(field_name, "installedsize")) return "Installed-Size";
    if (std.ascii.eqlIgnoreCase(field_name, "homepage")) return "Homepage";
    if (std.ascii.eqlIgnoreCase(field_name, "depends")) return "Depends";
    if (std.ascii.eqlIgnoreCase(field_name, "pre_depends") or std.ascii.eqlIgnoreCase(field_name, "predepends")) return "Pre-Depends";
    if (std.ascii.eqlIgnoreCase(field_name, "recommends")) return "Recommends";
    if (std.ascii.eqlIgnoreCase(field_name, "suggests")) return "Suggests";
    if (std.ascii.eqlIgnoreCase(field_name, "enhances")) return "Enhances";
    if (std.ascii.eqlIgnoreCase(field_name, "conflicts")) return "Conflicts";
    if (std.ascii.eqlIgnoreCase(field_name, "breaks")) return "Breaks";
    if (std.ascii.eqlIgnoreCase(field_name, "provides")) return "Provides";
    if (std.ascii.eqlIgnoreCase(field_name, "replaces")) return "Replaces";
    if (std.ascii.eqlIgnoreCase(field_name, "build_depends") or std.ascii.eqlIgnoreCase(field_name, "builddepends")) return "Build-Depends";
    if (std.ascii.eqlIgnoreCase(field_name, "build_depends_indep")) return "Build-Depends-Indep";
    if (std.ascii.eqlIgnoreCase(field_name, "standards_version") or std.ascii.eqlIgnoreCase(field_name, "standardsversion")) return "Standards-Version";
    if (std.ascii.eqlIgnoreCase(field_name, "vcs_git") or std.ascii.eqlIgnoreCase(field_name, "vcsgit")) return "Vcs-Git";
    if (std.ascii.eqlIgnoreCase(field_name, "vcs_browser") or std.ascii.eqlIgnoreCase(field_name, "vcsbrowser")) return "Vcs-Browser";

    comptime {
        var buf: [field_name.len]u8 = undefined;
        var capitalize_next = true;
        for (field_name, 0..) |c, i| {
            if (c == '_') {
                buf[i] = '-';
                capitalize_next = true;
            } else if (capitalize_next) {
                buf[i] = std.ascii.toUpper(c);
                capitalize_next = false;
            } else {
                buf[i] = c;
            }
        }
        const const_res = buf;
        return &const_res;
    }
}

/// Converts a ZON struct or anonymous struct literal into RFC-822 formatted string at runtime.
pub fn formatZon(gpa: Allocator, zon: anytype) ![]u8 {
    var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
    errdefer buf.deinit();

    var rw: Writer = .init(&buf.writer);
    try writeZon(&rw, zon);

    return buf.toOwnedSlice();
}

/// Formats a ZON struct or anonymous literal into RFC-822 format at compile time.
pub fn formatZonComptime(comptime zon: anytype) []const u8 {
    comptime {
        var buf: [16384]u8 = undefined;
        var fixed_writer: std.Io.Writer = .fixed(&buf);
        var rw: Writer = .init(&fixed_writer);
        writeZon(&rw, zon) catch unreachable;
        const out_len = fixed_writer.end;
        const result = buf[0..out_len].*;
        return &result;
    }
}

/// Writes any ZON struct / anonymous literal to an RFC-822 stream writer.
pub fn writeZon(rw: *Writer, zon: anytype) !void {
    const T = @TypeOf(zon);
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("Expected struct or anonymous struct literal for ZON, found " ++ @typeName(T));
    }

    inline for (type_info.@"struct".fields) |field| {
        const header_name = comptime rfc822FieldName(field.name);
        const val = @field(zon, field.name);
        const FieldType = @TypeOf(val);
        const field_info = @typeInfo(FieldType);

        if (field_info == .optional) {
            if (val) |unwrapped| {
                try writeZonValue(rw, header_name, unwrapped);
            }
        } else {
            try writeZonValue(rw, header_name, val);
        }
    }
}

fn writeZonValue(rw: *Writer, header_name: []const u8, val: anytype) !void {
    const ValType = @TypeOf(val);
    const val_info = @typeInfo(ValType);

    switch (val_info) {
        .bool => {
            try rw.writeFieldBool(header_name, val, "yes");
        },
        .int, .comptime_int => {
            try rw.writeFieldInt(header_name, val);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try rw.writeField(header_name, val);
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                try rw.writeField(header_name, val);
            } else if (ptr.size == .slice and ptr.child == []const u8) {
                var joined: [2048]u8 = undefined;
                var j_stream: std.Io.Writer = .fixed(&joined);
                for (val, 0..) |item, i| {
                    if (i > 0) try j_stream.writeAll(", ");
                    try j_stream.writeAll(item);
                }
                try rw.writeField(header_name, j_stream.buffered());
            } else {
                try rw.writeField(header_name, val);
            }
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                var joined_buf: [2048]u8 = undefined;
                var j_stream: std.Io.Writer = .fixed(&joined_buf);
                inline for (0..s.fields.len) |i| {
                    if (i > 0) try j_stream.writeAll(", ");
                    const item = val[i];
                    try j_stream.writeAll(item);
                }
                try rw.writeField(header_name, j_stream.buffered());
            } else {
                inline for (s.fields) |sub_f| {
                    const sub_h = comptime rfc822FieldName(sub_f.name);
                    const sub_v = @field(val, sub_f.name);
                    try writeZonValue(rw, sub_h, sub_v);
                }
            }
        },
        .enum_literal => {
            try rw.writeField(header_name, @tagName(val));
        },
        else => {
            try rw.writeField(header_name, val);
        },
    }
}

/// Streaming paragraph iterator over an RFC822 document.
pub const Iterator = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Iterator {
        return .{ .source = source };
    }

    pub fn next(self: *Iterator, gpa: Allocator) !?Paragraph {
        // Skip leading whitespace / blank lines / comments
        while (self.pos < self.source.len) {
            const entry = self.peekLineWithDelim();
            const trimmed = mem.trim(u8, entry.line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') {
                self.pos += entry.advance;
            } else {
                break;
            }
        }

        if (self.pos >= self.source.len) return null;

        const start_pos = self.pos;
        var p: Paragraph = .{ .raw = "" };
        errdefer p.deinit(gpa);

        var current_field_name: ?[]const u8 = null;
        var current_field_value_start: usize = 0;
        var current_field_value_end: usize = 0;

        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const entry = self.peekLineWithDelim();
            const line = entry.line;
            const trimmed = mem.trim(u8, line, " \t\r");

            // Empty line marks end of paragraph
            if (trimmed.len == 0) {
                self.pos += entry.advance;
                break;
            }

            // Comment line inside paragraph
            if (trimmed[0] == '#') {
                self.pos += entry.advance;
                continue;
            }

            // Continuation line (starts with space or tab)
            if (line[0] == ' ' or line[0] == '\t') {
                if (current_field_name != null) {
                    current_field_value_end = line_start + line.len;
                }
            } else if (mem.indexOfScalar(u8, line, ':')) |colon_pos| {
                // Flush previous field
                if (current_field_name) |fname| {
                    const fval = mem.trim(u8, self.source[current_field_value_start..current_field_value_end], " \t\r\n");
                    try p.fields.append(gpa, .{ .name = fname, .value = fval });
                }

                const fname = mem.trim(u8, line[0..colon_pos], " \t");
                const val_start_in_line = colon_pos + 1;
                current_field_name = fname;
                current_field_value_start = line_start + val_start_in_line;
                current_field_value_end = line_start + line.len;
            }

            self.pos += entry.advance;
        }

        // Flush last field
        if (current_field_name) |fname| {
            const fval = mem.trim(u8, self.source[current_field_value_start..current_field_value_end], " \t\r\n");
            try p.fields.append(gpa, .{ .name = fname, .value = fval });
        }

        p.raw = self.source[start_pos..self.pos];
        return p;
    }

    fn peekLineWithDelim(self: *const Iterator) struct { line: []const u8, advance: usize } {
        const remaining = self.source[self.pos..];
        if (mem.indexOfScalar(u8, remaining, '\n')) |idx| {
            var line = remaining[0..idx];
            const advance = idx + 1;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            return .{ .line = line, .advance = advance };
        }
        return .{ .line = remaining, .advance = remaining.len };
    }
};

test "RFC822 parsing basic" {
    const data =
        \\# Comment at start
        \\Package: dpkg
        \\Version: 1.21.22
        \\Architecture: amd64
        \\Description: Debian package management system
        \\ This is a multiline description
        \\ that spans multiple lines.
        \\
        \\Package: libc6
        \\Version: 2.36-9
        \\Architecture: amd64
        \\Depends: libgcc-s1
        \\
    ;

    var it = Iterator.init(data);
    var p1 = (try it.next(testing.allocator)).?;
    defer p1.deinit(testing.allocator);

    try testing.expectEqualStrings("dpkg", p1.get("Package").?);
    try testing.expectEqualStrings("1.21.22", p1.get("Version").?);
    try testing.expectEqualStrings("amd64", p1.get("Architecture").?);
    try testing.expect(p1.get("Description") != null);
    try testing.expect(mem.indexOf(u8, p1.get("Description").?, "multiline description") != null);

    var p2 = (try it.next(testing.allocator)).?;
    defer p2.deinit(testing.allocator);

    try testing.expectEqualStrings("libc6", p2.get("Package").?);
    try testing.expectEqualStrings("2.36-9", p2.get("Version").?);
    try testing.expectEqualStrings("libgcc-s1", p2.get("Depends").?);

    try testing.expect((try it.next(testing.allocator)) == null);
}

test "RFC822 CRLF and colons in values" {
    const data = "Package: test-pkg\r\nVersion: 1:2.3.4\r\nHomepage: https://example.com/test:pkg\r\n\r\n";
    var it = Iterator.init(data);
    var p = (try it.next(testing.allocator)).?;
    defer p.deinit(testing.allocator);

    try testing.expectEqualStrings("test-pkg", p.get("Package").?);
    try testing.expectEqualStrings("1:2.3.4", p.get("Version").?);
    try testing.expectEqualStrings("https://example.com/test:pkg", p.get("Homepage").?);
    try testing.expect(p.get("NonExistent") == null);
}

test "RFC822 Writer single and multiline fields" {
    const allocator = testing.allocator;

    var buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer buf.deinit();

    var w = Writer.init(&buf.writer);

    try w.writeComment("Generated RFC822 metadata");
    try w.writeField("Package", "test-app");
    try w.writeField("Version", "1.0.0");
    try w.writeFieldInt("Installed-Size", 42);
    try w.writeFieldBool("Essential", true, "yes");
    try w.writeFieldOptional("Homepage", "https://example.org");
    try w.writeFieldOptional("OptionalField", null);
    try w.writeField("Description", "Short summary line\nExtended line 1\n\nExtended line 2");
    try w.endParagraph();

    try w.writeField("Package", "second-pkg");
    try w.writeField("Version", "2.0.0");
    try w.endParagraph();

    const expected =
        "# Generated RFC822 metadata\n" ++
        "Package: test-app\n" ++
        "Version: 1.0.0\n" ++
        "Installed-Size: 42\n" ++
        "Essential: yes\n" ++
        "Homepage: https://example.org\n" ++
        "Description: Short summary line\n" ++
        " Extended line 1\n" ++
        " .\n" ++
        " Extended line 2\n" ++
        "\n" ++
        "Package: second-pkg\n" ++
        "Version: 2.0.0\n" ++
        "\n";

    try testing.expectEqualStrings(expected, buf.written());

    // Verify roundtrip parsing
    var it = Iterator.init(buf.written());
    var p1 = (try it.next(allocator)).?;
    defer p1.deinit(allocator);

    try testing.expectEqualStrings("test-app", p1.get("Package").?);
    try testing.expectEqualStrings("1.0.0", p1.get("Version").?);
    try testing.expectEqualStrings("42", p1.get("Installed-Size").?);
    try testing.expectEqualStrings("yes", p1.get("Essential").?);
    try testing.expectEqualStrings("https://example.org", p1.get("Homepage").?);

    var p2 = (try it.next(allocator)).?;
    defer p2.deinit(allocator);

    try testing.expectEqualStrings("second-pkg", p2.get("Package").?);
    try testing.expectEqualStrings("2.0.0", p2.get("Version").?);

    try testing.expect((try it.next(allocator)) == null);
}

test "RFC822 Paragraph format and write" {
    const allocator = testing.allocator;

    var p: Paragraph = .{};
    defer p.deinit(allocator);

    try p.addField(allocator, "Package", "libfoo");
    try p.addField(allocator, "Version", "0.1.0");

    const formatted = try p.format(allocator);
    defer allocator.free(formatted);

    try testing.expectEqualStrings("Package: libfoo\nVersion: 0.1.0\n", formatted);
}

test "formatZon runtime conversion" {
    const allocator = testing.allocator;

    const zon_data = .{
        .package = "my-awesome-tool",
        .version = "1.2.3-1",
        .architecture = "amd64",
        .maintainer = "Jane Doe <jane@example.com>",
        .section = "devel",
        .priority = "optional",
        .essential = true,
        .installed_size = 2048,
        .homepage = "https://example.com/tool",
        .depends = .{ "libc6 (>= 2.34)", "libssl3", "zlib1g" },
        .pre_depends = "debconf",
        .description = "Awesome native tool\nFirst line of description\n\nSecond paragraph",
        .custom_field = "custom_value",
    };

    const formatted = try formatZon(allocator, zon_data);
    defer allocator.free(formatted);

    // Verify it parses as valid RFC-822
    var it = Iterator.init(formatted);
    var p = (try it.next(allocator)).?;
    defer p.deinit(allocator);

    try testing.expectEqualStrings("my-awesome-tool", p.get("Package").?);
    try testing.expectEqualStrings("1.2.3-1", p.get("Version").?);
    try testing.expectEqualStrings("amd64", p.get("Architecture").?);
    try testing.expectEqualStrings("yes", p.get("Essential").?);
    try testing.expectEqualStrings("2048", p.get("Installed-Size").?);
    try testing.expectEqualStrings("libc6 (>= 2.34), libssl3, zlib1g", p.get("Depends").?);
    try testing.expectEqualStrings("debconf", p.get("Pre-Depends").?);
    try testing.expectEqualStrings("custom_value", p.get("Custom-Field").?);
    try testing.expect(p.get("Description") != null);
}

test "formatZonComptime conversion" {
    const rfc822_doc = comptime formatZonComptime(.{
        .package = "comptime-pkg",
        .version = "2.0.0",
        .architecture = "arm64",
        .maintainer = "Comptime Builder <builder@example.com>",
        .depends = .{ "libc6", "busybox" },
        .description = "Built at comptime\nNo runtime overhead",
    });

    try testing.expect(mem.indexOf(u8, rfc822_doc, "Package: comptime-pkg\n") != null);
    try testing.expect(mem.indexOf(u8, rfc822_doc, "Version: 2.0.0\n") != null);
    try testing.expect(mem.indexOf(u8, rfc822_doc, "Architecture: arm64\n") != null);
    try testing.expect(mem.indexOf(u8, rfc822_doc, "Depends: libc6, busybox\n") != null);
    try testing.expect(mem.indexOf(u8, rfc822_doc, "Description: Built at comptime\n No runtime overhead\n") != null);
}
