const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

pub const Response = struct {
    code: u32,
    value: []const u8 = "",

    pub fn isSuccess(self: Response) bool {
        return self.code == 0;
    }
};

pub const Client = struct {
    reader: ?*std.Io.Reader = null,
    writer: ?*std.Io.Writer = null,
    response_buf: [1024]u8 = undefined,

    pub fn init(reader: ?*std.Io.Reader, writer: ?*std.Io.Writer) Client {
        return .{
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn command(self: *Client, cmd: []const u8) !Response {
        const w = self.writer orelse return .{ .code = 0, .value = "" };
        const r = self.reader orelse return .{ .code = 0, .value = "" };

        try w.writeAll(cmd);
        try w.writeByte('\n');
        try w.flush();

        const line = try r.takeDelimiterExclusive('\n');
        const trimmed = mem.trim(u8, line, " \t\r\n");

        if (mem.indexOfScalar(u8, trimmed, ' ')) |space_pos| {
            const code_str = trimmed[0..space_pos];
            const code = std.fmt.parseInt(u32, code_str, 10) catch 0;
            const val = mem.trim(u8, trimmed[space_pos + 1 ..], " \t");
            return .{ .code = code, .value = val };
        } else {
            const code = std.fmt.parseInt(u32, trimmed, 10) catch 0;
            return .{ .code = code, .value = "" };
        }
    }

    pub fn input(self: *Client, priority: []const u8, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "INPUT {s} {s}", .{ priority, template });
        return self.command(cmd);
    }

    pub fn go(self: *Client) !Response {
        return self.command("GO");
    }

    pub fn get(self: *Client, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "GET {s}", .{template});
        return self.command(cmd);
    }

    pub fn set(self: *Client, template: []const u8, value: []const u8) !Response {
        var buf: [1024]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "SET {s} {s}", .{ template, value });
        return self.command(cmd);
    }

    pub fn reset(self: *Client, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "RESET {s}", .{template});
        return self.command(cmd);
    }

    pub fn subst(self: *Client, template: []const u8, variable: []const u8, value: []const u8) !Response {
        var buf: [2048]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "SUBST {s} {s} {s}", .{ template, variable, value });
        return self.command(cmd);
    }

    pub fn title(self: *Client, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "TITLE {s}", .{template});
        return self.command(cmd);
    }

    pub fn capb(self: *Client, capabilities: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "CAPB {s}", .{capabilities});
        return self.command(cmd);
    }

    pub fn fget(self: *Client, template: []const u8, flag: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "FGET {s} {s}", .{ template, flag });
        return self.command(cmd);
    }

    pub fn fset(self: *Client, template: []const u8, flag: []const u8, value: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "FSET {s} {s} {s}", .{ template, flag, value });
        return self.command(cmd);
    }

    pub fn progressStart(self: *Client, min: u32, max: u32, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "PROGRESS START {d} {d} {s}", .{ min, max, template });
        return self.command(cmd);
    }

    pub fn progressSet(self: *Client, val: u32) !Response {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "PROGRESS SET {d}", .{val});
        return self.command(cmd);
    }

    pub fn progressStep(self: *Client, inc: u32) !Response {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "PROGRESS STEP {d}", .{inc});
        return self.command(cmd);
    }

    pub fn progressInfo(self: *Client, template: []const u8) !Response {
        var buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "PROGRESS INFO {s}", .{template});
        return self.command(cmd);
    }

    pub fn progressRegion(self: *Client, start: u32, end: u32) !Response {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "PROGRESS REGION {d} {d}", .{ start, end });
        return self.command(cmd);
    }

    pub fn progressStop(self: *Client) !Response {
        return self.command("PROGRESS STOP");
    }

    pub fn stop(self: *Client) !void {
        _ = try self.command("STOP");
    }
};

test "Debconf Client protocol mock" {
    var in_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    // Simulate frontend answering with "0 OK"
    @memcpy(in_buf[0..5], "0 OK\n");
    var in_reader: std.Io.Reader = .fixed(in_buf[0..5]);

    var out_writer: std.Io.Writer = .fixed(&out_buf);

    var client = Client.init(&in_reader, &out_writer);
    const resp = try client.go();

    try testing.expectEqual(@as(u32, 0), resp.code);
    try testing.expectEqualStrings("OK", resp.value);
}

test "Debconf Client command formatting and error codes" {
    var in_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    @memcpy(in_buf[0..22], "30 question not asked\n");
    var in_reader: std.Io.Reader = .fixed(in_buf[0..22]);
    var out_writer: std.Io.Writer = .fixed(&out_buf);

    var client = Client.init(&in_reader, &out_writer);
    const resp = try client.input("medium", "debconf/priority");

    try testing.expectEqual(@as(u32, 30), resp.code);
    try testing.expectEqualStrings("question not asked", resp.value);
    try testing.expectEqualStrings("INPUT medium debconf/priority\n", out_writer.buffered());
}

test "Debconf Client subst and progress commands" {
    var in_buf: [256]u8 = undefined;
    var out_buf: [512]u8 = undefined;

    @memcpy(in_buf[0..5], "0 OK\n");
    var in_reader: std.Io.Reader = .fixed(in_buf[0..5]);
    var out_writer: std.Io.Writer = .fixed(&out_buf);

    var client = Client.init(&in_reader, &out_writer);

    const subst_resp = try client.subst("cdebootstrap/message/error", "ARG0", "Disk full");
    try testing.expectEqual(@as(u32, 0), subst_resp.code);
    try testing.expectEqualStrings("SUBST cdebootstrap/message/error ARG0 Disk full\n", out_writer.buffered());

    out_writer.end = 0;
    in_reader = .fixed(in_buf[0..5]);
    const prog_start_resp = try client.progressStart(0, 100, "cdebootstrap/progress/start/install");
    try testing.expectEqual(@as(u32, 0), prog_start_resp.code);
    try testing.expectEqualStrings("PROGRESS START 0 100 cdebootstrap/progress/start/install\n", out_writer.buffered());

    out_writer.end = 0;
    in_reader = .fixed(in_buf[0..5]);
    const prog_set_resp = try client.progressSet(42);
    try testing.expectEqual(@as(u32, 0), prog_set_resp.code);
    try testing.expectEqualStrings("PROGRESS SET 42\n", out_writer.buffered());

    out_writer.end = 0;
    in_reader = .fixed(in_buf[0..5]);
    const prog_step_resp = try client.progressStep(5);
    try testing.expectEqual(@as(u32, 0), prog_step_resp.code);
    try testing.expectEqualStrings("PROGRESS STEP 5\n", out_writer.buffered());

    out_writer.end = 0;
    in_reader = .fixed(in_buf[0..5]);
    const prog_info_resp = try client.progressInfo("cdebootstrap/progress/info/download/retrieve");
    try testing.expectEqual(@as(u32, 0), prog_info_resp.code);
    try testing.expectEqualStrings("PROGRESS INFO cdebootstrap/progress/info/download/retrieve\n", out_writer.buffered());

    out_writer.end = 0;
    in_reader = .fixed(in_buf[0..5]);
    const prog_stop_resp = try client.progressStop();
    try testing.expectEqual(@as(u32, 0), prog_stop_resp.code);
    try testing.expectEqualStrings("PROGRESS STOP\n", out_writer.buffered());
}
