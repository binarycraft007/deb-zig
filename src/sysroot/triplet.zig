const std = @import("std");

/// Converts an architecture name or target triplet to the canonical Debian repository architecture name (e.g. "armhf", "amd64", "arm64").
pub fn normalizeDebianArch(input: []const u8) []const u8 {
    if (std.mem.eql(u8, input, "arm-linux-gnueabihf") or
        std.mem.eql(u8, input, "armhf") or
        std.mem.eql(u8, input, "armv7") or
        std.mem.eql(u8, input, "armv7a") or
        std.mem.eql(u8, input, "armv7-a") or
        std.mem.eql(u8, input, "armv7l"))
    {
        return "armhf";
    }

    if (std.mem.eql(u8, input, "arm-linux-gnueabi") or
        std.mem.eql(u8, input, "armel") or
        std.mem.eql(u8, input, "armv5") or
        std.mem.eql(u8, input, "armv6") or
        std.mem.eql(u8, input, "armv6l"))
    {
        return "armel";
    }

    if (std.mem.eql(u8, input, "aarch64-linux-gnu") or
        std.mem.eql(u8, input, "aarch64") or
        std.mem.eql(u8, input, "arm64"))
    {
        return "arm64";
    }

    if (std.mem.eql(u8, input, "x86_64-linux-gnu") or
        std.mem.eql(u8, input, "x86_64") or
        std.mem.eql(u8, input, "amd64"))
    {
        return "amd64";
    }

    if (std.mem.eql(u8, input, "i386-linux-gnu") or
        std.mem.eql(u8, input, "i686-linux-gnu") or
        std.mem.eql(u8, input, "i386") or
        std.mem.eql(u8, input, "i686") or
        std.mem.eql(u8, input, "x86"))
    {
        return "i386";
    }

    if (std.mem.eql(u8, input, "riscv64-linux-gnu") or
        std.mem.eql(u8, input, "riscv64"))
    {
        return "riscv64";
    }

    if (std.mem.eql(u8, input, "powerpc64le-linux-gnu") or
        std.mem.eql(u8, input, "ppc64le") or
        std.mem.eql(u8, input, "ppc64el"))
    {
        return "ppc64el";
    }

    if (std.mem.eql(u8, input, "s390x-linux-gnu") or
        std.mem.eql(u8, input, "s390x"))
    {
        return "s390x";
    }

    if (std.mem.eql(u8, input, "mips64el-linux-gnuabi64") or
        std.mem.eql(u8, input, "mips64el"))
    {
        return "mips64el";
    }

    if (std.mem.eql(u8, input, "mipsel-linux-gnu") or
        std.mem.eql(u8, input, "mipsel"))
    {
        return "mipsel";
    }

    if (std.mem.eql(u8, input, "loongarch64-linux-gnu") or
        std.mem.eql(u8, input, "loong64"))
    {
        return "loong64";
    }

    return input;
}

/// Converts a Debian architecture name or short name to the canonical GNU multiarch triplet (e.g. "arm-linux-gnueabihf", "x86_64-linux-gnu").
pub fn archToTriplet(input: []const u8) []const u8 {
    const deb_arch = normalizeDebianArch(input);

    if (std.mem.eql(u8, deb_arch, "amd64")) return "x86_64-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "arm64")) return "aarch64-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "armhf")) return "arm-linux-gnueabihf";
    if (std.mem.eql(u8, deb_arch, "armel")) return "arm-linux-gnueabi";
    if (std.mem.eql(u8, deb_arch, "riscv64")) return "riscv64-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "i386")) return "i386-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "ppc64el")) return "powerpc64le-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "s390x")) return "s390x-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "mips64el")) return "mips64el-linux-gnuabi64";
    if (std.mem.eql(u8, deb_arch, "mipsel")) return "mipsel-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "mips")) return "mips-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "loong64")) return "loongarch64-linux-gnu";
    if (std.mem.eql(u8, deb_arch, "sparc64")) return "sparc64-linux-gnu";

    return input;
}

pub fn is64BitArch(input: []const u8) bool {
    const deb_arch = normalizeDebianArch(input);
    return std.mem.eql(u8, deb_arch, "amd64") or
        std.mem.eql(u8, deb_arch, "arm64") or
        std.mem.eql(u8, deb_arch, "riscv64") or
        std.mem.eql(u8, deb_arch, "ppc64el") or
        std.mem.eql(u8, deb_arch, "s390x") or
        std.mem.eql(u8, deb_arch, "mips64el") or
        std.mem.eql(u8, deb_arch, "loong64") or
        std.mem.eql(u8, deb_arch, "sparc64");
}

test "Bidirectional architecture and triplet normalization" {
    const testing = std.testing;

    // Both Debian arch and GNU triplet resolve to arm-linux-gnueabihf
    try testing.expectEqualStrings("armhf", normalizeDebianArch("armhf"));
    try testing.expectEqualStrings("armhf", normalizeDebianArch("arm-linux-gnueabihf"));
    try testing.expectEqualStrings("armhf", normalizeDebianArch("armv7-a"));
    try testing.expectEqualStrings("arm-linux-gnueabihf", archToTriplet("armhf"));
    try testing.expectEqualStrings("arm-linux-gnueabihf", archToTriplet("arm-linux-gnueabihf"));

    // ARM64 / aarch64
    try testing.expectEqualStrings("arm64", normalizeDebianArch("arm64"));
    try testing.expectEqualStrings("arm64", normalizeDebianArch("aarch64-linux-gnu"));
    try testing.expectEqualStrings("aarch64-linux-gnu", archToTriplet("arm64"));
    try testing.expectEqualStrings("aarch64-linux-gnu", archToTriplet("aarch64-linux-gnu"));

    // x86_64 / amd64
    try testing.expectEqualStrings("amd64", normalizeDebianArch("amd64"));
    try testing.expectEqualStrings("amd64", normalizeDebianArch("x86_64-linux-gnu"));
    try testing.expectEqualStrings("x86_64-linux-gnu", archToTriplet("amd64"));
    try testing.expectEqualStrings("x86_64-linux-gnu", archToTriplet("x86_64-linux-gnu"));

    // 64-bit detection
    try testing.expect(is64BitArch("amd64"));
    try testing.expect(is64BitArch("arm64"));
    try testing.expect(!is64BitArch("armhf"));
    try testing.expect(!is64BitArch("arm-linux-gnueabihf"));
}
