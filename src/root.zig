//! Pure Zig Debian package toolkit: packaging, metadata, Debconf protocol, and sysroot generation.

const std = @import("std");

pub const Builder = @import("deb/Builder.zig");
pub const sysroot = @import("sysroot.zig");

pub const Package = @import("deb/Package.zig");
pub const rfc822 = @import("deb/rfc822.zig");
pub const Version = @import("deb/Version.zig");
pub const Release = @import("deb/Release.zig");

test {
    _ = @import("tests.zig");
}
