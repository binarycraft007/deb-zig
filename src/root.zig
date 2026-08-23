//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const ar = @import("ar.zig");
pub const tar = @import("tar.zig");

test {
    _ = ar;
    _ = tar;
}
