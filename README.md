# deb-zig

A pure Zig library for creating and assembling Debian binary packages (`.deb`) without external dependencies. No `dpkg-deb`, `ar`, or system tools required.

## Features

- **Self-contained**: Native `ar`, `tar`, and `gzip` generation in Zig with GNU long path and long link extension support.
- **Reproducible**: Normalizes ownership (`root:root`), file modes, deterministic sorting, and timestamps.
- **Automatic hierarchy**: Automatically synthesizes missing intermediate parent directories with `0755` permissions.
- **Lintian validation**: Built-in validation of package names, versions, architectures, maintainer emails, and conffiles according to Debian policy.
- **Automatic metadata**: Computes `Installed-Size` and generates `md5sums` automatically if omitted.
- **ZON & RFC-822**: Configure package metadata using standard Debian `control` syntax, Zig struct literals, or `deb.zon`. Supports compile-time (`comptime`) conversion.
- **Flexible assembly**: Build directly from filesystem artifact directories or programmatically in memory.

---

## Quick Start

### 1. Build from an artifact directory

If you already have a directory layout containing your binary and metadata:

```
zig-out/pkg-root/
├── DEBIAN/
│   ├── control
│   └── postinst (optional)
└── usr/
    └── bin/
        └── my-app
```

Assemble it into a `.deb` file:

```zig
const std = @import("std");
const deb = @import("deb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try deb.Builder.buildFromDir(
        io,
        gpa,
        "zig-out/pkg-root",
        "zig-out/my-app_1.0.0_amd64.deb",
        .{}, // Options: mtime, uid, gid, auto_installed_size, auto_md5sums
    );
}
```

> **Tip:** You can replace `DEBIAN/control` with a simple `deb.zon` file at the root of your package directory.

---

### 2. Assemble programmatically with ZON

You can define package files and metadata directly in Zig:

```zig
const std = @import("std");
const deb = @import("deb");

pub fn buildPackage(allocator: std.mem.Allocator, io: std.Io) !void {
    var builder = try deb.Builder.initFromZon(allocator, .{
        .control = .{
            .package = "my-app",
            .version = "1.0.0-1",
            .architecture = "amd64",
            .maintainer = "Your Name <you@example.com>",
            .description =
                \\High performance utility
                \\Built entirely in Zig.
            ,
            .depends = .{ "libc6 (>= 2.34)", "curl" },
            .homepage = "https://example.com/my-app",
        },
        .postinst = "#!/bin/sh\necho 'my-app installed'\n",
    });
    defer builder.deinit();

    // Add directories, binaries, and symlinks
    try builder.addDir("usr/bin", 0o755);
    try builder.addFile("usr/bin/my-app", binary_contents, 0o755);
    try builder.addSymlink("usr/bin/my-alias", "my-app");

    // Write out the archive
    try builder.writeFile(io, allocator, "my-app_1.0.0-1_amd64.deb", .{});
}
```

---

### 3. Programmatic build with typed `ControlInfo`

```zig
var builder = deb.Builder.init(allocator);
defer builder.deinit();

builder.setControl(.{
    .package = "my-app",
    .version = "1.0.0",
    .architecture = "amd64",
    .maintainer = "Jane Doe <jane@example.com>",
    .description = "Command line tool",
    .section = "utils",
});

try builder.addFile("usr/bin/my-app", binary_bytes, 0o755);
try builder.writeFile(io, allocator, "my-app_1.0.0_amd64.deb", .{});
```

---

## Options

`deb.Builder.Options` provides control over package reproducibility:

| Field | Default | Description |
|---|---|---|
| `mtime` | `0` | UNIX timestamp for files inside archives (epoch 0 for deterministic builds). |
| `uid` / `gid` | `0` / `0` | Archive file ownership (defaults to root). |
| `uname` / `gname` | `"root"` | Archive username and group name. |
| `auto_installed_size` | `true` | Calculates package payload size in KiB and updates control metadata. |
| `auto_md5sums` | `true` | Generates standard `md5sums` member if missing. |
| `validate` | `true` | Validates package name, version, architecture, maintainer email, and conffiles. |

---

## Running Tests

```bash
zig build test
```

## License

MIT
