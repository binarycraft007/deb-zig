//! Pure Zig Bzip2 Decompressor
//! Implements standard bzip2 format decompression with zero C dependencies.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

pub const Bzip2Error = error{
    InvalidHeader,
    InvalidMagic,
    InvalidBlockSize,
    InvalidOrigPtr,
    InvalidHuffmanTable,
    InvalidSelector,
    CrcMismatch,
    EndOfStream,
    CorruptData,
    OutOfMemory,
};

/// Bzip2 Bit Reader (MSB first)
pub const BitReader = struct {
    bytes: []const u8,
    pos: usize = 0,
    bit_buf: u64 = 0,
    bits_in_buf: u8 = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    pub fn readBits(self: *BitReader, comptime T: type, count: u8) Bzip2Error!T {
        while (self.bits_in_buf < count) {
            if (self.pos >= self.bytes.len) return error.EndOfStream;
            self.bit_buf = (self.bit_buf << 8) | self.bytes[self.pos];
            self.pos += 1;
            self.bits_in_buf += 8;
        }

        const shift = self.bits_in_buf - count;
        const mask = (@as(u64, 1) << @intCast(count)) - 1;
        const val = (self.bit_buf >> @intCast(shift)) & mask;
        self.bits_in_buf -= count;
        return @intCast(val);
    }

    pub fn readBit(self: *BitReader) Bzip2Error!u1 {
        return self.readBits(u1, 1);
    }
};

const BZ_MAX_ALPHA_SIZE = 258;
const BZ_MAX_CODE_LEN = 20;
const BZ_MAX_TREES = 6;
const BZ_MAX_SELECTORS = 18002;

const HuffmanTree = struct {
    min_len: u8 = 0,
    max_len: u8 = 0,
    limit: [BZ_MAX_CODE_LEN + 2]i32 = [_]i32{0} ** (BZ_MAX_CODE_LEN + 2),
    base: [BZ_MAX_CODE_LEN + 2]i32 = [_]i32{0} ** (BZ_MAX_CODE_LEN + 2),
    perm: [BZ_MAX_ALPHA_SIZE]u16 = [_]u16{0} ** BZ_MAX_ALPHA_SIZE,

    pub fn init(lengths: []const u8, alpha_size: usize) HuffmanTree {
        var self: HuffmanTree = .{};
        var min_l: u8 = 32;
        var max_l: u8 = 0;

        for (lengths[0..alpha_size]) |l| {
            if (l > max_l) max_l = l;
            if (l < min_l and l > 0) min_l = l;
        }

        if (min_l > max_l) min_l = 0;
        self.min_len = min_l;
        self.max_len = max_l;

        var pp: usize = 0;
        var i: usize = min_l;
        while (i <= max_l) : (i += 1) {
            for (lengths[0..alpha_size], 0..) |l, j| {
                if (l == i) {
                    self.perm[pp] = @intCast(j);
                    pp += 1;
                }
            }
        }

        @memset(&self.base, 0);
        for (lengths[0..alpha_size]) |l| {
            self.base[l + 1] += 1;
        }

        for (1..BZ_MAX_CODE_LEN + 1) |k| {
            self.base[k] += self.base[k - 1];
        }

        @memset(&self.limit, 0);
        var vec: i32 = 0;
        i = min_l;
        while (i <= max_l) : (i += 1) {
            vec += self.base[i + 1] - self.base[i];
            self.limit[i] = vec - 1;
            vec <<= 1;
        }

        i = min_l + 1;
        while (i <= max_l) : (i += 1) {
            self.base[i] = ((self.limit[i - 1] + 1) << 1) - self.base[i];
        }

        return self;
    }

    pub fn decode(self: *const HuffmanTree, reader: *BitReader) Bzip2Error!u16 {
        var zn: u8 = self.min_len;
        var zvec: i32 = if (zn > 0) try reader.readBits(i32, zn) else 0;

        while (true) {
            if (zn > self.max_len) return error.CorruptData;
            if (zvec <= self.limit[zn]) break;
            zn += 1;
            zvec = (zvec << 1) | try reader.readBit();
        }

        const idx = zvec - self.base[zn];
        if (idx < 0 or idx >= BZ_MAX_ALPHA_SIZE) return error.CorruptData;
        return self.perm[@intCast(idx)];
    }
};

const Bzip2Crc = struct {
    const table: [256]u32 = initTable();

    fn initTable() [256]u32 {
        @setEvalBranchQuota(5000);
        var t: [256]u32 = undefined;
        for (0..256) |i| {
            var c: u32 = @as(u32, @intCast(i)) << 24;
            for (0..8) |_| {
                if ((c & 0x80000000) != 0) {
                    c = (c << 1) ^ 0x04C11DB7;
                } else {
                    c <<= 1;
                }
            }
            t[i] = c;
        }
        return t;
    }

    pub fn update(crc: u32, byte: u8) u32 {
        return (crc << 8) ^ table[((crc >> 24) ^ byte) & 0xFF];
    }
};

pub fn decompress(gpa: Allocator, input: []const u8, out_writer: anytype) !void {
    if (input.len < 4) return error.InvalidHeader;
    if (input[0] != 'B' or input[1] != 'Z' or input[2] != 'h') return error.InvalidMagic;
    if (input[3] < '1' or input[3] > '9') return error.InvalidBlockSize;

    const block_size_100k = input[3] - '0';
    const max_block_size = @as(usize, block_size_100k) * 100_000;

    var reader = BitReader.init(input[4..]);
    var computed_stream_crc: u32 = 0;

    const bwt_buf = try gpa.alloc(u8, max_block_size);
    defer gpa.free(bwt_buf);

    const tt = try gpa.alloc(u32, max_block_size);
    defer gpa.free(tt);

    while (true) {
        const b1 = reader.readBits(u8, 8) catch |err| if (err == error.EndOfStream) break else return err;
        const b2 = try reader.readBits(u8, 8);
        const b3 = try reader.readBits(u8, 8);
        const b4 = try reader.readBits(u8, 8);
        const b5 = try reader.readBits(u8, 8);
        const b6 = try reader.readBits(u8, 8);

        // Check for end of stream: 0x177245385090
        if (b1 == 0x17 and b2 == 0x72 and b3 == 0x45 and b4 == 0x38 and b5 == 0x50 and b6 == 0x90) {
            _ = try reader.readBits(u32, 32); // stream CRC
            break;
        }

        // Check for block header: 0x314159265359 (pi)
        if (b1 != 0x31 or b2 != 0x41 or b3 != 0x59 or b4 != 0x26 or b5 != 0x53 or b6 != 0x59) {
            return error.InvalidMagic;
        }

        const expected_block_crc = try reader.readBits(u32, 32);
        const randomised = try reader.readBit();
        if (randomised != 0) return error.CorruptData;

        const orig_ptr = try reader.readBits(u24, 24);

        // Read symbol mapping
        var in_use_16 = [_]bool{false} ** 16;
        for (0..16) |i| {
            in_use_16[i] = (try reader.readBit() == 1);
        }

        var in_use = [_]bool{false} ** 256;
        for (0..16) |i| {
            if (in_use_16[i]) {
                for (0..16) |j| {
                    in_use[i * 16 + j] = (try reader.readBit() == 1);
                }
            }
        }

        var num_in_use: usize = 0;
        var seq_to_unseq: [256]u8 = undefined;
        for (0..256) |i| {
            if (in_use[i]) {
                seq_to_unseq[num_in_use] = @intCast(i);
                num_in_use += 1;
            }
        }

        if (num_in_use == 0) return error.CorruptData;
        const alpha_size = num_in_use + 2;

        // Number of Huffman trees
        const num_trees = try reader.readBits(u3, 3);
        if (num_trees < 2 or num_trees > 6) return error.InvalidHuffmanTable;

        const num_selectors = try reader.readBits(u15, 15);
        if (num_selectors < 1 or num_selectors > BZ_MAX_SELECTORS) return error.InvalidSelector;

        // Selectors MTF
        var selector_mtf: [BZ_MAX_TREES]u8 = undefined;
        for (0..num_trees) |i| selector_mtf[i] = @intCast(i);

        var selectors = try gpa.alloc(u8, num_selectors);
        defer gpa.free(selectors);

        for (0..num_selectors) |i| {
            var count: u8 = 0;
            while (try reader.readBit() == 1) {
                count += 1;
                if (count >= num_trees) return error.InvalidSelector;
            }

            const tree_idx = selector_mtf[count];
            var k = count;
            while (k > 0) : (k -= 1) {
                selector_mtf[k] = selector_mtf[k - 1];
            }
            selector_mtf[0] = tree_idx;
            selectors[i] = tree_idx;
        }

        // Huffman code lengths
        var trees: [BZ_MAX_TREES]HuffmanTree = undefined;
        for (0..num_trees) |t| {
            var curr_len = try reader.readBits(u8, 5);
            var lengths: [BZ_MAX_ALPHA_SIZE]u8 = undefined;

            for (0..alpha_size) |i| {
                while (true) {
                    if (curr_len < 1 or curr_len > 20) return error.InvalidHuffmanTable;
                    if (try reader.readBit() == 0) break;
                    if (try reader.readBit() == 0) {
                        curr_len += 1;
                    } else {
                        curr_len -= 1;
                    }
                }
                lengths[i] = curr_len;
            }

            trees[t] = HuffmanTree.init(&lengths, alpha_size);
        }

        // Move to Front list for bytes
        var byte_mtf: [256]u8 = undefined;
        for (0..num_in_use) |i| byte_mtf[i] = @intCast(i);

        var bwt_len: usize = 0;
        var group_idx: usize = 0;
        var group_pos: usize = 0;
        var active_tree = &trees[selectors[0]];

        const RUNA = 0;
        const RUNB = 1;
        const EOB = num_in_use + 1;

        while (true) {
            if (group_pos == 0) {
                if (group_idx >= num_selectors) return error.CorruptData;
                active_tree = &trees[selectors[group_idx]];
                group_idx += 1;
                group_pos = 50;
            }
            group_pos -= 1;

            var next_sym = try active_tree.decode(&reader);

            if (next_sym == RUNA or next_sym == RUNB) {
                var run_count: usize = 0;
                var run_weight: usize = 1;

                while (true) {
                    if (next_sym == RUNA) {
                        run_count += run_weight;
                    } else if (next_sym == RUNB) {
                        run_count += run_weight * 2;
                    } else {
                        break;
                    }

                    run_weight <<= 1;

                    if (group_pos == 0) {
                        if (group_idx >= num_selectors) return error.CorruptData;
                        active_tree = &trees[selectors[group_idx]];
                        group_idx += 1;
                        group_pos = 50;
                    }
                    group_pos -= 1;

                    next_sym = try active_tree.decode(&reader);
                }

                if (bwt_len + run_count > max_block_size) return error.CorruptData;
                const repeated_byte = seq_to_unseq[byte_mtf[0]];
                @memset(bwt_buf[bwt_len .. bwt_len + run_count], repeated_byte);
                bwt_len += run_count;
            }

            if (next_sym == EOB) break;

            if (next_sym >= 2 and next_sym <= num_in_use + 1) {
                const mtf_idx = next_sym - 1;
                const sym_idx = byte_mtf[mtf_idx];
                const actual_byte = seq_to_unseq[sym_idx];

                // Move to front
                var k = mtf_idx;
                while (k > 0) : (k -= 1) {
                    byte_mtf[k] = byte_mtf[k - 1];
                }
                byte_mtf[0] = sym_idx;

                if (bwt_len >= max_block_size) return error.CorruptData;
                bwt_buf[bwt_len] = actual_byte;
                bwt_len += 1;
            } else {
                return error.CorruptData;
            }
        }

        if (orig_ptr >= bwt_len) return error.InvalidOrigPtr;

        // Inverse Burrows-Wheeler Transform
        var count = [_]u32{0} ** 256;
        for (bwt_buf[0..bwt_len]) |b| {
            count[b] += 1;
        }

        var base_count = [_]u32{0} ** 257;
        base_count[0] = 0;
        for (0..256) |i| {
            base_count[i + 1] = base_count[i] + count[i];
        }

        for (bwt_buf[0..bwt_len], 0..) |b, i| {
            tt[base_count[b]] = @intCast(i);
            base_count[b] += 1;
        }

        // Reconstruct stream & perform RLE2 output decoding
        var computed_block_crc: u32 = 0xFFFFFFFF;
        var curr = tt[orig_ptr];
        var rle_byte: u8 = 0;
        var rle_count: u8 = 0;

        for (0..bwt_len) |_| {
            const byte = bwt_buf[curr];
            curr = tt[curr];

            if (rle_count == 4) {
                for (0..byte) |_| {
                    try out_writer.writeByte(rle_byte);
                    computed_block_crc = Bzip2Crc.update(computed_block_crc, rle_byte);
                }
                rle_count = 0;
            } else {
                if (rle_count > 0 and byte == rle_byte) {
                    rle_count += 1;
                } else {
                    rle_byte = byte;
                    rle_count = 1;
                }
                try out_writer.writeByte(byte);
                computed_block_crc = Bzip2Crc.update(computed_block_crc, byte);
            }
        }

        computed_block_crc = ~computed_block_crc;
        if (computed_block_crc != expected_block_crc) {
            return error.CrcMismatch;
        }

        computed_stream_crc = ((computed_stream_crc << 1) | (computed_stream_crc >> 31)) ^ computed_block_crc;
    }
}

test "Bzip2 decompress sample stream" {
    // bzip2 -9 of "Hello, World! This is pure Zig bzip2 decompressor.\n"
    const sample = [_]u8{
        0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26,
        0x53, 0x59, 0x20, 0x92, 0xb1, 0xf5, 0x00, 0x00,
        0x06, 0x5f, 0x80, 0x00, 0x10, 0x60, 0x05, 0x10,
        0x00, 0x00, 0x40, 0x04, 0x90, 0x1e, 0xe6, 0xda,
        0x10, 0x20, 0x00, 0x48, 0x8a, 0x6d, 0x4f, 0x49,
        0xea, 0x6d, 0x02, 0x34, 0x7b, 0x54, 0xf5, 0x0a,
        0x00, 0x06, 0x81, 0x93, 0x21, 0x37, 0x4b, 0xe1,
        0x41, 0x67, 0xd0, 0x2b, 0x62, 0x2a, 0x39, 0xcd,
        0x70, 0x6f, 0xd6, 0xa0, 0x73, 0xc3, 0x35, 0xe4,
        0x32, 0xf6, 0xfa, 0x8b, 0x1a, 0x39, 0x92, 0xb2,
        0x47, 0xc5, 0xdc, 0x91, 0x4e, 0x14, 0x24, 0x08,
        0x24, 0xac, 0x7d, 0x40,
    };

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    try decompress(testing.allocator, &sample, &writer.writer);
    const out_slice = try writer.toOwnedSlice();
    defer testing.allocator.free(out_slice);

    try testing.expectEqualStrings("Hello, World! This is pure Zig bzip2 decompressor.\n", out_slice);
}
