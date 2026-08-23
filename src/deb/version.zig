const std = @import("std");
const mem = std.mem;
const math = std.math;
const testing = std.testing;

/// Represents a parsed Debian package version according to deb-version(7).
/// Format: [epoch:]upstream_version[-debian_revision]
pub const Version = struct {
    epoch: u32 = 0,
    upstream: []const u8 = "",
    debian_revision: []const u8 = "",
    raw: []const u8 = "",

    pub fn parse(raw: []const u8) Version {
        var str = raw;
        var epoch: u32 = 0;

        if (mem.indexOfScalar(u8, str, ':')) |colon_idx| {
            if (std.fmt.parseInt(u32, str[0..colon_idx], 10)) |e| {
                epoch = e;
                str = str[colon_idx + 1 ..];
            } else |_| {
                // If invalid epoch, keep epoch as 0
            }
        }

        var upstream = str;
        var revision: []const u8 = "";

        if (mem.lastIndexOfScalar(u8, str, '-')) |hyphen_idx| {
            upstream = str[0..hyphen_idx];
            revision = str[hyphen_idx + 1 ..];
        }

        return .{
            .epoch = epoch,
            .upstream = upstream,
            .debian_revision = revision,
            .raw = raw,
        };
    }

    pub fn order(a: Version, b: Version) math.Order {
        if (a.epoch < b.epoch) return .lt;
        if (a.epoch > b.epoch) return .gt;

        const up_ord = verrevcmp(a.upstream, b.upstream);
        if (up_ord != .eq) return up_ord;

        return verrevcmp(a.debian_revision, b.debian_revision);
    }

    pub fn compare(a: []const u8, b: []const u8) math.Order {
        return parse(a).order(parse(b));
    }

    pub const Operator = enum { lt, le, eq, ge, gt, ne };

    pub fn satisfies(v1: []const u8, op: Operator, v2: []const u8) bool {
        const ord = compare(v1, v2);
        return switch (op) {
            .lt => ord == .lt,
            .le => ord == .lt or ord == .eq,
            .eq => ord == .eq,
            .ge => ord == .gt or ord == .eq,
            .gt => ord == .gt,
            .ne => ord != .eq,
        };
    }
};

fn charOrder(c: u8) i32 {
    if (c == '~') return -1;
    if (std.ascii.isDigit(c)) return 0;
    if (std.ascii.isAlphabetic(c)) return @intCast(c);
    return @as(i32, @intCast(c)) + 256;
}

/// Debian version segment comparator (`verrevcmp`).
pub fn verrevcmp(val: []const u8, ref: []const u8) math.Order {
    var v_idx: usize = 0;
    var r_idx: usize = 0;

    while (v_idx < val.len or r_idx < ref.len) {
        // Compare non-digit characters
        while ((v_idx < val.len and !std.ascii.isDigit(val[v_idx])) or
            (r_idx < ref.len and !std.ascii.isDigit(ref[r_idx])))
        {
            const vc = if (v_idx < val.len) charOrder(val[v_idx]) else 0;
            const rc = if (r_idx < ref.len) charOrder(ref[r_idx]) else 0;
            if (vc < rc) return .lt;
            if (vc > rc) return .gt;
            if (v_idx < val.len) v_idx += 1;
            if (r_idx < ref.len) r_idx += 1;
        }

        // Skip leading zeros in digit sequence
        while (v_idx < val.len and val[v_idx] == '0') v_idx += 1;
        while (r_idx < ref.len and ref[r_idx] == '0') r_idx += 1;

        // Compare numerical digits
        var first_diff: i32 = 0;
        var v_len: usize = 0;
        var r_len: usize = 0;

        while (v_idx + v_len < val.len and std.ascii.isDigit(val[v_idx + v_len])) {
            v_len += 1;
        }
        while (r_idx + r_len < ref.len and std.ascii.isDigit(ref[r_idx + r_len])) {
            r_len += 1;
        }

        // The number with more digits is larger
        if (v_len < r_len) return .lt;
        if (v_len > r_len) return .gt;

        // If same length, compare digit by digit
        for (0..v_len) |i| {
            if (val[v_idx + i] != ref[r_idx + i] and first_diff == 0) {
                first_diff = @as(i32, val[v_idx + i]) - @as(i32, ref[r_idx + i]);
            }
        }

        v_idx += v_len;
        r_idx += r_len;

        if (first_diff < 0) return .lt;
        if (first_diff > 0) return .gt;
    }

    return .eq;
}

test "Debian version comparison" {
    try testing.expectEqual(math.Order.eq, Version.compare("1.0", "1.0"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0", "1.1"));
    try testing.expectEqual(math.Order.gt, Version.compare("1.1", "1.0"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0~beta1", "1.0"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0~~", "1.0~"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0~beta1", "1.0~beta2"));
    try testing.expectEqual(math.Order.gt, Version.compare("1:1.0", "2.0"));
    try testing.expectEqual(math.Order.gt, Version.compare("2:1.0", "1:9.9"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0-1", "1.0-2"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0-0ubuntu1", "1.0-1"));
    try testing.expectEqual(math.Order.eq, Version.compare("0:1.0-1", "1.0-1"));
    try testing.expectEqual(math.Order.gt, Version.compare("2.0.1", "2.0"));
    try testing.expectEqual(math.Order.lt, Version.compare("2.0-1", "2.0-1+deb12u1"));
    try testing.expectEqual(math.Order.gt, Version.compare("2.36-9+deb12u14", "2.36-9+deb12u2"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0a", "1.0b"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0", "1.0a"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0~", "1.0"));
    try testing.expectEqual(math.Order.lt, Version.compare("1.0", "1.0+"));
    try testing.expectEqual(math.Order.eq, Version.compare("1.0.0", "1.0.0"));
}

test "Debian version operators and satisfaction" {
    try testing.expect(Version.satisfies("2.36-9", .ge, "2.36-1"));
    try testing.expect(Version.satisfies("2.36-9", .gt, "2.36-1"));
    try testing.expect(Version.satisfies("2.36-9", .le, "2.36-9"));
    try testing.expect(Version.satisfies("2.36-9", .eq, "2.36-9"));
    try testing.expect(Version.satisfies("2.36-9", .ne, "2.36-1"));
    try testing.expect(!Version.satisfies("2.36-9", .lt, "2.36-1"));
}
