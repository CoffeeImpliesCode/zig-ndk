//! zig-ndk — Android NDK sysroot facts, for Zig 0.16.0.
//!
//! Zig 0.16.0 ships no NDK awareness and bundles no bionic, so
//! `zig build-exe -target aarch64-linux-android -lc` fails with
//! `error: unable to provide libc for target '…'`. This package closes that
//! one gap and nothing wider: it describes where an unpacked Android NDK keeps
//! its sysroot and finds that tree, so that a Zig build can hand Zig the libc
//! paths file Zig requires and cannot derive for itself.
//!
//! **This is not a translation of the NDK's build systems.** `ndk-build` and
//! the NDK CMake toolchain file are out of scope by decision, not by omission;
//! reproducing them is a different project. What ships here is pure Zig that
//! reads a directory layout. No C, no header, and no part of the NDK is
//! redistributed.
//!
//! Usage from a dependent build.zig:
//!
//! ```zig
//! const ndk_dep = b.dependency("zig_ndk", .{});
//! const zig_ndk = @import("zig_ndk");
//!
//! Facts, for your own Zig code: Abi, HostTag, Ndk, LibcPaths, Error.
//! exe.root_module.addImport("ndk", ndk_dep.module("ndk"));
//!
//! // Wiring, for a compilation.
//! exe.linkage = .dynamic; // emits -dynamic; bionic supplies the interpreter
//! _ = try zig_ndk.linkAndroid(ndk_dep.builder, ndk_dep.module("ndk"), exe, .{
//!     .abi = "arm64-v8a",
//!     .api_level = 35,
//!     // .ndk = null -> ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_NDK, in
//!     // that order
//! });
//! ```
//! The package name is `zig_ndk`, underscore: `build.zig.zon` declares
//! `.name = .zig_ndk` as an enum literal, and Zig 0.16 derives the dependency
//! name from that token. A hyphen is not another spelling of it. Spelling it
//! that way panics the dependent's build script with "no dependency named
//! 'zig-ndk'", before any of this package's code runs.
//!
//! `linkAndroid` does the discovery, renders the libc paths file through
//! `LibcPaths`, writes it into the build cache, and sets
//! `compile.root_module.link_libc` so the runner emits `-lc`. Call it once per
//! compilation: a second call on the same `compile` is refused with
//! `error.AlreadyLinked`, because `Compile.setLibCFile` is last-call-wins. A
//! silent replacement is worse than a wrong one — an API-24 CRT directory
//! under a target query that says API 35 links into an undefined `statx`
//! instead of into a diagnosable error. It does **not** pass
//! `--sysroot` — `b.sysroot` is a whole-`Build`
//! field, so setting it would leak this NDK into every other compilation in
//! your build, and the sysroot is fully expressed by the paths file's CRT
//! directory, which the ELF linker turns into `-L` itself. `exe.linkage` is
//! yours to set; `linkAndroid` does not touch it.
//!
//! Ownership: `Ndk` **borrows**. It owns no memory. Every path it hands back is
//! either a slice you supplied or a slice whose lifetime is the build run.
//! There is no `deinit`, and that absence is the contract rather than an
//! oversight: a caller that needs a path after the run must copy it into
//! storage it owns, and the type gives it no way to believe otherwise.

const std = @import("std");

// Re-exports are spelled out one by one. `usingnamespace` and `pub use` would
// each forward whatever the descriptor module happens to grow, which is a
// surface no reader can review in this file; the flat index `lib/std/std.zig`
// keeps at this compiler line is the precedent.

/// The five Android NDK ABI directory names, as shipped in the NDK's own
/// `meta/abis.json`. Owned by nothing; every method is a pure function of the
/// tag.
pub const Abi = @import("src/ndk.zig").Abi;

/// The NDK's prebuilt-toolchain directory names — `linux-x86_64`,
/// `darwin-x86_64`, `windows-x86_64` — which are the only part of the sysroot
/// path a host contributes. Exactly three, and every one of them an x86_64
/// tag: Google publishes no arm NDK package for any host, so `aarch64-linux`
/// and `aarch64-windows` have no toolchain to point at and fail as
/// `UnsupportedHost` rather than as a missing directory. `aarch64-macos` is
/// the exception and still resolves, because it runs the `darwin-x86_64`
/// package under Rosetta.
pub const HostTag = @import("src/ndk.zig").HostTag;

/// A resolved installation: the NDK root, the host tag it was resolved for, and
/// the sysroot beneath it. A borrowed view of a directory tree; see the module
/// comment for why it has no `deinit`.
pub const Ndk = @import("src/ndk.zig").Ndk;

/// Every refusal a caller can act on. Closed by construction: this set names
/// what `Ndk` refuses and nothing else, so a `switch` over a failure is
/// exhaustive without an `else`.
pub const Error = @import("src/ndk.zig").Error;

/// The libc paths file `std.zig.LibCInstallation.parse` reads, and this
/// package's only renderer for it. `forAndroid` takes the directories and
/// `render` writes the bytes; the format's single home is `src/libc_file.zig`,
/// which is also where the build script's generated helper gets its text.
///
/// A consumer reaches for this when it writes the file itself — its own
/// configure step, or a test that pins the bytes against Zig's own parser. A
/// consumer that wants only a linked Android binary does not: `linkAndroid`
/// renders and writes it. This is the module root rather than that file's own
/// `LibcPaths` alias, because the alias is private and a private container
/// declaration cannot be reached through `@import`; the two are one type.
///
/// A `LibcPaths` **owns** its three paths, where `Ndk` borrows: `forAndroid`
/// copies them, and `deinit` takes back the allocator `forAndroid` was given.
/// `render` allocates nothing and leaves flushing to its writer.
pub const LibcPaths = @import("src/libc_file.zig");

comptime {
    // The ABI table is a derived fact. It was read from r29's
    // `meta/abis.json`, and `tools/sync-ndk.sh` is what notices when the NDK
    // moves underneath it. What that script cannot see is a table edited into
    // a shape the NDK would never ship, so the table is held here to
    // properties the NDK does not state anywhere.
    //
    // Every loop below walks `std.enums.values(Abi)` rather than a hand-copied
    // tag list. A check written over a copied list keeps passing after the real
    // list grows, which is the failure this exists to prevent.
    @setEvalBranchQuota(4000);

    const abis = std.enums.values(Abi);

    // Five ABIs ship in r29. A sixth is a real change to the NDK and has to
    // arrive with a re-read of `meta/abis.json` and a new entry in
    // `tools/ndk.sha256` — not with an edit to the constant below.
    if (abis.len != 5) {
        @compileError(std.fmt.comptimePrint(
            "zig-ndk: the ABI table has {d} entries; r29's meta/abis.json has 5. " ++
                "Re-read the NDK, then update tools/ndk.sha256 and CHANGELOG.md.",
            .{abis.len},
        ));
    }

    for (abis) |abi| {
        // An empty name does not fail at configure time. It produces `usr/lib`
        // instead of `usr/lib/<triple>`, which is a real directory holding a
        // `libc.a` for every ABI at once.
        if (abi.name().len == 0 or abi.triple().len == 0) {
            @compileError(std.fmt.comptimePrint(
                "zig-ndk: {s} has an empty ABI name or sysroot triple.",
                .{@tagName(abi)},
            ));
        }

        // Android, by Zig's own reckoning. An ABI mapped to `.musl` or `.gnu`
        // resolves the libc paths file against the wrong sysroot and links a
        // libc that is not bionic.
        switch (abi.zigAbi()) {
            .android, .androideabi => {},
            else => @compileError(std.fmt.comptimePrint(
                "zig-ndk: {s} does not map to a Zig Android ABI.",
                .{@tagName(abi)},
            )),
        }

        // r29 declares 21 as the floor for four ABIs and 35 for riscv64. No
        // Android release the NDK targets is below 21, so a smaller number is a
        // typo that would resolve to a directory the sysroot does not carry.
        if (abi.minApiLevel() < 21) {
            @compileError(std.fmt.comptimePrint(
                "zig-ndk: {s} declares minimum API level {d}; r29's floor is 21.",
                .{ @tagName(abi), abi.minApiLevel() },
            ));
        }
    }

    // Distinctness. Two ABIs sharing a triple resolve to one `usr/lib/<triple>`
    // directory, so the CRT objects and `libc.a` picked for one of them are
    // the other's. Both paths exist, so nothing downstream complains.
    for (abis, 0..) |a, i| {
        for (abis, 0..) |b, j| {
            if (j <= i) continue;
            if (std.mem.eql(u8, a.triple(), b.triple())) {
                @compileError(std.fmt.comptimePrint(
                    "zig-ndk: {s} and {s} share the sysroot triple {s}.",
                    .{ @tagName(a), @tagName(b), a.triple() },
                ));
            }
            if (std.mem.eql(u8, a.name(), b.name())) {
                @compileError(std.fmt.comptimePrint(
                    "zig-ndk: {s} and {s} share the ABI name {s}.",
                    .{ @tagName(a), @tagName(b), a.name() },
                ));
            }
        }
    }

    // The one hazard the table carries today, pinned at a count. Zig resolves a
    // bare `-Dtarget=riscv64-linux-android` to API level 29
    // (`lib/std/Target.zig:484`, `.android = 29`), and r29 ships no
    // `usr/lib/riscv64-linux-android/29`: the floor is 35. A second high-floor
    // ABI, or a floor that moves, fails here rather than later as a directory
    // that is not there. Raising the constant is a deliberate act.
    const zig_default_android_api_level = 29;
    var above_default: usize = 0;
    for (abis) |abi| {
        if (abi.minApiLevel() > zig_default_android_api_level) above_default += 1;
    }
    if (above_default != 1) {
        @compileError(std.fmt.comptimePrint(
            "zig-ndk: {d} ABIs declare a floor above Zig's default Android API " ++
                "level of {d}; r29 has exactly one, riscv64 at 35.",
            .{ above_default, zig_default_android_api_level },
        ));
    }
}

test {
    std.testing.refAllDecls(@This());
}
