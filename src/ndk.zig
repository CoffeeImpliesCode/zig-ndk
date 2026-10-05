//! Android NDK discovery and layout facts for Zig 0.16.0.
//!
//! Zig 0.16.0 has no NDK awareness at all: `lib/std/Build.zig` never mentions
//! android, and `lib/libc/` ships darwin, freebsd, glibc, mingw, musl, netbsd,
//! openbsd, wasi and include. There is no bionic. A freestanding
//! `aarch64-linux-android` binary links; anything that needs `libc.so`, the CRT
//! objects or `stdio.h` does not, because there is nothing to point at.
//!
//! This module resolves an NDK installation on disk and reports where its
//! sysroot, its per-ABI libraries and its per-API-level CRT objects live. The
//! five ABI facts below were read from r29's `meta/abis.json`, not from a
//! specification; nothing here hardcodes a path table, so an NDK at another
//! revision, host tag or API level is described by probing it.

const std = @import("std");

const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const File = std.Io.File;
const Io = std.Io;
const Target = std.Target;
const Writer = std.Io.Writer;
const path = std.fs.path;

/// Every refusal a caller of this module can act on.
///
/// Closed. No declaration in this file widens it to `anyerror`. The only other
/// errors that can surface are `Allocator.Error` and the filesystem errors of
/// `std.Io.Dir`, both of which pass through unchanged because they describe the
/// machine, not the NDK.
pub const Error = error{
    /// No source named an NDK: none was set at all, or every source that was
    /// set names a path that is not on disk. The caller can act by pointing the
    /// `-Dndk` build option, or one of `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`,
    /// `ANDROID_NDK`, at an unpacked installation, and
    /// `Ndk.describeDiscoveryFailure` renders the four with what each read.
    ///
    /// An explicit `-Dndk` that is not on disk lands here too, and that is what
    /// the option is for: `Ndk.find` treats it as a pin rather than as the first
    /// of four preferences, so it cannot be answered by whatever
    /// `ANDROID_NDK_HOME` the runner image happened to export. "The path I
    /// named is not there" and "no shell set anything here" are different
    /// mistakes, and the walk stops at both rather than reporting a success it
    /// cannot vouch for.
    NdkNotFound,
    /// A root does not hold a usable installation: neither layout probed under
    /// it holds a `toolchains/llvm/prebuilt/<host-tag>/sysroot`. The caller
    /// pointed at an archive rather than an unpacked NDK, at an SDK root rather
    /// than an NDK, or at an NDK unpacked for another host tag. `Ndk.Shape`
    /// names the two layouts that are recognised; `Ndk.probeCandidates` names
    /// the two paths that were probed under any root, and
    /// `Ndk.describeProbeFailure` renders the refusal message CONTRACT.md D3
    /// asks for.
    ///
    /// Two paths reach this member without that meaning, and each says so where
    /// it is produced, because a caller who renders this member's message has
    /// to be able to tell them apart.
    ///
    /// `Ndk.open` puts a root that is missing altogether, or is a regular file,
    /// here as well: `open` has no next source to walk past, so a root it
    /// cannot use has nowhere else to go. Its own doc lists those cases, and
    /// `describeProbeFailure` still answers them — a report for a path that is
    /// not there is what tells the reader that it is not there.
    ///
    /// `Ndk.readVersion` puts a root that stopped being a directory here: the
    /// installation resolved a moment earlier has been moved, removed, or
    /// replaced by a file. Nothing about its layout is wrong, no probe was
    /// refused, and `describeProbeFailure` is then misleading rather than
    /// helpful — it names two sysroot paths for an installation that had
    /// already resolved, and every path in that report is one nobody looked
    /// for. The action is to resolve again, not to read a report.
    NotAnNdk,
    /// The host has no NDK host tag, so no NDK package ships a prebuilt
    /// toolchain for it. The caller can act only by building on one of the
    /// hosts in `HostTag`, or by crossing the NDK toolchain by hand.
    UnsupportedHost,
    /// This NDK has no `usr/lib/<triple>` for the requested ABI, so the ABI is
    /// not among the ones this NDK ships. The caller can act by picking an ABI
    /// this NDK carries.
    UnsupportedAbi,
    /// `usr/lib/<triple>` exists but holds no directory for that API level.
    /// The caller can act by picking one of `Ndk.apiLevelsFor`.
    ApiLevelUnavailable,
    /// `source.properties` is present but holds no parsable `Pkg.Revision`. The
    /// installation is otherwise fully usable; only its version is unknown.
    VersionUnreadable,
};

/// Filesystem refusals that pass through `Ndk.open`, `Ndk.find`,
/// `Ndk.libcDirFor`, `Ndk.apiLevelsFor`, `Ndk.probeCandidates`,
/// `Ndk.describeProbeFailure` and `Ndk.readVersion` unchanged.
///
/// Probing is a `stat`, not an `access`. `Dir.AccessError` is gone because
/// nothing calls `Dir.accessAbsolute` any more, and an error set that names a
/// failure no call can produce is a claim this file cannot keep. Nothing a
/// caller can observe leaves with it: `AccessDenied` and `PermissionDenied`
/// are members of `File.OpenError`, which `Dir.StatFileError` includes.
const FsError = Dir.RealPathFileAllocError || Dir.StatFileError || Dir.OpenError ||
    Dir.ReadFileAllocError || Dir.Iterator.Error;

/// The largest `source.properties` `Ndk.readVersion` will read.
///
/// The r29 file is four lines of about 110 bytes. A megabyte is generous
/// enough that no real NDK hits the limit and small enough that pointing this
/// at a wrong file cannot exhaust memory.
const max_properties_bytes = 1024 * 1024;

/// One of the five ABIs an NDK ships libraries for.
///
/// The name is the key of this ABI's entry in r29's `meta/abis.json`, and the
/// value `ANDROID_ABI` takes. `sysroot/usr/lib/` is namespaced by sysroot
/// triple instead, so a directory is `triple` and never a name.
///
/// The Zig tag is the ABI name with `-` written `_`. That is a spelling
/// change, not an identity: `.armeabi_v7a` and `.arm64_v8a` carry the
/// `v7a`/`v8a` marker that their library triple does not, and no tag here is
/// the NDK's own spelling of anything. Reach that spelling through `name`,
/// never through `@tagName`.
pub const Abi = enum {
    /// `armeabi-v7a`: 32-bit ARM, API 21 floor.
    armeabi_v7a,
    /// `arm64-v8a`: 64-bit ARM, API 21 floor.
    arm64_v8a,
    /// `riscv64`: 64-bit RISC-V, API 35 floor. The only ABI r29 ships one
    /// API level for.
    riscv64,
    /// `x86`: 32-bit Intel, API 21 floor.
    x86,
    /// `x86_64`: 64-bit Intel, API 21 floor.
    x86_64,

    /// The ABI's name as the NDK's own tooling writes it: the key of its entry
    /// in `meta/abis.json`, and the value `ANDROID_ABI` takes.
    ///
    /// Not a path component of the sysroot. `sysroot/usr/lib/` is namespaced by
    /// sysroot triple, and `triple` returns that; `fromName` is the inverse.
    ///
    /// Borrowed from a string literal, so the slice has static lifetime and
    /// the caller frees nothing.
    pub fn name(self: Abi) []const u8 {
        return switch (self) {
            .armeabi_v7a => "armeabi-v7a",
            .arm64_v8a => "arm64-v8a",
            .riscv64 => "riscv64",
            .x86 => "x86",
            .x86_64 => "x86_64",
        };
    }

    /// The ABI whose NDK name is exactly `wanted`, or `null` when no ABI
    /// carries that name.
    ///
    /// Exact byte equality, and nothing looser. No case folding — the NDK
    /// spells `x86_64` in lower case and a case-folded match would accept a
    /// name the NDK never writes. No trimming — a leading or trailing space is
    /// a name the NDK does not write. No separator or suffix stripping —
    /// `arm64_v8a` is the Zig tag for `arm64-v8a`, and accepting the tag
    /// spelling would let a caller pass `-Dabi=arm64_v8a` and silently get
    /// the ABI for a name no NDK tooling writes.
    ///
    /// This is the inverse of `name`, and it exists so that a consumer turning
    /// a name it was given back into an ABI does not carry its own copy of the
    /// five-entry table. Two copies are how two callers come to disagree about
    /// whether `arm64-v8a` is a valid ABI.
    ///
    /// `null` for the empty string and for every name not in the table. It is a
    /// pure function of the tag; nothing here touches the filesystem, so a
    /// `null` says the name is not one of the five, not that the ABI is missing
    /// from some particular installation.
    pub fn fromName(wanted: []const u8) ?Abi {
        for (std.enums.values(Abi)) |abi| {
            if (std.mem.eql(u8, abi.name(), wanted)) return abi;
        }
        return null;
    }

    /// The sysroot triple this ABI's libraries live under.
    ///
    /// This is neither a Zig triple nor the ABI name. It is the
    /// `triple` field of the ABI's entry in `meta/abis.json`, and it is the
    /// directory name directly under `sysroot/usr/lib`, above the API levels.
    ///
    /// Borrowed from a string literal; the caller frees nothing.
    pub fn triple(self: Abi) []const u8 {
        return switch (self) {
            .armeabi_v7a => "arm-linux-androideabi",
            .arm64_v8a => "aarch64-linux-android",
            .riscv64 => "riscv64-linux-android",
            .x86 => "i686-linux-android",
            .x86_64 => "x86_64-linux-android",
        };
    }

    /// The lowest API level the NDK declares for this ABI, as `min_os_version`.
    ///
    /// A floor, not an inventory. `Ndk.apiLevelsFor` reports what is actually
    /// on disk, and the two differ whenever an NDK ships fewer levels than it
    /// permits: r29 declares 35 for `riscv64` and puts only 35 in the tree,
    /// while the other four declare 21 and ship 21 upward.
    pub fn minApiLevel(self: Abi) u32 {
        return switch (self) {
            .riscv64 => 35,
            .armeabi_v7a, .arm64_v8a, .x86, .x86_64 => 21,
        };
    }

    /// The `std.Target.Abi` a Zig cross build for this ABI must carry.
    ///
    /// Only 32-bit ARM is `.androideabi`; every other ABI is `.android`. The
    /// distinction is not cosmetic. Zig picks the dynamic linker from the pair
    /// (`std.Target`: `/system/bin/linker` for `arm` under `.androideabi`,
    /// `/system/bin/linker64` for the 64-bit arches under `.android`) and picks
    /// soft-float for `.androideabi`, so the wrong one either builds with the
    /// wrong ABI or links nothing at all.
    pub fn zigAbi(self: Abi) Target.Abi {
        return switch (self) {
            .armeabi_v7a => .androideabi,
            .arm64_v8a, .riscv64, .x86, .x86_64 => .android,
        };
    }
};

/// The host tags the NDK publishes a prebuilt LLVM toolchain for: exactly
/// three, all of them x86_64.
///
/// Source, and the reason the obvious-looking additions are absent. Google's
/// own repository manifest for r29,
/// https://dl.google.com/android/repository/repository2-3.xml, offers exactly
/// three host packages and their betas:
///
///   android-ndk-r29-linux.zip      <host-os>linux</host-os>
///   android-ndk-r29-darwin.zip     <host-os>macosx</host-os>
///   android-ndk-r29-windows.zip    <host-os>windows</host-os>
///   android-ndk-r29-beta{1..4}-{linux,darwin,windows}.zip
///
/// There is no linux-arm package and no darwin-arm package. Google's host-tag
/// table at https://developer.android.com/ndk/guides/other_build_systems
/// agrees: three rows, `darwin-x86_64`, `linux-x86_64`, `windows-x86_64`. The
/// macOS package is named `darwin-x86_64` and runs on Apple Silicon under
/// Rosetta; Google never emits `darwin-arm64`.
///
/// The r29 tree unpacked on this host agrees, with a single prebuilt directory:
/// `toolchains/llvm/prebuilt/linux-x86_64`.
///
/// Do not add `linux_aarch64` or `darwin_arm64` back. Both look obviously
/// necessary and neither exists, and having them here turns "no NDK is
/// published for this host" into a misleading `error.NotAnNdk` about a
/// path the user configured. A host that cannot be served has to fail as
/// `error.UnsupportedHost`, which is a different problem with a different fix.
///
/// The Zig tag is the on-disk host tag with `-` written `_`; `directoryName`
/// returns the on-disk spelling, which is what appears under
/// `toolchains/llvm/prebuilt/`.
pub const HostTag = enum {
    /// `linux-x86_64`.
    linux_x86_64,
    /// `darwin-x86_64`. The only macOS package; runs on Apple Silicon under
    /// Rosetta, and is the tag for an `aarch64-macos` host too.
    darwin_x86_64,
    /// `windows-x86_64`.
    windows_x86_64,

    /// The exact directory name under `toolchains/llvm/prebuilt/`.
    ///
    /// Borrowed from a string literal; the caller frees nothing.
    pub fn directoryName(self: HostTag) []const u8 {
        return switch (self) {
            .linux_x86_64 => "linux-x86_64",
            .darwin_x86_64 => "darwin-x86_64",
            .windows_x86_64 => "windows-x86_64",
        };
    }
};

/// A resolved Android NDK installation: a borrowed view of a directory tree.
///
/// Ownership is the whole point of this type, so it is worth stating plainly.
/// An `Ndk` owns no memory and has deliberately no `deinit`. Every slice it
/// stores was allocated from the allocator the caller passed to `find` or
/// `open`; in a build script that is the build runner's allocator, whose
/// lifetime is the build. There is no `deinit` so that a caller cannot be led
/// to believe the value owns anything it might leak, and so that a caller who
/// needs a path after the build knows to copy it into storage it owns. Freeing
/// is the allocator's business, not this type's.
pub const Ndk = struct {
    /// The directory that actually holds `source.properties`, `meta/` and
    /// `toolchains/`, after the `Shape` relocation. Absolute.
    root_path: []const u8,
    /// The host tag whose prebuilt toolchain `sysroot_path` points into.
    host_tag: HostTag,
    /// `<root_path>/toolchains/llvm/prebuilt/<host_tag>/sysroot`. Absolute, and
    /// the directory to hand a libc paths file as `include_dir` and `crt_dir`.
    sysroot_path: []const u8,
    /// Which of the two recognised layouts `root_path` was found under.
    shape: Shape,

    /// The two on-disk shapes an NDK is found in.
    pub const Shape = enum {
        /// The NDK sits where it was pointed at. The sysroot is
        /// `<root>/toolchains/llvm/prebuilt/<host-tag>/sysroot`, and that is
        /// what a candidate path is assumed to be before anything is probed.
        /// This is the layout Google's own archive has once unpacked.
        direct,
        /// The NDK sits one level down, under
        /// `<root>/libexec/android-sdk/ndk-bundle`, which is where a packaging
        /// wrapper puts it. The outer directory then holds only `bin/` and
        /// `libexec/`, and no NDK at all. This is the layout nixpkgs'
        /// `androidenv` produces, so it is the layout a Nix user actually has.
        ndk_bundle,
    };

    /// Every path discovery probes under one candidate root, in probe order.
    ///
    /// CONTRACT.md D3 promises that a refusal names every path it tried, and
    /// this is what carries that promise. The shape of the answer follows from
    /// three facts about the problem.
    ///
    /// The `Ndk` that holds those paths is only ever constructed on success, so
    /// the information cannot ride along on it: on the failure path there is no
    /// `Ndk`. It has to be re-derived from `(root, host)` alone, and this is
    /// that derivation.
    ///
    /// It is a value the caller asks for rather than an out-parameter written
    /// through `find` and `open`. An out-parameter was the other candidate and
    /// it loses three ways. It changes two published signatures for a value that
    /// is wanted only on the branch where the call has already failed. It has to
    /// be typed for one root while D3's promise is about the *walk*, which is up
    /// to four roots — so it would need a second concept alongside the layouts
    /// for the roots that were skipped, and that is the half a caller needs most
    /// when an inherited `ANDROID_NDK_HOME` outranked `ANDROID_NDK_ROOT`. And an
    /// out-parameter is written before the call and read after the error, so
    /// nothing at the signature says its value is meaningful on one branch only.
    ///
    /// Every slice is allocated from `gpa`; `deinit` releases them. That makes
    /// this the one value in this file that owns its paths, and the asymmetry
    /// with `Ndk` is deliberate: an `Ndk` is only ever constructed on success
    /// and so can afford to own nothing, whereas this exists only to be freed on
    /// the failure branch.
    pub const Probes = struct {
        /// The host tag the sysroot paths were built for. A refusal that names
        /// paths without naming the tag leaves the reader to guess which
        /// toolchain was looked for, and a wrong host tag is one of the reasons
        /// a probe fails.
        host_tag: HostTag,
        /// The two layouts, direct first. Sized by the probe itself, so a layout
        /// cannot be added to discovery and left out of what this reports.
        entries: [probe_shapes.len]Entry,

        /// One layout's answer for one root: where the NDK would sit, and the
        /// sysroot beneath it that discovery looks for.
        pub const Entry = struct {
            /// Which layout this entry describes.
            shape: Shape,
            /// The directory that would hold `source.properties` and
            /// `toolchains/` under this layout: `root`, or
            /// `root/libexec/android-sdk/ndk-bundle`.
            ndk_root: []const u8,
            /// `<ndk_root>/toolchains/llvm/prebuilt/<host-tag>/sysroot`, the path
            /// whose presence decides this layout.
            sysroot: []const u8,

            /// Frees both borrowed paths.
            pub fn deinit(self: *Entry, gpa: Allocator) void {
                gpa.free(self.sysroot);
                gpa.free(self.ndk_root);
                self.* = undefined;
            }
        };

        /// Frees every entry's paths.
        pub fn deinit(self: *Probes, gpa: Allocator) void {
            for (&self.entries) |*entry| entry.deinit(gpa);
            self.* = undefined;
        }
    };

    /// The paths discovery probes under `root` for `host`, in probe order.
    ///
    /// Built by the same code `open` probes with, so the diagnostic cannot name
    /// a path that was never tried. It answers for a root that is not on disk as
    /// readily as for one that is:
    ///
    /// - a root that is on disk is canonicalised exactly as `open` canonicalises
    ///   it, so the paths reported are the paths probed, down to a symlinked
    ///   parent or a trailing separator;
    /// - a root that is not on disk has no canonical spelling to report, so
    ///   `root` is used as the caller wrote it and the two entries are the paths
    ///   that *would* have been probed. A diagnostic that refused to describe an
    ///   absent root would leave the commonest `-Dndk` mistake undescribed.
    ///
    /// `host` is the tag the paths are built for, not necessarily the one this
    /// machine resolves to. Pass what `open` was given; naming a different tag
    /// here describes a toolchain the caller never asked for, which is the
    /// confusion `error.UnsupportedHost` exists to prevent.
    ///
    /// Every slice in the result comes from `gpa`; free it with
    /// `Probes.deinit`.
    pub fn probeCandidates(
        gpa: Allocator,
        io: Io,
        root: []const u8,
        host: HostTag,
    ) (Allocator.Error || FsError)!Probes {
        // `resolve` trims a candidate the same way before it probes, so this
        // reports the path that was probed rather than the one a shell spelled
        // with a trailing newline on it.
        const root_trimmed = trimCandidate(root);

        // `realPathFileAlloc` returns `[:0]u8` and `free` recovers the block
        // length through `mem.absorbSentinel`, so the value being freed has to
        // keep the sentinel type. The fallback arm is `dupeZ` and not `dupe`
        // for the same reason: with a plain `dupe` the peer type of the two
        // arms is `[]u8` again, the free below asks for one byte fewer than the
        // allocation, and an arena — which is what every caller in this
        // repository passes — turns that mismatch into a silent no-op.
        const canonical: [:0]u8 = Dir.cwd().realPathFileAlloc(io, root_trimmed, gpa) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => try gpa.dupeZ(u8, root_trimmed),
            else => |other| return other,
        };
        defer gpa.free(canonical);
        // Sentinel-typed for the free above, plain for the joins below: nothing
        // here needs the sentinel and `path.join` takes `[]const u8`.
        const root_abs: []const u8 = canonical;

        var probes: Probes = .{ .host_tag = host, .entries = undefined };
        var filled: usize = 0;
        errdefer for (probes.entries[0..filled]) |*entry| entry.deinit(gpa);

        for (probe_shapes, 0..) |shape, i| {
            probes.entries[i] = try probeEntry(gpa, root_abs, host, shape);
            filled += 1;
        }
        return probes;
    }

    /// Writes a refusal naming the host tag and every path `open` probed under
    /// `root` into `writer`.
    ///
    /// This is the caller-facing half of D3's promise. `open` and `find` return
    /// the closed `Error` set and nothing else, so what they probed has to be
    /// asked for separately — and a caller who has to name those paths should
    /// not have to re-spell the two layouts to do it, because a second copy of
    /// that table is a second thing to get wrong. Use it where `NotAnNdk` is
    /// caught from `find` or `open`:
    ///
    /// ```zig
    /// const install = Ndk.open(gpa, io, root, host) catch |err| {
    ///     if (err == error.NotAnNdk) {
    ///         try Ndk.describeProbeFailure(gpa, io, root, host, &log);
    ///     }
    ///     return err;
    /// };
    /// ```
    ///
    /// Not from `readVersion`, which returns the same member for a root that
    /// disappeared between the `open` and the read. No probe was refused
    /// there, so every path in that report is one nobody looked for; resolve
    /// again instead.
    ///
    /// A writer, not a `[]u8` the caller has to free: the caller already owns the
    /// sink it wants the message in — a `std.Build.Step.Fail` body, a log, an
    /// `ArrayList` — and returning a fresh allocation would mean a second
    /// thing to release on a path that is already unwinding, and a copy to reach
    /// the sink anyway. The only error this can add to a caller's set is
    /// `Writer.Error`, which the sink it was handed can already produce.
    ///
    /// Nothing here decides whether a path is an NDK. It touches the filesystem
    /// once, to canonicalise `root` if `root` is there at all, and then only
    /// composes strings, so it cannot itself become the failure the caller is
    /// reporting.
    ///
    /// The value is rendered escaped, and it is escaped because a candidate can
    /// come from an environment variable: `export ANDROID_NDK_HOME=$(cat
    /// ndk.path)` leaves a newline on the end of it, a CI YAML block scalar
    /// leaves one, a `for` loop over a file leaves one, and POSIX allows one in
    /// the middle of a directory name. Raw into this message that newline lands
    /// mid-path and every line after it reads as part of the value, so a report
    /// whose own content can move its own boundaries can lie about its
    /// structure.
    pub fn describeProbeFailure(
        gpa: Allocator,
        io: Io,
        root: []const u8,
        host: HostTag,
        writer: *Writer,
    ) (Allocator.Error || FsError || Writer.Error)!void {
        var probes = try probeCandidates(gpa, io, root, host);
        defer probes.deinit(gpa);

        try writer.writeAll("no Android NDK sysroot under '");
        try writeEscaped(writer, root);
        try writer.print(
            \\' for host tag '{s}'.
            \\
            \\discovery probes these paths, in this order, and takes the first one
            \\that is a directory:
            \\
        , .{probes.host_tag.directoryName()});

        for (probes.entries, 0..) |entry, i| {
            try writer.print("  {d}. {s}: ", .{ i + 1, @tagName(entry.shape) });
            try writeEscaped(writer, entry.sysroot);
            try writer.writeAll("\n");
        }

        try writer.writeAll(
            \\
            \\none of them is. Point the NDK at an unpacked installation: the directory
            \\holding source.properties and toolchains/. A zip file, an Android SDK root,
            \\and an NDK unpacked for another host tag all fail exactly this way.
            \\
        );
    }

    /// Writes a refusal naming every source `Ndk.find` walks, and the value it
    /// read from each, into `writer`.
    ///
    /// The other half of D3's promise, and the commoner of the two refusals:
    /// `describeProbeFailure` describes a root that was reached and turned out
    /// to hold no sysroot, while this describes the walk that reached nothing —
    /// the state before any `-Dndk` value exists, which is where a fresh
    /// checkout and a CI runner both start. Use it where `NdkNotFound` is
    /// caught:
    ///
    /// ```zig
    /// const install = Ndk.find(gpa, io, explicit, &environ) catch |err| {
    ///     if (err == error.NdkNotFound) {
    ///         try Ndk.describeDiscoveryFailure(explicit, &environ, &log);
    ///     }
    ///     return err;
    /// };
    /// ```
    ///
    /// `environ` is the map `find` was handed, not the process environment read
    /// a second time here: these are the walk's values, so a variable the runner
    /// dropped between building the map and walking it is reported as this walk
    /// saw it rather than as the shell spells it now.
    ///
    /// The four sources are the table `find` walks, so a refusal cannot name a
    /// source the walk did not read or read one it did not name. A writer, not
    /// a `[]u8` the caller has to free, for the reason `describeProbeFailure`
    /// gives: the caller owns the sink it wants the message in, and the only
    /// error this can add is `Writer.Error`.
    ///
    /// It allocates nothing and takes no allocator, so it owns nothing and has
    /// no `deinit` — the same asymmetry as `Ndk`, for the same reason. Naming
    /// four strings the caller already holds needs no paths built and no
    /// filesystem walk, where `Ndk.Probes` exists precisely because probing a
    /// root does.
    ///
    /// A build script cannot reach this, and that is a fact about `std.Build`
    /// rather than about this package: a build script has no way to `@import`
    /// the module it publishes, so a gate that refuses at configure time spells
    /// these sources out itself. This is for the consumer that runs its own
    /// discovery in Zig.
    ///
    /// Nothing here decides whether a source is an NDK, and nothing here claims
    /// to: each is reported as the value `find` read from it, with `(unset)` or
    /// `(empty)` where it has none. The one thing this checks is the host tag,
    /// which is a switch over the compilation target and costs no filesystem
    /// access — and which decides whether the four could have satisfied the
    /// walk at all, since `find` refuses `UnsupportedHost` before it reads a
    /// source. A report that listed four paths on such a build would be listing
    /// paths nothing could have used.
    pub fn describeDiscoveryFailure(
        explicit: ?[]const u8,
        environ: *const Environ.Map,
        writer: *Writer,
    ) Writer.Error!void {
        try writer.writeAll(
            \\
            \\no Android NDK was found, so nothing here has a sysroot to point at.
            \\
            \\`Ndk.find` walks these sources in this order and takes the first one
            \\holding an unpacked installation. A variable naming nothing on disk is
            \\walked past rather than refused, which is what lets a stale
            \\ANDROID_NDK_HOME hand the turn to the next source instead of failing the
            \\walk. The `-Dndk` option is the one exception: it is a pin, so an
            \\explicit path that is not there stops the walk here rather than being
            \\answered by whatever the next variable exports. Each of them read:
            \\
        );

        for (discovery_sources, 0..) |source, i| {
            // The `-Dndk` option is the caller's and not the environment's, so
            // the table names it rather than reading it from the map.
            const value = if (source.env_var) |name| environ.get(name) else explicit;
            try writer.print("  {d}. {s: <32} '", .{ i + 1, source.label });
            try writeEscaped(writer, sourceOrUnset(value));
            try writer.writeAll("'\n");
        }

        // `find` resolves the tag from the compilation target before it reads a
        // single source, so on a host Google publishes no package for, none of
        // the four above could have satisfied it. `hostTag` consults no
        // directory, so this is a fact about the build and not a guess about
        // the machine.
        const host = hostTag(builtin.target) catch |err| switch (err) {
            error.UnsupportedHost => {
                try writer.writeAll(
                    \\
                    \\None of them can satisfy this build. Google publishes an NDK host
                    \\tag for linux-x86_64, darwin-x86_64 and windows-x86_64 and for no
                    \\others, so `Ndk.find` refuses `UnsupportedHost` here, meaning this
                    \\build host has no NDK toolchain, before it reads a source at all.
                    \\Build on one of those three hosts, or cross the NDK toolchain by
                    \\hand; no value above changes that.
                    \\
                );
                return;
            },
            // `hostTag` takes a target and consults no directory, so the
            // NDK-domain refusals in its closed set cannot happen here. The arm
            // says so rather than letting a bare `catch` drop them in silence.
            else => unreachable,
        };

        try writer.print(
            \\
            \\Point one of them at an unpacked installation, the directory holding
            \\`source.properties` and `toolchains/`, unpacked for host tag '{s}'.
            \\
        , .{host.directoryName()});
    }

    /// Resolves an NDK by probing, in order: the explicit build option, then
    /// `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, `ANDROID_NDK`.
    ///
    /// `explicit` is the caller's `-Dndk` build option; pass `null` when it was
    /// not set. `environ` is the build runner's environment map.
    ///
    /// The explicit option is a PIN, not the first of four preferences. If it
    /// names a path that is not on disk this returns `error.NdkNotFound`
    /// instead of walking past it, because an option that can be answered by
    /// whatever `ANDROID_NDK_HOME` a runner image happened to export is an
    /// option nobody is told was ignored. CONTRACT.md D3 promises "explicit
    /// beats implicit, always", and a fall-through made that promise false in
    /// exactly the case it is about: a dangling symlink, a path typed from
    /// memory, an NDK that was never fetched.
    ///
    /// Among the variables, first hit wins and the rest are never read, so an
    /// inherited `ANDROID_NDK_HOME` does outrank `ANDROID_NDK_ROOT` and
    /// `ANDROID_NDK`. `shape` on the result tells a caller which layout
    /// answered, which is what to name when the inherited variable picked the
    /// wrong NDK. An unset variable, or one holding nothing but whitespace, is
    /// skipped without complaint.
    ///
    /// Surrounding whitespace is trimmed off every candidate before it is
    /// probed, because a path with a newline on the end of it is a path that is
    /// not there, and the shell accidents that produce one are ordinary:
    /// `export ANDROID_NDK_HOME=$(cat ndk.path)`, a CI YAML block scalar, a
    /// `for` loop over a file. The interior is left alone — POSIX lets a
    /// directory name hold a newline, so trimming one out of the middle would
    /// point the probe at a directory nobody named.
    ///
    /// Returns `error.NdkNotFound` when no source named an NDK,
    /// `error.NotAnNdk` when one exists but holds no sysroot, and
    /// `error.UnsupportedHost` before any candidate is read when this machine
    /// has no NDK host tag.
    ///
    /// The four sources in the documented order are the caller's to name,
    /// because they come from a `-D` option and an environment map that are
    /// both the caller's — and `describeDiscoveryFailure` names them from the
    /// same table this walk reads, so nothing has to be re-spelled here.
    /// `probeCandidates` names what was probed under any one of them, so a
    /// refusal can carry both halves of D3's list: the sources walked, in
    /// order, and the paths each was walked for.
    ///
    /// The host tag comes from the compilation target, `builtin.target`, which
    /// is the machine `zig build` runs on. Every slice the result stores comes
    /// from `gpa`; see the ownership note on `Ndk`.
    pub fn find(
        gpa: Allocator,
        io: Io,
        explicit: ?[]const u8,
        environ: *const Environ.Map,
    ) (Error || Allocator.Error || FsError)!Ndk {
        const host = try hostTag(builtin.target);

        // One table of sources, walked here and rendered by
        // `describeDiscoveryFailure`. A second spelling of these four is a
        // second thing to get wrong, and it fails silently: a variable added to
        // discovery and left out of what a refusal names leaves the reader
        // hunting for a source the walk never read.
        for (discovery_sources) |source| {
            // The `-Dndk` option is the caller's and not the environment's, so
            // the table names it rather than reading it from the map.
            const value = if (source.env_var) |name| environ.get(name) else explicit;
            // Trimmed here as well as in `resolve`, because the walk has to
            // know a variable holding nothing but whitespace is not a candidate
            // before it decides whether a missing path was a pin.
            const candidate = trimCandidate(value orelse continue);
            if (candidate.len == 0) continue;

            if (resolve(gpa, io, candidate, host)) |resolved| {
                return resolved;
            } else |err| switch (err) {
                error.FileNotFound => {
                    // An explicit path that is not on disk is the whole answer,
                    // not a candidate to skip. Walking past it is what let
                    // `-Dndk` be answered by whatever a runner image exported,
                    // with nothing said about it.
                    if (source.env_var == null) return error.NdkNotFound;
                    // A variable that is not there hands the turn to the next
                    // source.
                },
                // Anything else is a decision the caller needs to see.
                else => |other| return other,
            }
        }
        return error.NdkNotFound;
    }

    /// Opens an NDK whose root the caller already knows.
    ///
    /// `root` may be relative or absolute and is canonicalised before use, so
    /// `sysroot()` is absolute whatever the caller passed. Both recognised
    /// layouts are probed under it, direct first; `shape` reports which one
    /// matched.
    ///
    /// Returns `error.NotAnNdk` when the root is missing, is a regular file, or
    /// holds no sysroot directory under either layout — so pointing at an
    /// archive, at a zip, or at an SDK root fails here rather than at link time,
    /// and never hands back a raw filesystem error for a case the caller can act
    /// on. `probeCandidates` and `describeProbeFailure` name the paths that were
    /// probed, for any of those three.
    ///
    /// Every slice the result stores comes from `gpa`; see the ownership note
    /// on `Ndk`.
    pub fn open(
        gpa: Allocator,
        io: Io,
        root: []const u8,
        host: HostTag,
    ) (Error || Allocator.Error || FsError)!Ndk {
        return resolve(gpa, io, root, host) catch |err| switch (err) {
            // `NotDir` is the shape a regular file takes when something walks
            // under it, and pointing at an unzipped archive is exactly that
            // mistake. `isDirectoryPath` absorbs it at the probe, so this arm
            // guards the mapping rather than being reached today: if a later
            // step under `root` walks a component, discovery still answers in
            // its own vocabulary instead of handing back a syscall code the
            // caller cannot act on.
            error.FileNotFound, error.NotDir, error.NotAnNdk => error.NotAnNdk,
            else => |other| return other,
        };
    }

    /// The absolute sysroot directory for the resolved host tag.
    ///
    /// `<root_path>/toolchains/llvm/prebuilt/<host_tag.directoryName()>/sysroot`,
    /// holding both `usr/include` and `usr/lib/<triple>/<api-level>`. This is
    /// the one path a consumer needs to build a libc paths file from.
    ///
    /// Borrowed from the allocator passed to `find` or `open`; see the ownership
    /// note on `Ndk`.
    pub fn sysroot(self: Ndk) []const u8 {
        return self.sysroot_path;
    }

    /// The NDK host tag that ships a prebuilt toolchain for `target`.
    ///
    /// `target` is the host the build runs on, normally `b.graph.host`. Google
    /// publishes exactly three NDK packages and all three are x86_64, so this
    /// resolves for an x86_64 Linux, macOS or Windows host and for nothing
    /// else. `aarch64-macos` is served by the `darwin_x86_64` package, which
    /// runs under Rosetta; `aarch64-linux` is not served at all.
    ///
    /// Returns `error.UnsupportedHost` for every other host. That error means
    /// Google publishes no NDK for the machine the build is running on. It does
    /// not mean a path was mistyped, and no `-Dndk` value can fix it: the
    /// caller has to build on one of the three published hosts, or cross the
    /// NDK toolchain by hand. Reporting `error.NotAnNdk` here instead would
    /// blame the user for a path they configured correctly.
    pub fn hostTag(target: Target) Error!HostTag {
        return switch (target.os.tag) {
            // Only x86_64 has a package. A native Apple Silicon build still
            // uses the darwin-x86_64 package, so that is the tag for both.
            .linux => if (target.cpu.arch == .x86_64)
                .linux_x86_64
            else
                error.UnsupportedHost,
            .macos => if (target.cpu.arch == .x86_64 or target.cpu.arch == .aarch64)
                .darwin_x86_64
            else
                error.UnsupportedHost,
            .windows => if (target.cpu.arch == .x86_64)
                .windows_x86_64
            else
                error.UnsupportedHost,
            else => error.UnsupportedHost,
        };
    }

    /// The sysroot triple for `abi`, the directory name under `usr/lib`.
    ///
    /// Borrowed from a string literal; see `Abi.triple`.
    pub fn tripleFor(abi: Abi) []const u8 {
        return abi.triple();
    }

    /// The API-level directory holding this ABI's CRT objects and its libc and
    /// libm shared objects.
    ///
    /// `<sysroot>/usr/lib/<abi.triple()>/<api_level>`, absolute. In r29 this
    /// directory holds the six CRT objects — `crtbegin_dynamic.o`,
    /// `crtbegin_so.o`, `crtbegin_static.o`, `crtend_android.o`,
    /// `crtend_so.o` and `crt_pad_segment.o` — beside `libc.so`, `libm.so` and
    /// the `libc++.so` / `libc++.a` linker scripts, so it is the value a libc
    /// paths file wants as `crt_dir`. It is never the API-agnostic
    /// `usr/lib/<triple>`, and it never holds `libc.a` or `libc++_shared.so`.
    ///
    /// That placement is the load-bearing consequence, and it is why a
    /// consumer must set `.linkage = .dynamic`: `libc.a` and
    /// `libc++_shared.so` are API-agnostic and sit one level up, as siblings of
    /// the numeric directories in `usr/lib/<triple>`. A libc paths file carries
    /// no other search path, so neither archive is reachable from the `crt_dir`
    /// this returns. A static libc link and a libc++ link are therefore not
    /// reachable from `crt_dir` alone, and a consumer wanting one has to name
    /// the archive itself.
    ///
    /// Returns `error.UnsupportedAbi` when the NDK has no `usr/lib/<triple>` at
    /// all, and `error.ApiLevelUnavailable` when it has the triple but not that
    /// level. `apiLevelsFor` answers both questions without failing.
    ///
    /// The returned slice is owned by `gpa`; free it with the same allocator.
    pub fn libcDirFor(
        self: Ndk,
        gpa: Allocator,
        io: Io,
        abi: Abi,
        api_level: u32,
    ) (Error || Allocator.Error || FsError)![]u8 {
        const triple_dir = try self.tripleDir(gpa, io, abi);
        defer gpa.free(triple_dir);

        // A u32 needs at most ten digits, so this buffer cannot overflow.
        // printInt cannot fail; bufPrint would widen the error set of this
        // function with an error that cannot happen.
        var api_buf: [10]u8 = undefined;
        const api_end = std.fmt.printInt(&api_buf, api_level, 10, .lower, .{});
        const api_text = api_buf[0..api_end];

        const level_dir = try path.join(gpa, &.{ triple_dir, api_text });
        errdefer gpa.free(level_dir);

        // A plain file named like an API level is not an API level, and handing
        // one to a libc paths file as `crt_dir` fails at link time with a
        // message about libc that points nowhere near the file.
        if (!try isDirectoryPath(io, level_dir)) return error.ApiLevelUnavailable;

        return level_dir;
    }

    /// Every API level this NDK ships a CRT-object directory for.
    ///
    /// Reads the numeric directory names directly under
    /// `<sysroot>/usr/lib/<abi.triple()>` and returns them sorted ascending.
    /// Entries whose name does not parse as an unsigned decimal are skipped, so
    /// a future NDK that adds a directory beside the API levels cannot break
    /// this.
    ///
    /// Returns `error.UnsupportedAbi` when the NDK has no `usr/lib/<triple>` at
    /// all.
    ///
    /// The returned slice is owned by `gpa`; free it with the same allocator.
    pub fn apiLevelsFor(
        self: Ndk,
        gpa: Allocator,
        io: Io,
        abi: Abi,
    ) (Error || Allocator.Error || FsError)![]u32 {
        const triple_dir = try self.tripleDir(gpa, io, abi);
        defer gpa.free(triple_dir);

        var dir = Dir.openDirAbsolute(io, triple_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.UnsupportedAbi,
            else => |other| return other,
        };
        defer dir.close(io);

        var levels: std.ArrayList(u32) = .empty;
        errdefer levels.deinit(gpa);

        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            // The same predicate `libcDirFor` uses, so a name the iterator calls
            // a directory and a stat calls one cannot disagree.
            if (!isDirectory(entry.kind)) continue;
            const level = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
            try levels.append(gpa, level);
        }

        std.mem.sort(u32, levels.items, {}, std.sort.asc(u32));
        return levels.toOwnedSlice(gpa);
    }

    /// Reads the `Pkg.Revision` code from `source.properties` at the NDK root.
    ///
    /// `null` when the file is absent, which is legal: a repackaged NDK need
    /// not carry one, and an unknown version never blocks a build.
    /// `error.VersionUnreadable` when it is present but holds no parsable
    /// `Pkg.Revision` line.
    ///
    /// `error.NotAnNdk` is the one member of the set that arrives without a
    /// judgement about the layout, and it is reached only when the root is
    /// gone: this opens `root_path`, which `find` or `open` resolved and which
    /// held a sysroot a moment earlier, and between those two calls the root
    /// stopped being a directory — moved, removed, or replaced by a file.
    /// `describeProbeFailure` is misleading rather than helpful here, naming
    /// two sysroot paths for an installation that had already resolved;
    /// resolve again instead. Every other failure is a filesystem error,
    /// unchanged.
    ///
    /// This is the dotted code, `29.0.14206865`, which is what a build pins
    /// against. The sibling `Pkg.ReleaseName`, `r29`, is the string a human
    /// reads; this does not return it.
    pub fn readVersion(
        self: Ndk,
        gpa: Allocator,
        io: Io,
    ) (Error || Allocator.Error || FsError)!?Version {
        var dir = Dir.openDirAbsolute(io, self.root_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.NotAnNdk,
            else => |other| return other,
        };
        defer dir.close(io);

        const properties = dir.readFileAlloc(
            io,
            "source.properties",
            gpa,
            .limited(max_properties_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |other| return other,
        };
        defer gpa.free(properties);

        return try Version.parse(properties);
    }

    /// The dotted version code from `Pkg.Revision`, `29.0.14206865` for r29.
    ///
    /// r29 writes both `Pkg.Revision = 29.0.14206865` and an identical
    /// `Pkg.BaseRevision`; only the first is read. A value type: it owns no
    /// memory and has no `deinit`.
    pub const Version = struct {
        /// The release number. `29` for r29.
        major: u32,
        /// The second component. `0` for r29.
        minor: u32,
        /// The build number. `14206865` for r29.
        patch: u32,

        /// Parses the `Pkg.Revision` value out of a `source.properties` body.
        ///
        /// Scans whole lines, skipping blanks, `#` comments and every other
        /// key, and returns the first `Pkg.Revision` whose value is three
        /// dot-separated non-negative integers. Whitespace around the key, the
        /// `=` and the value is ignored. No such key, two components, a
        /// trailing qualifier or anything unparsable is
        /// `error.VersionUnreadable`, never a guess.
        pub fn parse(properties: []const u8) Error!Version {
            var lines = std.mem.tokenizeScalar(u8, properties, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..separator], " \t");
                if (!std.mem.eql(u8, key, "Pkg.Revision")) continue;

                return parseRevision(std.mem.trim(u8, trimmed[separator + 1 ..], " \t"));
            }
            return error.VersionUnreadable;
        }
    };

    /// `<sysroot>/usr/lib/<abi.triple()>`, checked to be a directory. Gpa-owned.
    ///
    /// `error.UnsupportedAbi` when it is not there or is not a directory, which
    /// is how an ABI this NDK does not carry is told apart from an API level it
    /// does not.
    fn tripleDir(
        self: Ndk,
        gpa: Allocator,
        io: Io,
        abi: Abi,
    ) (Error || Allocator.Error || FsError)![]u8 {
        const triple_dir = try path.join(gpa, &.{
            self.sysroot_path, "usr", "lib", abi.triple(),
        });
        errdefer gpa.free(triple_dir);

        if (!try isDirectoryPath(io, triple_dir)) return error.UnsupportedAbi;

        return triple_dir;
    }
};

/// The one definition of "this is a directory" this module uses.
///
/// Two questions get the same answer — the `stat` a probe does, and the `kind`
/// a directory iterator hands back — and `File.Kind` is the type both carry, so
/// there is one place to be wrong. That matters because the two were once
/// spelled separately: `apiLevelsFor` filtered iterator entries on
/// `entry.kind == .directory` while `libcDirFor` asked only whether a path
/// existed. A plain file named `99` under `usr/lib/<triple>/` was then correctly
/// left out of `apiLevelsFor` and happily accepted as a `crt_dir`, and the build
/// failed later, at link time, with a message about libc that pointed nowhere
/// near the file that caused it.
fn isDirectory(kind: File.Kind) bool {
    return kind == .directory;
}

/// Whether `dir_path` is a directory.
///
/// "Not there" and "there but not a directory" are both `false`, because for
/// every caller here — a sysroot, a `usr/lib/<triple>`, an API-level directory —
/// a path that is not a directory is the wrong shape rather than a broken
/// machine, and "not a directory" is exactly what pointing at a zip, at an SDK
/// root, or at a wrapper's outer directory looks like on disk.
///
/// Every other filesystem error is returned unchanged, and that is the point of
/// the second half of the switch: a caller here maps `false` onto a domain
/// answer that depends on what it was looking for (the wrong `Shape`,
/// `UnsupportedAbi`, `ApiLevelUnavailable`), so reading a permission failure or
/// an I/O error as "absent" would turn a broken filesystem into a confident
/// wrong answer about the NDK.
fn isDirectoryPath(io: Io, dir_path: []const u8) FsError!bool {
    const stat = Dir.cwd().statFile(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |other| return other,
    };
    return isDirectory(stat.kind);
}

/// The layouts discovery recognises under one candidate root, in probe order.
///
/// Direct first, because that is what an explicitly named root means and
/// because a packaging wrapper is the rarer case. `Ndk.Probes` sizes its entry
/// array by this length, so a layout cannot be added to the probe and left out
/// of what a refusal reports.
const probe_shapes = [_]Ndk.Shape{ .direct, .ndk_bundle };

/// The sources `Ndk.find` walks, in walk order.
///
/// `env_var` is null for the `-Dndk` build option, which is the caller's and
/// not the environment's. `label` is how a refusal names a source, because the
/// option is not spelled like an environment variable and a report that printed
/// four bare names would leave the reader to work out which of them is the one
/// they typed.
const discovery_sources = [_]struct { label: []const u8, env_var: ?[]const u8 }{
    .{ .label = "the -Dndk build option", .env_var = null },
    .{ .label = "the ANDROID_NDK_HOME environment", .env_var = "ANDROID_NDK_HOME" },
    .{ .label = "the ANDROID_NDK_ROOT environment", .env_var = "ANDROID_NDK_ROOT" },
    .{ .label = "the ANDROID_NDK environment", .env_var = "ANDROID_NDK" },
};

/// A candidate as discovery reads it: surrounding whitespace removed, the
/// interior untouched.
///
/// A path with a newline on the end of it is a path that is not there, and the
/// shell accidents that produce one are ordinary rather than exotic: `export
/// ANDROID_NDK_HOME=$(cat ndk.path)`, a CI YAML block scalar, a `for` loop over
/// a file, a Windows `.bat`. The interior is left alone because POSIX lets a
/// directory name hold a newline, so trimming one out of the middle would point
/// the probe at a directory nobody named — and what is left is escaped in the
/// refusal, so a real one still reads as one line.
///
/// Borrowed from the input, so the caller frees nothing.
fn trimCandidate(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

/// One discovery source's value, the way a refusal reads it.
///
/// `(unset)` for a source that carries nothing, `(empty)` for one that carries
/// whitespace only, and the trimmed value itself otherwise — trimmed, because a
/// report that printed a padded path would name a path discovery never probed.
/// The two markers are kept apart because they are different facts: `(unset)`
/// says no shell exported anything under that name, `(empty)` says one did and
/// exported nothing under it, and the second is a shell bug worth naming rather
/// than a variable that is missing.
///
/// Borrowed from the input or from a literal; the caller frees nothing.
fn sourceOrUnset(value: ?[]const u8) []const u8 {
    const trimmed = trimCandidate(value orelse return "(unset)");
    if (trimmed.len == 0) return "(empty)";
    return trimmed;
}

/// Writes `text` with the bytes that could move a report off its own line
/// escaped, so a value that arrived from an environment cannot reformat the
/// message quoting it.
///
/// A newline is the case that matters. Rendered raw it lands mid-path in the
/// middle of the message and every line after it reads as part of the value, so
/// a report whose own content can move its own boundaries can lie about its
/// structure. Bytes above ASCII are written as the filesystem spelled them:
/// this decodes nothing, and a report that dropped what it could not name would
/// be reporting a value nobody set.
fn writeEscaped(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| {
        switch (c) {
            // The byte that quotes a value and the byte that continues a quoted
            // one. Both stay readable; the backslash in front says which.
            '\\', '\'' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            // Every C0 control and DEL. None of them belongs in a path a reader
            // wants, and every one of them can end a line or move the cursor.
            0x00...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{c}),
            else => try writer.writeByte(c),
        }
    }
}

/// The NDK root and the sysroot one layout implies under an absolute `root`.
/// Gpa-owned; free both slices through `Probes.Entry.deinit`.
///
/// The one place the two layouts are spelled out as paths. `resolve` probes what
/// this builds and `Ndk.probeCandidates` reports it, so the paths a refusal
/// names are the paths the refusal came from — a diagnostic cannot drift away
/// from the discovery it describes, which is where a message written out twice
/// eventually ends up pointing somewhere the code never looked.
fn probeEntry(
    gpa: Allocator,
    root_abs: []const u8,
    host: HostTag,
    shape: Ndk.Shape,
) Allocator.Error!Ndk.Probes.Entry {
    const ndk_root = switch (shape) {
        .direct => try gpa.dupe(u8, root_abs),
        .ndk_bundle => try path.join(gpa, &.{
            root_abs, "libexec", "android-sdk", "ndk-bundle",
        }),
    };
    errdefer gpa.free(ndk_root);

    const sysroot = try path.join(gpa, &.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        host.directoryName(),
        "sysroot",
    });
    errdefer gpa.free(sysroot);

    return .{ .shape = shape, .ndk_root = ndk_root, .sysroot = sysroot };
}

/// Resolves one candidate root under both recognised layouts.
///
/// Private, so that `Ndk.find` can tell "this candidate is not on disk, try the
/// next one" apart from "this candidate exists and is not an NDK", which is the
/// distinction `error.FileNotFound` and `error.NotAnNdk` carry. That is also why
/// the canonicalisation here is not the one in `Ndk.probeCandidates`: in the
/// walk an absent root must stay distinguishable from a root that is present and
/// wrong, because there is a next candidate to fall through to.
fn resolve(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    host: HostTag,
) (Error || Allocator.Error || FsError)!Ndk {
    // Trimmed here as well as in `Ndk.probeCandidates`, because those two have
    // to canonicalise the same string: one probes it and the other reports it,
    // and a report naming a path the probe never looked at is the one thing
    // both exist to prevent.
    const root_trimmed = trimCandidate(root);

    const canonical = Dir.cwd().realPathFileAlloc(io, root_trimmed, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.NotDir => return error.NotAnNdk,
        else => |other| return other,
    };
    defer gpa.free(canonical);
    // The sentinel stays on `canonical` because that is the value being freed:
    // `free` recovers the block length through `mem.absorbSentinel`, so a
    // `[]u8` alias of a `[:0]u8` asks for one byte fewer than `dupeZ` allocated.
    // `Ndk.probeCandidates` holds the same rule for the same reason. The peel
    // below is only for the joins, which take a plain slice.
    const root_abs: []const u8 = canonical;

    for (probe_shapes) |shape| {
        var entry = try probeEntry(gpa, root_abs, host, shape);
        // On the matching shape the entry's two slices become the result, so
        // this frees them on every iteration that moves on to the next shape,
        // and on every error return out of the body.
        var claimed = false;
        defer if (!claimed) entry.deinit(gpa);

        // A sysroot that is not there — or is there and is not a directory —
        // means this shape is the wrong one, so the answer is "not this shape",
        // not "stop". Only a real filesystem failure is worth passing on.
        if (!try isDirectoryPath(io, entry.sysroot)) continue;
        claimed = true;

        return .{
            .root_path = entry.ndk_root,
            .host_tag = host,
            .sysroot_path = entry.sysroot,
            .shape = entry.shape,
        };
    }

    return error.NotAnNdk;
}

/// Parses `29.0.14206865` into three components, or refuses.
fn parseRevision(text: []const u8) Error!Ndk.Version {
    var components: [3]u32 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&components) |*component| {
        const digits = parts.next() orelse return error.VersionUnreadable;
        component.* = std.fmt.parseUnsigned(u32, digits, 10) catch
            return error.VersionUnreadable;
    }
    if (parts.next() != null) return error.VersionUnreadable;

    return .{
        .major = components[0],
        .minor = components[1],
        .patch = components[2],
    };
}

const testing = std.testing;

/// Resolves an `arch-os` triple string into a real `std.Target`.
///
/// `std.Target` cannot be written as a literal without all four of `cpu`, `os`,
/// `abi` and `ofmt`, and `cpu.model` is a `*const Model` that has to outlive
/// the target it belongs to, so a hand-built literal is a trap. Zig's own
/// resolver produces a target with every field real. `hostTag` reads only the
/// OS tag and the CPU arch; the rest is here so the value is not a fiction.
/// Test helper.
fn targetFor(arch_os: []const u8) !std.Target {
    return std.zig.system.resolveTargetQuery(
        testing.io,
        try std.Target.Query.parse(.{ .arch_os_abi = arch_os }),
    );
}

/// The absolute path of a scratch directory. `gpa`-owned. Test helper.
fn absPathOf(gpa: Allocator, scratch: *testing.TmpDir) ![]u8 {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const len = try scratch.dir.realPath(testing.io, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

/// Joins `parts` and creates the result plus every missing parent. `gpa`-owned.
///
/// Test helper.
fn createAll(gpa: Allocator, parts: []const []const u8) ![]u8 {
    const dir = try path.join(gpa, parts);
    errdefer gpa.free(dir);
    try Dir.cwd().createDirPath(testing.io, dir);
    return dir;
}

/// Builds a synthetic NDK holding one triple with one directory per level.
///
/// Enough of a tree for `open`, `libcDirFor`, `apiLevelsFor` and `readVersion`
/// to be exercised with no NDK anywhere on the machine. Returns the root path,
/// `gpa`-owned. Test helper.
fn createNdk(
    gpa: Allocator,
    scratch: *testing.TmpDir,
    host: HostTag,
    triple_name: []const u8,
    levels: []const []const u8,
) ![]u8 {
    const root = try absPathOf(gpa, scratch);
    errdefer gpa.free(root);

    const lib_dir = try createAll(gpa, &.{
        root,
        "toolchains",
        "llvm",
        "prebuilt",
        host.directoryName(),
        "sysroot",
        "usr",
        "lib",
        triple_name,
    });
    defer gpa.free(lib_dir);

    for (levels) |level| {
        const dir = try createAll(gpa, &.{ lib_dir, level });
        defer gpa.free(dir);
    }
    return root;
}

test "ABI names round-trip to the meta/abis.json keys" {
    // Straight from r29's meta/abis.json keys. A tag is not an ABI name; only
    // this mapping reaches the NDK's own spelling.
    try testing.expectEqualStrings("armeabi-v7a", Abi.armeabi_v7a.name());
    try testing.expectEqualStrings("arm64-v8a", Abi.arm64_v8a.name());
    try testing.expectEqualStrings("riscv64", Abi.riscv64.name());
    try testing.expectEqualStrings("x86", Abi.x86.name());
    try testing.expectEqualStrings("x86_64", Abi.x86_64.name());

    // The enum is exactly the five r29 ABIs, and every name is distinct, so no
    // two ABIs can be named for one another.
    const abis = std.enums.values(Abi);
    try testing.expectEqual(@as(usize, 5), abis.len);
    for (abis, 0..) |a, i| {
        for (abis, 0..) |b, j| {
            if (j <= i) continue;
            try testing.expect(!std.mem.eql(u8, a.name(), b.name()));
            try testing.expect(!std.mem.eql(u8, a.triple(), b.triple()));
        }
    }

    // The mapping is not the identity: a tag is never the NDK's spelling of its
    // ABI, which is why @tagName must never be used to name one. Only the three
    // ABIs whose name carries no dash can coincide with their tag.
    for (abis) |abi| {
        if (!std.mem.eql(u8, abi.name(), @tagName(abi))) continue;
        try testing.expect(std.mem.indexOfScalar(u8, @tagName(abi), '-') == null);
    }
}

test "every triple matches r29's meta/abis.json" {
    try testing.expectEqualStrings("arm-linux-androideabi", Abi.armeabi_v7a.triple());
    try testing.expectEqualStrings("aarch64-linux-android", Abi.arm64_v8a.triple());
    try testing.expectEqualStrings("riscv64-linux-android", Abi.riscv64.triple());
    try testing.expectEqualStrings("i686-linux-android", Abi.x86.triple());
    try testing.expectEqualStrings("x86_64-linux-android", Abi.x86_64.triple());
}

test "every minimum API level matches r29's min_os_version" {
    try testing.expectEqual(@as(u32, 21), Abi.armeabi_v7a.minApiLevel());
    try testing.expectEqual(@as(u32, 21), Abi.arm64_v8a.minApiLevel());
    try testing.expectEqual(@as(u32, 35), Abi.riscv64.minApiLevel());
    try testing.expectEqual(@as(u32, 21), Abi.x86.minApiLevel());
    try testing.expectEqual(@as(u32, 21), Abi.x86_64.minApiLevel());
}

test "only 32-bit ARM is androideabi" {
    try testing.expectEqual(Target.Abi.androideabi, Abi.armeabi_v7a.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.arm64_v8a.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.riscv64.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.x86.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.x86_64.zigAbi());

    // Every ABI maps to an ABI Zig itself calls Android, or the dynamic linker
    // it picks would not be a bionic one.
    for (std.enums.values(Abi)) |abi| {
        try testing.expect(abi.zigAbi().isAndroid());
    }
}

test "host tags resolve for the three hosts Google publishes an NDK for" {
    // Google's manifest offers android-ndk-r29-{linux,darwin,windows}.zip and
    // no arm package, so these three triples are the whole supported set.
    const cases = [_]struct { arch_os: []const u8, want: HostTag }{
        .{ .arch_os = "x86_64-linux", .want = .linux_x86_64 },
        .{ .arch_os = "x86_64-macos", .want = .darwin_x86_64 },
        .{ .arch_os = "x86_64-windows", .want = .windows_x86_64 },
    };
    try testing.expectEqual(cases.len, std.enums.values(HostTag).len);

    for (cases) |case| {
        const target = try targetFor(case.arch_os);
        try testing.expectEqual(case.want, try Ndk.hostTag(target));

        // Every resolved host tag reaches its on-disk spelling.
        try testing.expectEqualStrings(
            case.want.directoryName(),
            (try Ndk.hostTag(target)).directoryName(),
        );
    }

    // Apple Silicon runs the darwin-x86_64 package under Rosetta, so an arm
    // macOS host resolves rather than failing.
    try testing.expectEqual(
        HostTag.darwin_x86_64,
        try Ndk.hostTag(try targetFor("aarch64-macos")),
    );
}

test "hosts Google publishes no NDK for are refused, not misreported" {
    // Most of these matter because a host with a plausible tag would otherwise
    // get that tag and then fail as NotAnNdk, blaming a path that is correct.
    const refused = [_][]const u8{
        "aarch64-linux",
        "riscv64-linux",
        "x86-linux",
        "x86-windows",
        "aarch64-windows",
        "riscv64-windows",
        "x86_64-freebsd",
        "aarch64-freebsd",
    };
    for (refused) |arch_os| {
        try testing.expectError(
            error.UnsupportedHost,
            Ndk.hostTag(try targetFor(arch_os)),
        );
    }
}

test "the host tag names a prebuilt directory, not the ABI triple" {
    try testing.expectEqualStrings("linux-x86_64", HostTag.linux_x86_64.directoryName());
    try testing.expectEqualStrings("darwin-x86_64", HostTag.darwin_x86_64.directoryName());
    try testing.expectEqualStrings("windows-x86_64", HostTag.windows_x86_64.directoryName());

    const hosts = std.enums.values(HostTag);

    // Every published host tag is an x86_64 tag. A `linux-aarch64` or
    // `darwin-arm64` entry would be a tag no Google package contains.
    for (hosts) |host| {
        try testing.expect(std.mem.endsWith(u8, @tagName(host), "_x86_64"));
    }

    // No host tag collides with an ABI triple: the two name different
    // directories, and mixing them up silently yields a missing sysroot.
    for (hosts) |host| {
        for (std.enums.values(Abi)) |abi| {
            try testing.expect(!std.mem.eql(u8, host.directoryName(), abi.triple()));
        }
    }
}

test "r29's Pkg.Revision parses" {
    const properties =
        \\Pkg.Desc = Android NDK
        \\Pkg.Revision = 29.0.14206865
        \\Pkg.BaseRevision = 29.0.14206865
        \\Pkg.ReleaseName = r29
    ;
    const version = try Ndk.Version.parse(properties);
    try testing.expectEqual(@as(u32, 29), version.major);
    try testing.expectEqual(@as(u32, 0), version.minor);
    try testing.expectEqual(@as(u32, 14206865), version.patch);
}

test "version parsing tolerates spacing and rejects everything else" {
    try testing.expectEqual(
        @as(u32, 29),
        (try Ndk.Version.parse("Pkg.Revision=29.0.14206865")).major,
    );
    try testing.expectEqual(
        @as(u32, 14206865),
        (try Ndk.Version.parse("  Pkg.Revision \t= \t 29.0.14206865  \r")).patch,
    );

    // A different key is not the version.
    try testing.expectError(
        error.VersionUnreadable,
        Ndk.Version.parse("Pkg.ReleaseName = r29"),
    );
    // Neither is a truncated or over-long code.
    try testing.expectError(error.VersionUnreadable, Ndk.Version.parse("Pkg.Revision = 29.0"));
    try testing.expectError(
        error.VersionUnreadable,
        Ndk.Version.parse("Pkg.Revision = 29.0.14206865.1"),
    );
    try testing.expectError(
        error.VersionUnreadable,
        Ndk.Version.parse("Pkg.Revision = r29"),
    );
    // Nor is an absent or empty file.
    try testing.expectError(error.VersionUnreadable, Ndk.Version.parse(""));
    try testing.expectError(
        error.VersionUnreadable,
        Ndk.Version.parse("# Pkg.Desc = Android NDK\n"),
    );
}

test "open resolves a direct root and reports the direct shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    const sysroot = try createAll(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
    try testing.expectEqual(Ndk.Shape.direct, ndk.shape);
    try testing.expectEqual(HostTag.linux_x86_64, ndk.host_tag);
    try testing.expectEqualStrings(root, ndk.root_path);
    try testing.expectEqualStrings(sysroot, ndk.sysroot());
}

test "open resolves a root that keeps the NDK one level down" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // The shape a packaging wrapper leaves: the outer directory holds only
    // bin/ and libexec/, and the NDK itself sits under libexec/android-sdk.
    const sysroot = try createAll(gpa, &.{
        root,         "libexec", "android-sdk", "ndk-bundle",
        "toolchains", "llvm",    "prebuilt",    "linux-x86_64",
        "sysroot",
    });

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
    try testing.expectEqual(Ndk.Shape.ndk_bundle, ndk.shape);
    try testing.expectEqualStrings(sysroot, ndk.sysroot());

    const bundle_root = try path.join(gpa, &.{
        root, "libexec", "android-sdk", "ndk-bundle",
    });
    try testing.expectEqualStrings(bundle_root, ndk.root_path);
}

test "a direct root wins over a nested one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    const direct_sysroot = try createAll(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });
    const nested_sysroot = try createAll(gpa, &.{
        root,         "libexec", "android-sdk", "ndk-bundle",
        "toolchains", "llvm",    "prebuilt",    "linux-x86_64",
        "sysroot",
    });

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
    try testing.expectEqual(Ndk.Shape.direct, ndk.shape);
    try testing.expectEqualStrings(direct_sysroot, ndk.sysroot());
    try testing.expect(!std.mem.eql(u8, nested_sysroot, ndk.sysroot()));
}

test "a root with no sysroot, or no root at all, is not an NDK" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // A directory that exists and holds NDK metadata, but no toolchain.
    _ = try createAll(gpa, &.{ root, "meta" });
    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, root, .linux_x86_64),
    );

    // A path that does not exist at all.
    const missing = try path.join(gpa, &.{ root, "not-installed" });
    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, missing, .linux_x86_64),
    );
}

test "the host tag selects which prebuilt toolchain is used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // Only one prebuilt directory, and it is not the one asked for.
    const sysroot = try createAll(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });

    // The right host, pointed at the wrong installation.
    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, root, .darwin_x86_64),
    );

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
    try testing.expectEqualStrings(sysroot, ndk.sysroot());
}

test "API levels come back sorted and libcDirFor finds each one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    const triple_dir = try createAll(gpa, &.{
        root,  "toolchains", "llvm",                  "prebuilt", "linux-x86_64", "sysroot",
        "usr", "lib",        "aarch64-linux-android",
    });

    // Out of order on purpose, and beside a name that is not an API level.
    for ([_][]const u8{ "35", "21", "30", "debug" }) |level| {
        _ = try createAll(gpa, &.{ triple_dir, level });
    }

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);

    const levels = try ndk.apiLevelsFor(gpa, testing.io, .arm64_v8a);
    try testing.expectEqualSlices(u32, &.{ 21, 30, 35 }, levels);

    const crt_dir = try ndk.libcDirFor(gpa, testing.io, .arm64_v8a, 35);
    const expected = try path.join(gpa, &.{ triple_dir, "35" });
    try testing.expectEqualStrings(expected, crt_dir);

    // The triple is shipped, the level is not.
    try testing.expectError(
        error.ApiLevelUnavailable,
        ndk.libcDirFor(gpa, testing.io, .arm64_v8a, 34),
    );
    // Neither is the triple.
    try testing.expectError(
        error.UnsupportedAbi,
        ndk.libcDirFor(gpa, testing.io, .riscv64, 35),
    );
    try testing.expectError(
        error.UnsupportedAbi,
        ndk.apiLevelsFor(gpa, testing.io, .x86),
    );
}

test "readVersion reads the code, tolerates absence, refuses junk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    _ = try createAll(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);

    // No source.properties at all is legal and leaves the version unknown.
    try testing.expect(try ndk.readVersion(gpa, testing.io) == null);

    try scratch.dir.writeFile(testing.io, .{
        .sub_path = "source.properties",
        .data = "Pkg.Desc = Android NDK\nPkg.Revision = 29.0.14206865\n",
    });
    const version = (try ndk.readVersion(gpa, testing.io)).?;
    try testing.expectEqual(@as(u32, 29), version.major);
    try testing.expectEqual(@as(u32, 0), version.minor);
    try testing.expectEqual(@as(u32, 14206865), version.patch);

    // Present but unparsable is an error, not a silent null.
    try scratch.dir.writeFile(testing.io, .{
        .sub_path = "source.properties",
        .data = "Pkg.ReleaseName = r29\n",
    });
    try testing.expectError(
        error.VersionUnreadable,
        ndk.readVersion(gpa, testing.io),
    );
}

test "find takes the build option first, then the variables in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // `find` resolves the host tag from the compilation target, so on a host
    // Google publishes no NDK package for there is no order to assert. That
    // case is not skipped silently — it asserts the refusal in its place, and
    // that is precisely what these hosts otherwise never exercise. "This host
    // has no package" and "the path you configured is wrong" are different
    // problems with different fixes.
    const host = Ndk.hostTag(builtin.target) catch |err| switch (err) {
        error.UnsupportedHost => {
            var empty: Environ.Map = .init(testing.allocator);
            defer empty.deinit();
            try testing.expectError(
                error.UnsupportedHost,
                Ndk.find(gpa, testing.io, null, &empty),
            );
            return;
        },
        // `hostTag` takes a target and consults no directory, so the NDK-domain
        // refusals in its error set are unreachable here. The arm exists only
        // because the set is closed and a bare `catch` would drop the others
        // silently.
        else => unreachable,
    };

    var option_scratch = testing.tmpDir(.{});
    defer option_scratch.cleanup();
    const option_root = try createNdk(
        gpa,
        &option_scratch,
        host,
        "riscv64-linux-android",
        &.{},
    );

    var env_scratch = testing.tmpDir(.{});
    defer env_scratch.cleanup();
    const env_root = try createNdk(
        gpa,
        &env_scratch,
        host,
        "i686-linux-android",
        &.{"21"},
    );

    var dead_scratch = testing.tmpDir(.{});
    defer dead_scratch.cleanup();
    const dead_root = try absPathOf(gpa, &dead_scratch);
    const missing = try path.join(gpa, &.{ dead_root, "gone" });

    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("ANDROID_NDK_HOME", env_root);
    try environ.put("ANDROID_NDK_ROOT", env_root);
    try environ.put("ANDROID_NDK", env_root);

    // An explicit option outranks every variable.
    {
        const ndk = try Ndk.find(gpa, testing.io, option_root, &environ);
        try testing.expectEqualStrings(option_root, ndk.root_path);
    }
    // Without one, the variables are consulted in the documented order.
    {
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(env_root, ndk.root_path);
    }
    // A variable that is not on disk is skipped for the next one. An explicit
    // option is not, which is what the test below says.
    {
        try environ.put("ANDROID_NDK_HOME", missing);
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(env_root, ndk.root_path);
    }
    // An existing directory that is not an NDK stops discovery, so the mistake
    // is reported instead of silently falling through to a worse answer.
    {
        try environ.put("ANDROID_NDK_HOME", dead_root);
        try testing.expectError(
            error.NotAnNdk,
            Ndk.find(gpa, testing.io, null, &environ),
        );
    }
    // Nothing set, and everything set but absent, are discovery failures.
    {
        var empty: Environ.Map = .init(testing.allocator);
        defer empty.deinit();
        try testing.expectError(
            error.NdkNotFound,
            Ndk.find(gpa, testing.io, null, &empty),
        );

        try environ.put("ANDROID_NDK_HOME", missing);
        try environ.put("ANDROID_NDK_ROOT", missing);
        try environ.put("ANDROID_NDK", missing);
        try testing.expectError(
            error.NdkNotFound,
            Ndk.find(gpa, testing.io, null, &environ),
        );
    }
}

/// Renders the refusal `Ndk.describeProbeFailure` writes, as one string.
/// `testing`-allocator-owned; the caller frees it. Test helper.
///
/// `testing.allocator` and not the arena, so a renderer that stops copying what
/// it was handed fails the leak check instead of passing unnoticed.
fn probeMessage(root: []const u8, host: HostTag) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try Ndk.describeProbeFailure(
        arena.allocator(),
        testing.io,
        root,
        host,
        &out.writer,
    );
    return testing.allocator.dupe(u8, out.written());
}

/// Writes a plain file at the absolute path `file_path`. Test helper.
///
/// The point of it is a file where a directory is expected: `createAll` cannot
/// make one, and a refusal of `error.FileNotFound` proves nothing about a path
/// that is present and is simply the wrong kind of thing.
///
/// Absolute, because the trees are built through `Dir.cwd` from the canonical
/// spelling `absPathOf` returns, and a tmp dir handle may hold a different
/// spelling of the same directory — through a symlink in `TMPDIR`, say — in
/// which case a path spelled relatively to the handle names a different tree.
fn createFile(file_path: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = file_path, .data = data });
}

test "a refusal names both probed layouts and the host tag" {
    // The defect this catches: D3 promises the refusal names every path it
    // tried, and `open` returned the bare `error.NotAnNdk`. A user who pointed
    // `-Dndk` at an SDK root then had to guess which of two layouts was
    // expected, and the two are not guesses a user can make.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // Exists, holds NDK metadata, holds no toolchain: the case D3 is about.
    _ = try createAll(gpa, &.{ root, "meta" });
    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, root, .linux_x86_64),
    );

    const message = try probeMessage(root, .linux_x86_64);
    defer testing.allocator.free(message);

    // Both layouts, named, in probe order.
    const direct_at = std.mem.indexOf(u8, message, "direct:").?;
    const bundle_at = std.mem.indexOf(u8, message, "ndk_bundle:").?;
    try testing.expect(direct_at < bundle_at);

    // Both sysroot paths, spelled the way discovery spells them.
    const direct_sysroot = try path.join(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });
    const bundle_sysroot = try path.join(gpa, &.{
        root,         "libexec", "android-sdk", "ndk-bundle",
        "toolchains", "llvm",    "prebuilt",    "linux-x86_64",
        "sysroot",
    });
    try testing.expect(std.mem.indexOf(u8, message, direct_sysroot) != null);
    try testing.expect(std.mem.indexOf(u8, message, bundle_sysroot) != null);

    // And the host tag, without which the paths say nothing about which
    // toolchain was looked for.
    try testing.expect(std.mem.indexOf(u8, message, "linux-x86_64") != null);
}

test "a refusal describes a root that was never installed" {
    // The other half of the requirement: an absent root has no canonical
    // spelling to report, and a diagnostic that gave up on it would leave the
    // commonest `-Dndk` mistake — a typo, or an NDK that was never fetched —
    // undescribed.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);
    const missing = try path.join(gpa, &.{ root, "not-installed" });

    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, missing, .linux_x86_64),
    );

    var probes = try Ndk.probeCandidates(gpa, testing.io, missing, .linux_x86_64);
    defer probes.deinit(gpa);

    try testing.expectEqual(HostTag.linux_x86_64, probes.host_tag);
    try testing.expectEqual(@as(usize, 2), probes.entries.len);

    const message = try probeMessage(missing, .linux_x86_64);
    defer testing.allocator.free(message);

    for (probes.entries) |entry| {
        try testing.expect(std.mem.indexOf(u8, message, entry.sysroot) != null);
    }
    try testing.expect(std.mem.indexOf(u8, message, "linux-x86_64") != null);
}

test "probeCandidates names the paths discovery actually probed" {
    // The drift guard. A diagnostic built from its own copy of the layout table
    // can name a path that discovery never looked at, and it keeps doing so
    // until the NDK moves a directory. These two trees are the only two layouts
    // there are, and each has to be reported by the layout that answered.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    {
        var scratch = testing.tmpDir(.{});
        defer scratch.cleanup();
        const root = try absPathOf(gpa, &scratch);
        _ = try createAll(gpa, &.{
            root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
        });

        const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
        try testing.expectEqual(Ndk.Shape.direct, ndk.shape);

        var probes = try Ndk.probeCandidates(gpa, testing.io, root, .linux_x86_64);
        defer probes.deinit(gpa);

        try testing.expectEqual(Ndk.Shape.direct, probes.entries[0].shape);
        try testing.expectEqual(Ndk.Shape.ndk_bundle, probes.entries[1].shape);
        try testing.expectEqualStrings(root, probes.entries[0].ndk_root);
        try testing.expectEqualStrings(ndk.sysroot(), probes.entries[0].sysroot);
        try testing.expect(!std.mem.eql(u8, ndk.sysroot(), probes.entries[1].sysroot));
    }
    {
        var scratch = testing.tmpDir(.{});
        defer scratch.cleanup();
        const root = try absPathOf(gpa, &scratch);
        _ = try createAll(gpa, &.{
            root,         "libexec", "android-sdk", "ndk-bundle",
            "toolchains", "llvm",    "prebuilt",    "linux-x86_64",
            "sysroot",
        });

        const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);
        try testing.expectEqual(Ndk.Shape.ndk_bundle, ndk.shape);

        var probes = try Ndk.probeCandidates(gpa, testing.io, root, .linux_x86_64);
        defer probes.deinit(gpa);

        try testing.expectEqual(Ndk.Shape.ndk_bundle, probes.entries[1].shape);
        try testing.expectEqualStrings(ndk.sysroot(), probes.entries[1].sysroot);

        const bundle_root = try path.join(gpa, &.{
            root, "libexec", "android-sdk", "ndk-bundle",
        });
        try testing.expectEqualStrings(bundle_root, probes.entries[1].ndk_root);
    }
}

test "the probed paths name the host tag they were built for" {
    // A refusal about a toolchain the caller never asked for is worse than no
    // refusal, so the tag has to be an argument rather than something read off
    // the machine behind the caller's back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    var probes = try Ndk.probeCandidates(gpa, testing.io, root, .darwin_x86_64);
    defer probes.deinit(gpa);
    try testing.expectEqual(HostTag.darwin_x86_64, probes.host_tag);

    const message = try probeMessage(root, .darwin_x86_64);
    defer testing.allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "darwin-x86_64") != null);
    try testing.expect(std.mem.indexOf(u8, message, "linux-x86_64") == null);
}

test "a plain file named like an API level is not an API level" {
    // The defect this catches: `libcDirFor` gated on existence while
    // `apiLevelsFor` gated on `entry.kind == .directory`. A regular file named
    // `99` was correctly left out of the level list and still accepted as a
    // `crt_dir`, so the build failed later, at link time, with a message about
    // libc pointing nowhere near the file that caused it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    const triple_dir = try createAll(gpa, &.{
        root,  "toolchains", "llvm",                  "prebuilt", "linux-x86_64", "sysroot",
        "usr", "lib",        "aarch64-linux-android",
    });
    for ([_][]const u8{ "21", "35" }) |level| {
        _ = try createAll(gpa, &.{ triple_dir, level });
    }
    // Parses as an API level, is not one.
    try createFile(try path.join(gpa, &.{ triple_dir, "99" }), "not a directory");

    const ndk = try Ndk.open(gpa, testing.io, root, .linux_x86_64);

    // The iterator never reported it...
    const levels = try ndk.apiLevelsFor(gpa, testing.io, .arm64_v8a);
    try testing.expectEqualSlices(u32, &.{ 21, 35 }, levels);

    // ...and the stat that libcDirFor now uses refuses it the same way. The two
    // answers have to come from one predicate, or the file lands back in the
    // middle.
    try testing.expectError(
        error.ApiLevelUnavailable,
        ndk.libcDirFor(gpa, testing.io, .arm64_v8a, 99),
    );

    // The real levels are untouched.
    const crt_dir = try ndk.libcDirFor(gpa, testing.io, .arm64_v8a, 35);
    const expected = try path.join(gpa, &.{ triple_dir, "35" });
    try testing.expectEqualStrings(expected, crt_dir);
}

test "a root that is a plain file is not an NDK" {
    // The defect this catches: `open` documents `error.NotAnNdk` for a root that
    // is not a usable installation, and an unzipped archive is exactly a regular
    // file. `realPathFileAlloc` succeeds on a file, so the probe walked to
    // `<file>/toolchains/...`, got `NotDir`, and handed that syscall code back
    // to a caller that can act on nothing but "that is not an NDK".
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    const archive = try path.join(gpa, &.{ root, "android-ndk-r29.zip" });
    try createFile(archive, "PK\x03\x04 not really a zip");

    try testing.expectError(
        error.NotAnNdk,
        Ndk.open(gpa, testing.io, archive, .linux_x86_64),
    );

    // The refusal still describes what was probed, which is the whole point of
    // the diagnostic: the paths under a file are exactly what a user needs to
    // see to work out that the thing they named is a file.
    const message = try probeMessage(archive, .linux_x86_64);
    defer testing.allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "android-ndk-r29.zip") != null);
    try testing.expect(std.mem.indexOf(u8, message, "ndk_bundle:") != null);
}

test "an ABI round-trips through its NDK name" {
    // Every name the NDK ships maps back, and nothing else does.
    for (std.enums.values(Abi)) |abi| {
        try testing.expectEqual(abi, Abi.fromName(abi.name()));
    }
    try testing.expectEqual(Abi.arm64_v8a, Abi.fromName("arm64-v8a"));

    // The inverse is exact, and every one of these is the way a caller
    // misspells the name: the Zig tag for the ABI, the shouted spelling, a
    // trailing separator carried over from a path, a name with a stray space,
    // and the empty string.
    const rejected = [_][]const u8{
        "arm64_v8a",
        "ARM64-V8A",
        "armeabi-v7a/",
        " arm64-v8a",
        "arm64-v8a ",
        "x86-64",
        "arm64",
        "",
    };
    for (rejected) |name| {
        try testing.expectEqual(@as(?Abi, null), Abi.fromName(name));
    }

    // The five names are distinct, so no name can resolve to two ABIs.
    const abis = std.enums.values(Abi);
    for (abis, 0..) |a, i| {
        for (abis, 0..) |b, j| {
            if (j <= i) continue;
            try testing.expect(Abi.fromName(a.name()) != b);
        }
    }
}

/// How many non-overlapping occurrences of `needle` are in `haystack`.
/// Test helper.
fn countOf(haystack: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |start| {
        found += 1;
        at = start + needle.len;
    }
    return found;
}

test "the probe paths are freed under a checking allocator" {
    // The defect this catches: `probeCandidates` bound the peeled type of
    // `realPathFileAlloc` — which returns `[:0]u8` — to the value it frees, so
    // `Allocator.free` recovered the block length without the sentinel and asked
    // for one byte fewer than `dupeZ` allocated, on every call whose root is on
    // disk. Nothing else in this repository could see it: every caller here and
    // in `build.zig` hands these two functions an arena, and an arena makes a
    // short free a silent no-op. `testing.allocator` compares the free size
    // against the allocation, so it is the only allocator that turns this back
    // into a failure, and passing one is the whole point of the test.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // On disk, because that is the branch `realPathFileAlloc` answers. The
    // absent-root branch allocates through `dupeZ` and was never short.
    _ = try createAll(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });

    {
        var probes = try Ndk.probeCandidates(testing.allocator, testing.io, root, .linux_x86_64);
        defer probes.deinit(testing.allocator);
        try testing.expectEqual(HostTag.linux_x86_64, probes.host_tag);
        try testing.expectEqual(@as(usize, 2), probes.entries.len);
        try testing.expect(probes.entries[0].sysroot.len > 0);
    }

    // And through the renderer a consumer reaches, which owns the same free.
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try Ndk.describeProbeFailure(testing.allocator, testing.io, root, .linux_x86_64, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "linux-x86_64") != null);
}

test "a discovery refusal names every source and the value it read" {
    // The defect this catches: the renderer for `NdkNotFound` — the refusal a
    // caller meets first, and the only one this package exported nothing for —
    // was a private function in `build.zig`, so `@import` carried the renderer
    // for the rarer `NotAnNdk` and not this one. Every consumer had to re-spell
    // the walk, and the vocabulary that tells a variable no shell exported from
    // one that was exported empty.
    //
    // Synthetic maps, never the process environment: a test that read the real
    // one would assert whatever the machine running it happened to export.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Nothing set anywhere, which is what a fresh checkout looks like.
    {
        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();

        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try Ndk.describeDiscoveryFailure(null, &environ, &out.writer);
        const message = out.written();

        // All four, in the walk's order. The labels, not the bare names: the
        // paragraph above the list names `ANDROID_NDK_HOME` in prose, and the
        // order being asserted is the order of the sources, not the order of
        // first mention.
        const option_at = std.mem.indexOf(u8, message, "the -Dndk build option").?;
        const home_at = std.mem.indexOf(u8, message, "the ANDROID_NDK_HOME environment").?;
        const root_at = std.mem.indexOf(u8, message, "the ANDROID_NDK_ROOT environment").?;
        const bare_at = std.mem.indexOf(u8, message, "the ANDROID_NDK environment").?;
        try testing.expect(option_at < home_at);
        try testing.expect(home_at < root_at);
        try testing.expect(root_at < bare_at);

        // One `(unset)` per source, four sources, and nothing else quoted: the
        // report cannot be naming a variable the map does not have.
        try testing.expectEqual(@as(usize, 4), discovery_sources.len);
        try testing.expectEqual(discovery_sources.len, countOf(message, "(unset)"));
        try testing.expect(std.mem.indexOf(u8, message, "(empty)") == null);

        // Which is the refusal this message is for.
        try testing.expectError(
            error.NdkNotFound,
            Ndk.find(gpa, testing.io, null, &environ),
        );
    }

    // Set, empty, padded and set again: four values, and they are the caller's
    // own strings rather than copies of them.
    {
        var scratch = testing.tmpDir(.{});
        defer scratch.cleanup();
        const padded_root = try absPathOf(gpa, &scratch);

        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();
        // A root that IS on disk, spelled the way a CI YAML block scalar, a
        // `$(cat ndk.path)` and a tab-indented Makefile value all spell it:
        // padded on both sides. What the refusal prints is the path discovery
        // would have probed, so the padding cannot survive into the report — a
        // report naming '  /path  ' is naming a path no probe ever looked at,
        // and the reader who types it back gets a directory that is not there.
        try environ.put(
            "ANDROID_NDK_HOME",
            try std.fmt.allocPrint(gpa, "  {s}\t\n ", .{padded_root}),
        );
        try environ.put("ANDROID_NDK_ROOT", "");
        try environ.put("ANDROID_NDK", "~/ndk");

        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try Ndk.describeDiscoveryFailure("/opt/ndk/explicit", &environ, &out.writer);
        const message = out.written();

        try testing.expect(std.mem.indexOf(u8, message, "/opt/ndk/explicit") != null);
        try testing.expect(std.mem.indexOf(u8, message, "~/ndk") != null);
        // The empty one reads `(empty)` and not `(unset)`: a reader shown
        // `(unset)` would go looking for a variable that was exported.
        try testing.expect(std.mem.indexOf(u8, message, "'(empty)'") != null);
        try testing.expectEqual(@as(usize, 0), countOf(message, "(unset)"));

        // Trimmed, inside the quotes and on both sides of them. The value is
        // quoted, so the assertion is about the bytes between the quotes and
        // not about a substring the surrounding prose could satisfy.
        try testing.expect(
            std.mem.indexOf(
                u8,
                message,
                try std.fmt.allocPrint(gpa, "'{s}'", .{padded_root}),
            ) != null,
        );
        try testing.expect(
            std.mem.indexOf(
                u8,
                message,
                try std.fmt.allocPrint(gpa, "'  {s}", .{padded_root}),
            ) == null,
        );
        // And no escape for the tab or the newline the padding carried: those
        // bytes were the shell's, not the path's, so the report must not carry
        // them into a value the reader is meant to type back.
        try testing.expect(std.mem.indexOf(u8, message, "\\x09") == null);
        try testing.expect(std.mem.indexOf(u8, message, "\\x0a") == null);
    }
}

test "an explicit -Dndk that is not on disk is a pin, not a preference" {
    // The defect this catches: the walk fell through on `FileNotFound`, so
    // `-Dndk=/opt/android-ndk-r29` naming a path that is not there — a dangling
    // symlink, a typo, an NDK that was never fetched — was answered by whatever
    // `ANDROID_NDK_HOME` the runner image happened to export. The build linked,
    // reported success, and never said the option had been ignored, which is
    // the case CONTRACT.md D3's "explicit beats implicit, always" is about.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // `find` takes the host tag from the compilation target, so on a host Google
    // publishes no package for there is no tree worth building. That is not a
    // silent skip: the refusal is asserted in its place by the discovery test
    // above, and those hosts are exactly what it exercises.
    const host = Ndk.hostTag(builtin.target) catch |err| switch (err) {
        error.UnsupportedHost => return,
        else => unreachable,
    };

    var good_scratch = testing.tmpDir(.{});
    defer good_scratch.cleanup();
    const good = try createNdk(gpa, &good_scratch, host, "riscv64-linux-android", &.{});

    var dead_scratch = testing.tmpDir(.{});
    defer dead_scratch.cleanup();
    const dead_root = try absPathOf(gpa, &dead_scratch);
    const missing = try path.join(gpa, &.{ dead_root, "not-installed" });

    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("ANDROID_NDK_HOME", good);
    try environ.put("ANDROID_NDK_ROOT", good);
    try environ.put("ANDROID_NDK", good);

    // Present: the option answers, as it always did.
    {
        const ndk = try Ndk.find(gpa, testing.io, good, &environ);
        try testing.expectEqualStrings(good, ndk.root_path);
    }
    // Absent: the walk stops, even though all three variables name an
    // installation that is right there.
    try testing.expectError(
        error.NdkNotFound,
        Ndk.find(gpa, testing.io, missing, &environ),
    );
    // Not named at all, so the variables answer as they always did.
    {
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(good, ndk.root_path);
    }
    // Named with nothing in it is not naming a path, and pins nothing.
    {
        const empty = try Ndk.find(gpa, testing.io, "", &environ);
        try testing.expectEqualStrings(good, empty.root_path);
        const blank = try Ndk.find(gpa, testing.io, "  \t\r\n ", &environ);
        try testing.expectEqualStrings(good, blank.root_path);
    }
    // A root that is there and holds no NDK already stopped the walk and still
    // does: the pin is about absence, not about a path that answers wrongly.
    {
        var meta_scratch = testing.tmpDir(.{});
        defer meta_scratch.cleanup();
        const meta_root = try absPathOf(gpa, &meta_scratch);
        _ = try createAll(gpa, &.{ meta_root, "meta" });
        try testing.expectError(
            error.NotAnNdk,
            Ndk.find(gpa, testing.io, meta_root, &environ),
        );
    }
}

test "a candidate with whitespace around it is the path without the whitespace" {
    // The defect this catches: nothing trimmed a candidate before probing it,
    // so `export ANDROID_NDK_HOME=$(cat ndk.path)` — and every CI YAML block
    // scalar, `for` loop over a file and Windows `.bat` that leaves the same
    // newline on a value — named a path that was never there. The walk then
    // refused with `NdkNotFound`, which says nothing about a newline, or linked
    // the next variable's NDK without a word.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const host = Ndk.hostTag(builtin.target) catch |err| switch (err) {
        error.UnsupportedHost => return,
        else => unreachable,
    };

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const good = try createNdk(gpa, &scratch, host, "x86_64-linux-android", &.{});

    const paddings = [_][]const u8{
        "\n", // $(cat file), or a YAML `|`
        "\r\n", // the same value through a CRLF checkout
        "\r", // an old shell, or a CR left by a Windows editor
        " ", // a quoted expansion with a stray space
        "\t", // a tab-indented value in a Makefile
        " \t\r\n ", // all of them at once
    };
    for (paddings) |padding| {
        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();
        const padded = try std.fmt.allocPrint(gpa, "{s}{s}", .{ good, padding });
        try environ.put("ANDROID_NDK_HOME", padded);

        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(good, ndk.root_path);
    }

    // A value that is nothing but whitespace is not a candidate at all, and pins
    // nothing: there is no path in it to be wrong about.
    {
        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();
        try environ.put("ANDROID_NDK_HOME", " \t\r\n ");
        try environ.put("ANDROID_NDK_ROOT", good);
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(good, ndk.root_path);
    }

    // The interior is not trimmed, because POSIX lets a directory name hold a
    // newline and trimming one out would refuse a path that really is there. It
    // resolves when that directory exists...
    {
        const nested = try path.join(gpa, &.{ good, "two\nlines" });
        _ = try createAll(gpa, &.{
            nested,
            "toolchains",
            "llvm",
            "prebuilt",
            host.directoryName(),
            "sysroot",
        });
        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();
        try environ.put("ANDROID_NDK_HOME", nested);
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(nested, ndk.root_path);
    }
    // ...and is walked past, like any other path that is not there.
    {
        var environ: Environ.Map = .init(testing.allocator);
        defer environ.deinit();
        try environ.put("ANDROID_NDK_HOME", try path.join(gpa, &.{ good, "not\nhere" }));
        try environ.put("ANDROID_NDK_ROOT", good);
        const ndk = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(good, ndk.root_path);
    }
}

test "a refusal stays one line whatever the candidate carries" {
    // The defect this catches: the value was rendered raw, so a candidate that
    // arrived with a newline on the end of it — or, which POSIX allows, in the
    // middle — broke the report across lines and every line after the break read
    // as part of the path. A message whose own content can move its own
    // boundaries can lie about its structure.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try absPathOf(gpa, &scratch);

    // A root with nothing to escape, and one whose name holds a newline and a
    // tab.
    const clean = try probeMessage(root, .linux_x86_64);
    defer testing.allocator.free(clean);

    const noisy = try probeMessage(
        try path.join(gpa, &.{ root, "android\nndk\tr29" }),
        .linux_x86_64,
    );
    defer testing.allocator.free(noisy);

    // The same number of lines as the root with nothing to escape: the newline
    // and the tab became escapes rather than line breaks.
    try testing.expectEqual(countOf(clean, "\n"), countOf(noisy, "\n"));
    // Visible rather than swallowed, so a reader can see that the value they
    // exported is not the value that was probed.
    try testing.expect(std.mem.indexOf(u8, noisy, "android\\x0andk\\x09r29") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "\\x0a") == null);

    // A candidate whose newline TRAILING is a different case from one whose
    // newline is in the middle. The interior one is a real directory name, so
    // it stays and the refusal shows it escaped; trailing padding is trimmed
    // before the probe, so the paths the refusal reports are the paths the
    // probe used, spelled clean. Delete that trim and the probe falls back to
    // the candidate as written, every reported sysroot ends in `\x0a`, and the
    // report names two directories that were never probed.
    const padded = try probeMessage(
        try std.fmt.allocPrint(gpa, "{s}\n", .{root}),
        .linux_x86_64,
    );
    defer testing.allocator.free(padded);

    // The sysroot paths are the canonical ones, byte for byte.
    const canonical_sysroot = try path.join(gpa, &.{
        root, "toolchains", "llvm", "prebuilt", "linux-x86_64", "sysroot",
    });
    try testing.expect(std.mem.indexOf(u8, padded, canonical_sysroot) != null);

    // And the section that lists them carries no escape at all. The header
    // names the candidate as the CALLER wrote it, escaped on purpose, so the
    // assertion is scoped to the probe paths below that header rather than to
    // the whole message — an escape in the header is the contract and an
    // escape down here is the defect.
    const header = "that is a directory:\n";
    const probed_at = std.mem.indexOf(u8, padded, header).?;
    const probed = padded[probed_at + header.len ..];
    try testing.expect(std.mem.indexOf(u8, probed, "\\x0a") == null);
    try testing.expect(std.mem.indexOf(u8, probed, "\\x09") == null);
    // Same number of lines as the root with nothing to escape: the trailing
    // newline neither ended a line nor left an escape behind.
    try testing.expectEqual(countOf(clean, "\n"), countOf(padded, "\n"));

    // The discovery refusal has the same hazard in it: a variable carries a
    // newline as easily as a path does.
    {
        var noisy_env: Environ.Map = .init(testing.allocator);
        defer noisy_env.deinit();
        try noisy_env.put("ANDROID_NDK_HOME", "/opt/ndk\nr29");

        var bare_env: Environ.Map = .init(testing.allocator);
        defer bare_env.deinit();
        try bare_env.put("ANDROID_NDK_HOME", "/opt/ndk-r29");

        var noisy_out: Writer.Allocating = .init(testing.allocator);
        defer noisy_out.deinit();
        try Ndk.describeDiscoveryFailure(null, &noisy_env, &noisy_out.writer);

        var bare_out: Writer.Allocating = .init(testing.allocator);
        defer bare_out.deinit();
        try Ndk.describeDiscoveryFailure(null, &bare_env, &bare_out.writer);

        try testing.expectEqual(
            countOf(bare_out.written(), "\n"),
            countOf(noisy_out.written(), "\n"),
        );
        try testing.expect(std.mem.indexOf(u8, noisy_out.written(), "/opt/ndk\\x0ar29") != null);
    }
}
