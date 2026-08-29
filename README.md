# deb-zig

A pure Zig toolkit for **building `.deb` packages** and **bootstrapping Debian cross-compilation sysroots** — no `dpkg-deb`, `ar`, `sudo`, or `chroot` required.

---

## Why deb-zig?

- **Zero System Dependencies**: Native Zig implementations of `ar`, `tar`, `gzip`, and HTTP. Runs anywhere Zig runs.
- **Reproducible Packages**: Deterministic file sorting, normalized `root:root` ownership, custom epoch timestamps, and automatic `md5sums` + `Installed-Size` injection.
- **Pure User-Space Sysroots**: Pulls packages directly from Debian mirrors, resolves transitive dependency trees, relativizes symlinks, and patches GNU `ld` scripts for seamless `zig cc` / `clang` / `gcc` cross-compilation.
- **Debian Policy Compliant**: Built-in validation for package names, versions (epochs, revisions, tilde ordering), architectures, maintainer emails, and conffiles.

---

## Adding to your project

In your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .dependencies = .{
        .deb = .{
            .url = "https://github.com/your-username/deb-zig/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

In your `build.zig`:

```zig
const deb_dep = b.dependency("deb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("deb", deb_dep.module("deb"));
```

---

## Quick Recipes

### 1. Build a `.deb` from a directory

If you already have your files laid out:

```
zig-out/pkg-root/
├── DEBIAN/
│   ├── control        # Standard Debian control file (or deb.zon)
│   └── postinst       # Optional install scripts
└── usr/
    └── bin/
        └── my-app
```

Assemble it with one function call:

```zig
const deb = @import("deb");

pub fn main(init: std.process.Init) !void {
    try deb.Builder.buildFromDir(
        init.io,
        init.gpa,
        "zig-out/pkg-root",
        "zig-out/my-app_1.0.0_amd64.deb",
        .{}, // Options: mtime, uid, gid, compression_level (.fastest, .default, .best)
    );
}
```

---

### 2. Build a `.deb` programmatically

Define your package metadata and payload directly in code:

```zig
const deb = @import("deb");

pub fn buildPackage(allocator: std.mem.Allocator, io: std.Io) !void {
    var builder = try deb.Builder.initFromZon(allocator, .{
        .control = .{
            .package = "my-app",
            .version = "1.0.0-1",
            .architecture = "amd64",
            .maintainer = "Jane Doe <jane@example.com>",
            .description = "High-performance CLI tool built in Zig",
            .depends = "libc6 (>= 2.34), libssl3",
            .homepage = "https://example.com/my-app",
        },
        .postinst = "#!/bin/sh\necho 'Installed my-app'\n",
    });
    defer builder.deinit();

    try builder.addFile("usr/bin/my-app", binary_contents, 0o755);
    try builder.addSymlink("usr/bin/my-alias", "my-app");

    try builder.writeFile(io, allocator, "my-app_1.0.0-1_amd64.deb", .{
        .compression_level = .best,
    });
}
```

---

### 3. Generate a Cross-Compilation Sysroot

Fetch headers, shared libraries, and pkg-config files from Debian mirrors without root:

```zig
const deb = @import("deb");

pub fn setupSysroot(allocator: std.mem.Allocator, io: std.Io) !void {
    try deb.sysroot.buildSysroot(allocator, io, .{
        .suite = "trixie",
        .arch = "arm64", // Supports "armhf", "arm64", "x86_64-linux-gnu", "riscv64", etc.
        .target = "sysroot-arm64",
        .packages = &.{
            "libc6-dev",
            "libssl-dev",
            "zlib1g-dev",
        },
    });
}
```

This creates a self-contained, relocatable sysroot and generates `sysroot-arm64/environment.sh`:

```bash
source sysroot-arm64/environment.sh
# Now PKG_CONFIG_SYSROOT_DIR, PKG_CONFIG_LIBDIR, CFLAGS, and LDFLAGS are set!
zig cc --sysroot=$SYSROOT main.c -lssl -lcrypto
```

---

### 4. Unpack Packages into an Existing Sysroot

Install `.deb` files (or entire directories of `.deb`s) into an already built sysroot with automatic post-processing fixups:

```zig
const deb = @import("deb");

pub fn addExtraPackages(allocator: std.mem.Allocator, io: std.Io) !void {
    // Unpack a single .deb (or a directory containing .debs)
    try deb.unpackDeb(allocator, io, "sysroot-arm64", "my-custom-lib_1.0_arm64.deb", .{
        .fixup = true, // Automatically relativizes symlinks & patches ld scripts
    });

    // Or unpack multiple packages / directories at once
    try deb.unpackDebs(allocator, io, "sysroot-arm64", &.{
        "extra_pkgs/",
        "local_debs/libfoo_1.0_arm64.deb",
    }, .{ .fixup = true });
}
```

---

### 5. Debian Version & Metadata Utilities

```zig
const deb = @import("deb");

// Compare versions exactly like `dpkg --compare-versions`
const ord = deb.Version.compare("1:2.0~alpha1-1", "1:2.0-1"); // .lt

// Parse Debian RFC-822 control paragraphs
var it = deb.rfc822.Iterator.init(packages_file_text);
while (try it.next(allocator)) |paragraph| {
    var p = paragraph;
    defer p.deinit(allocator);
    const name = p.get("Package");
    const ver = p.get("Version");
}
```

---

## Testing

```bash
zig build test
```

## License

[MIT](LICENSE)


