//! Consumer-shaped integration tests for zig-ndk.
//!
//! Everything here reaches the package the way a dependent build reaches it:
//! through the published `ndk` module, under the same import name build.zig
//! hands to `exe.root_module.addImport("ndk", dep.module("ndk"))`. Nothing in
//! this file knows the on-disk NDK layout except as a string it asks the
//! library to confirm, so a test cannot pass by re-deriving what it is
//! supposed to be checking.
//!
//! A relative `@import("../src/ndk.zig")` is not an alternative here. The
//! compiler roots a module at the directory of its root source file, so a file
//! at `test/integration_test.zig` has `test/` as its root and any path that
//! escapes it is rejected with "import of file outside module path". The named
//! import is the shape a consumer compiles against, and it is what build.zig
//! wires.
//!
//! **No test in this file needs an NDK.** Each one builds the tree it asserts
//! against under `.zig-cache/tmp` via `std.testing.tmpDir` and removes it with
//! `defer`. No test reads `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` or
//! `ANDROID_NDK` from the process environment: `Ndk.find` takes its
//! environment as a `*const Environ.Map` parameter, and the tests inject a map
//! they built, which is what keeps them order-independent under
//! `zig build test` parallelism.
//!
//! The tests are grouped by the defect each one is aimed at, and each says
//! which defect it is in its own doc comment. A test that restates the code is
//! worth nothing; the ones here are the places where a plausible edit to the
//! ABI table, the discovery order or the paths file would pass every other
//! gate in this package and still hand a consumer a binary that does not link.

const std = @import("std");
const builtin = @import("builtin");

// The published module, imported the way a dependent build imports it.
const ndk = @import("ndk");

const Abi = ndk.Abi;
const HostTag = ndk.HostTag;
const Ndk = ndk.Ndk;
const LibcPaths = ndk.LibcPaths;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const Target = std.Target;
const path = std.fs.path;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

/// A scratch directory and its absolute path.
///
/// The directory is `std.testing.tmpDir`'s, which lives under
/// `.zig-cache/tmp`, so no test reads a real NDK and none writes into the
/// source tree. The absolute path is `gpa`-owned: every test here runs on an
/// arena, so a path never has to be freed by hand and a leak check cannot fail
/// on a path that is still in use.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,

    /// Creates a fresh scratch directory. `gpa` must outlive every path the
    /// returned `root` hands out.
    fn init(gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .root = try gpa.dupe(u8, buf[0..len]) };
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.* = undefined;
    }
};

/// Creates `parts` with every missing parent, and returns the absolute path.
/// `gpa`-owned.
///
/// `parts[0]` may already be absolute. `createTree` passes the NDK root there,
/// which is `f.root` itself for the direct shape and a directory below it for
/// the bundled one, so prefixing it a second time would build the tree at
/// `<root>/<root>/toolchains/…` — which is not an NDK, and which every probe in
/// this file would then correctly refuse.
fn mkdir(f: *Fixture, gpa: Allocator, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    if (parts.len == 0 or !path.isAbsolute(parts[0])) try all.append(gpa, f.root);
    try all.appendSlice(gpa, parts);
    const full = try path.join(gpa, all.items);
    try Dir.cwd().createDirPath(testing.io, full);
    return full;
}

/// Builds a synthetic NDK in `shape`, carrying `abi`'s triple directory with
/// one subdirectory per entry of `levels`. Returns the triple directory.
///
/// Enough of a tree for `open`, `libcDirFor`, `apiLevelsFor` and `readVersion`
/// to be exercised with no NDK anywhere on the machine. The triple is asked
/// of the library rather than written here: a tree built from a hand-copied
/// triple keeps passing after the table moves, which is the failure this
/// suite exists to catch. The five components between the NDK root and the
/// triple are spelled out in full for the same reason.
fn createTree(
    f: *Fixture,
    gpa: Allocator,
    host: HostTag,
    shape: Ndk.Shape,
    abi: Abi,
    levels: []const []const u8,
) ![]u8 {
    const triple = abi.triple();
    const base = switch (shape) {
        .direct => f.root,
        .ndk_bundle => try mkdir(f, gpa, &.{ "libexec", "android-sdk", "ndk-bundle" }),
    };

    const triple_dir = try mkdir(f, gpa, &.{
        base,
        "toolchains",
        "llvm",
        "prebuilt",
        host.directoryName(),
        "sysroot",
        "usr",
        "lib",
        triple,
    });

    for (levels) |level| {
        _ = try mkdir(f, gpa, &.{
            base,
            "toolchains",
            "llvm",
            "prebuilt",
            host.directoryName(),
            "sysroot",
            "usr",
            "lib",
            triple,
            level,
        });
    }

    return triple_dir;
}

/// An `Environ.Map` holding only what a test puts in it.
///
/// Built fresh per assertion rather than mutated, because `Environ.Map` has no
/// remove and a map edited across four assertions is four assertions in a
/// trench coat. `gpa`-backed, so `deinit` is a no-op on the arena and the map
/// outlives every path it holds.
fn environOf(gpa: Allocator, entries: []const [2][]const u8) !Environ.Map {
    var map: Environ.Map = .init(gpa);
    errdefer map.deinit();
    for (entries) |entry| try map.put(entry[0], entry[1]);
    return map;
}

/// The host tag `Ndk.find` will use, which it derives from `builtin.target`
/// rather than from a parameter.
///
/// `null` means Google publishes no NDK package for the host these tests are
/// running on. That case is not skipped silently: the tests that need `find`
/// assert the refusal in its place. "This host has no package" and "the path
/// you configured is wrong" are different problems with different fixes, and
/// conflating them is the defect `error.UnsupportedHost` exists to prevent.
fn findHostTag() !?HostTag {
    const host = Ndk.hostTag(builtin.target) catch |err| switch (err) {
        error.UnsupportedHost => return null,
        // `hostTag` takes a target and consults no directory, so the NDK-domain
        // refusals in its error set are unreachable here. The arm exists only
        // because the set is closed and a bare `catch` would drop the others
        // silently.
        else => unreachable,
    };
    return host;
}

/// The `name=value` lines of a libc paths file, in the order the parser sees
/// them.
///
/// `LibCInstallation.parse` drops blank lines and `#` comments before it counts
/// keys, so what is left here is exactly the set it will require. `gpa`-owned;
/// every caller passes an arena, so the result is never freed.
fn keyLines(gpa: Allocator, text: []const u8) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer lines.deinit(gpa);
    var tokenizer = std.mem.tokenizeScalar(u8, text, '\n');
    while (tokenizer.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try lines.append(gpa, try gpa.dupe(u8, line));
    }
    return lines.items;
}

/// Writes `text` to a scratch file and hands the path to the compiler's own
/// libc paths file parser.
///
/// `std.testing.tmpDir` places its directory at `.zig-cache/tmp/<16 chars>`
/// relative to the working directory, and `LibCInstallation.parse` reads
/// through `Io.Dir.cwd`, so the path handed over is that join rather than the
/// absolute one. The buffer is fixed size because the joined path cannot be
/// longer than the scratch name plus a separator.
fn parsePathsFile(
    gpa: Allocator,
    text: []const u8,
    target: *const std.Target,
) !std.zig.LibCInstallation {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "libc.cfg", .data = text });

    var path_buf: [128]u8 = undefined;
    const file_path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache{c}tmp{c}{s}{c}libc.cfg",
        .{ path.sep, path.sep, scratch.sub_path[0..], path.sep },
    );
    // An arena, never `testing.allocator`: `LibCInstallation.parse` allocates
    // each value with `dupeZ` and stores it in a sentinel-free field, so
    // `LibCInstallation.deinit` frees one byte short of what it allocated and a
    // bounds-checking allocator rejects that. `src/libc_file.zig` records the
    // same upstream problem on the same compiler line.
    return std.zig.LibCInstallation.parse(gpa, testing.io, file_path, target);
}

/// The Android target the libc paths file parser is exercised against.
///
/// Built through the resolver because `std.Target` cannot be written as a
/// literal without a `cpu.model` that outlives it. Non-Darwin, so `parse`
/// enforces the non-empty `crt_dir` an Android file must carry.
fn androidTarget() !std.Target {
    return std.zig.system.resolveTargetQuery(
        testing.io,
        try Target.Query.parse(.{ .arch_os_abi = "aarch64-linux-android.35" }),
    );
}

// ---------------------------------------------------------------------------
// 1. The ABI table
// ---------------------------------------------------------------------------

test "every ABI has a unique non-empty name and triple, and a floor r29 could declare" {
    // The defect this catches: two ABIs sharing a triple resolve to one
    // `usr/lib/<triple>` directory, so the CRT objects and `libc.a` picked for
    // one of them are the other's. Both paths exist, nothing downstream
    // complains, and the wrong libc is linked. A zeroed triple is the same
    // class of failure: it collapses `usr/lib/<triple>` to `usr/lib`, a real
    // directory holding a `libc.a` for every ABI at once.
    const abis = std.enums.values(Abi);

    for (abis, 0..) |a, i| {
        try testing.expect(a.name().len > 0);
        try testing.expect(a.triple().len > 0);

        // Neither may carry a separator. A name carrying one would let a
        // `-Dabi=` argument carry path structure, and a lookup for it would
        // resolve to a path that is simply absent — a missing directory rather
        // than a typo in the table.
        try testing.expect(std.mem.indexOfScalar(u8, a.name(), path.sep) == null);
        try testing.expect(std.mem.indexOfScalar(u8, a.triple(), path.sep) == null);

        // The namespaced spelling must not drift from the method, since
        // build.zig's generated helper reaches the table through it.
        try testing.expectEqualStrings(a.triple(), Ndk.tripleFor(a));

        // r29 declares 21 for four ABIs and 35 for riscv64. Below 21 is a
        // release the NDK does not target and above 35 nothing has shipped, so
        // either way the level resolves to a directory that is not there — a
        // typo that configures cleanly and fails at the consumer's link step.
        try testing.expect(a.minApiLevel() >= 21);
        try testing.expect(a.minApiLevel() <= 35);

        for (abis, 0..) |b, j| {
            if (j <= i) continue;

            try testing.expect(!std.mem.eql(u8, a.name(), b.name()));
            try testing.expect(!std.mem.eql(u8, a.triple(), b.triple()));

            // The two namespaces must not collide with each other either.
            // `armeabi-v7a` and `arm-linux-androideabi` name different
            // directories under `usr/lib`, and swapping one for the other
            // yields a path that is simply absent.
            try testing.expect(!std.mem.eql(u8, a.name(), b.triple()));
            try testing.expect(!std.mem.eql(u8, a.triple(), b.name()));
        }
    }
}

test "only 32-bit ARM is androideabi, and the float ABI follows from that" {
    // The defect this catches is silent until the binary is on a device. Zig
    // reads the dynamic linker off the (arch, abi) pair and the float ABI off
    // the abi alone, so an ABI mapped to `.android` where `.androideabi`
    // belongs compiles, configures, and asks for `/system/bin/linker64` on a
    // 32-bit ARM CPU — or links nothing at all. Nothing in this package's own
    // gates would notice: the paths are right either way.
    try testing.expectEqual(Target.Abi.androideabi, Abi.armeabi_v7a.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.arm64_v8a.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.riscv64.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.x86.zigAbi());
    try testing.expectEqual(Target.Abi.android, Abi.x86_64.zigAbi());

    // Both spellings must be ones Zig itself calls Android, or the libc that
    // reaches the link line is not bionic's.
    for (std.enums.values(Abi)) |a| {
        try testing.expect(a.zigAbi().isAndroid());
    }

    // The consequence, not the spelling: 32-bit ARM is soft-float under
    // `.androideabi` and every other Android ABI here is hard-float. Pinning
    // the pair to a property the compiler actually derives is what makes the
    // table hard to edit past.
    try testing.expectEqual(Target.Abi.Float.soft, Abi.armeabi_v7a.zigAbi().float());
    try testing.expectEqual(Target.Abi.Float.hard, Abi.arm64_v8a.zigAbi().float());
    try testing.expectEqual(Target.Abi.Float.hard, Abi.riscv64.zigAbi().float());
    try testing.expectEqual(Target.Abi.Float.hard, Abi.x86.zigAbi().float());
    try testing.expectEqual(Target.Abi.Float.hard, Abi.x86_64.zigAbi().float());
}

test "an ABI name resolves back to exactly one ABI, and a near miss to none" {
    // The defect this catches: `Abi.name` and `Abi.fromName` are two halves of
    // one mapping, and a table where only one of them moved still compiles and
    // still looks right on the page. Two tags sharing a name makes the reverse
    // lookup answer with the first for both, so `-Dabi=` selects an ABI the
    // caller did not name; a name spelled wrongly still leaves the ABI with a
    // correct triple. Neither is visible anywhere else in this package.
    for (std.enums.values(Abi)) |a| {
        const found = Abi.fromName(a.name()) orelse {
            std.debug.print("no ABI has the name '{s}'\n", .{a.name()});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(a, found);
    }

    // A name that is a near miss of a real one resolves to nothing, rather
    // than to a prefix match, an ignoring case, or a trailing separator. The
    // third and fourth entries are the Zig tags, which the NDK never writes as
    // an ABI name: the enum spells `-` as `_`, so accepting one is exactly the
    // `@tagName`-instead-of-`name` mistake this catches.
    for ([_][]const u8{
        "arm64-v8",
        "ARM64-V8A",
        "arm64_v8a",
        "armeabi_v7a",
        "armeabi-v7a/",
        " arm64-v8a",
        "x86-64",
        "",
    }) |name| {
        try testing.expect(Abi.fromName(name) == null);
    }
}

// ---------------------------------------------------------------------------
// 2. The libc paths file
// ---------------------------------------------------------------------------

test "the six-field libc paths file built from a resolved sysroot parses, and matches Zig's own bytes" {
    // This is the load-bearing test in the package.
    // `std.zig.LibCInstallation.parse` rejects the file outright unless all six
    // keys are present, and rejects it again for a non-Darwin target whose
    // `crt_dir` is empty. Neither is a subtle failure: the consumer's build
    // stops with "missing field" at the link step. A key that Android never
    // uses — `msvc_lib_dir`, `kernel32_lib_dir`, `gcc_dir` — still has to be
    // written, present and valueless, which is the one mistake that survives
    // every gate in this package because nothing here links anything.
    //
    // The bytes come from `LibcPaths`, the package's one renderer, and are then
    // compared whole against `LibCInstallation.render` for the same six values
    // — which is what Zig itself writes for them. A dropped key, a reordered
    // key, or a value where an Android file wants none, is then a byte
    // difference caught here rather than a link failure on somebody else's
    // machine. `LibcPaths.render` is byte-for-byte `LibCInstallation.render`,
    // which is why the comparison can be of whole documents.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();

    const tree = try createTree(&fixture, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{"35"});
    const install = try Ndk.open(gpa, testing.io, fixture.root, .linux_x86_64);

    try testing.expectEqual(Ndk.Shape.direct, install.shape);
    try testing.expectEqualStrings(fixture.root, install.root_path);
    // The sysroot is the one path a consumer turns into a libc paths file, so
    // it is compared whole rather than by a suffix that would tolerate a
    // directory in between.
    const expected_sysroot = try path.join(gpa, &.{
        fixture.root,
        "toolchains",
        "llvm",
        "prebuilt",
        "linux-x86_64",
        "sysroot",
    });
    try testing.expectEqualStrings(expected_sysroot, install.sysroot());

    const include_dir = try path.join(gpa, &.{ install.sysroot(), "usr", "include" });
    const crt_dir = try install.libcDirFor(gpa, testing.io, .arm64_v8a, 35);

    // `crt_dir` is the per-API-level directory, never the API-agnostic triple
    // directory above it: the CRT objects live one level down, and a file that
    // names the triple directory parses fine and then links nothing.
    try testing.expectEqualStrings(try path.join(gpa, &.{ tree, "35" }), crt_dir);

    // Rendered through the published renderer, not through a template written
    // here. The six-field format has one home; a second copy in a test is how
    // a second source of truth starts.
    var paths = try LibcPaths.forAndroid(gpa, include_dir, include_dir, crt_dir);
    defer paths.deinit(gpa);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try paths.render(&buffer.writer);
    const text = buffer.written();

    // `forAndroid` is the Android entry point, so the three platform-only
    // fields stay unset and `render` must write them present and valueless.
    try testing.expect(paths.msvc_lib_dir == null);
    try testing.expect(paths.kernel32_lib_dir == null);
    try testing.expect(paths.gcc_dir == null);

    const fields = std.meta.fields(std.zig.LibCInstallation);
    try testing.expectEqual(@as(usize, 6), fields.len);

    const lines = try keyLines(gpa, text);
    try testing.expectEqual(fields.len, lines.len);

    const values = [6][]const u8{ include_dir, include_dir, crt_dir, "", "", "" };
    // `inline for`, not `for`: `std.meta.fields` yields
    // `builtin.Type.StructField`, whose `type` member exists only at comptime,
    // so a runtime loop cannot even copy one element out of the slice. The key
    // names are read from the compiler's own declaration of the struct, which
    // is what keeps this file from carrying a second list of the six names.
    inline for (fields, 0..) |field, i| {
        try testing.expectEqualStrings(
            try std.fmt.allocPrint(gpa, "{s}={s}", .{ field.name, values[i] }),
            lines[i],
        );
    }

    // Line terminators, not just content: a generated file that lost its
    // trailing newline still parses here, and the next tool to read it may not
    // be so forgiving.
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);

    // Round-trip through the parser that will read it in the consumer's build.
    const target = try androidTarget();
    const parsed = try parsePathsFile(gpa, text, &target);

    try testing.expectEqualStrings(include_dir, parsed.include_dir.?);
    try testing.expectEqualStrings(include_dir, parsed.sys_include_dir.?);
    try testing.expectEqualStrings(crt_dir, parsed.crt_dir.?);

    // An empty value parses to null. The file still carries the key, which is
    // the whole reason the three Windows and Haiku fields are written at all.
    try testing.expect(parsed.msvc_lib_dir == null);
    try testing.expect(parsed.kernel32_lib_dir == null);
    try testing.expect(parsed.gcc_dir == null);

    // And the whole document is what Zig itself would have written for those
    // values, comment header included.
    var zig_rendered: std.Io.Writer.Allocating = .init(gpa);
    defer zig_rendered.deinit();
    try parsed.render(&zig_rendered.writer);
    try testing.expectEqualStrings(zig_rendered.written(), text);
}

// ---------------------------------------------------------------------------
// 3. Discovery: order, the explicit pin, and candidate trimming
// ---------------------------------------------------------------------------

test "a present build option wins, and the three variables are read in the documented order" {
    // The defect this catches: the order is a promise about which NDK a build
    // silently uses. Swap two entries and a machine with an inherited
    // `ANDROID_NDK_HOME` starts linking a different libc with no diagnostic
    // anywhere, because every candidate is a valid unpacked NDK and every
    // path resolves. That is the failure mode the refusal message in
    // build.zig exists to make visible, and it only works if the order is
    // pinned.
    //
    // `Ndk.find` takes its environment as a `*const Environ.Map` parameter, so
    // this test injects a map. Nothing here reads or writes the process
    // environment, which is what makes the test safe to run beside others.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Four trees carrying four different triples, so the winner is identified
    // by what it actually resolved and not merely by the string passed in.
    var option = try Fixture.init(gpa);
    defer option.deinit();
    var home = try Fixture.init(gpa);
    defer home.deinit();
    var root = try Fixture.init(gpa);
    defer root.deinit();
    var bare = try Fixture.init(gpa);
    defer bare.deinit();

    const host = (try findHostTag()) orelse {
        // Google publishes no NDK package for this host, so `find` can only
        // refuse. It must say so before it reads a single candidate, and it
        // must not fall through to `NdkNotFound`, which would blame a path the
        // user configured correctly.
        const empty = try environOf(gpa, &[_][2][]const u8{});
        try testing.expectError(error.UnsupportedHost, Ndk.find(gpa, testing.io, null, &empty));
        return;
    };

    _ = try createTree(&option, gpa, host, .direct, .riscv64, &[_][]const u8{});
    _ = try createTree(&home, gpa, host, .direct, .x86, &.{"21"});
    _ = try createTree(&root, gpa, host, .direct, .x86_64, &.{"21"});
    _ = try createTree(&bare, gpa, host, .direct, .arm64_v8a, &.{"21"});

    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_HOME", home.root },
            .{ "ANDROID_NDK_ROOT", root.root },
            .{ "ANDROID_NDK", bare.root },
        });
        // The explicit build option outranks all three variables.
        const explicit = try Ndk.find(gpa, testing.io, option.root, &environ);
        try testing.expectEqualStrings(option.root, explicit.root_path);
        // And the variables are consulted in the documented order.
        const from_home = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(home.root, from_home.root_path);
    }
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_ROOT", root.root },
            .{ "ANDROID_NDK", bare.root },
        });
        const from_root = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(root.root, from_root.root_path);
    }
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK", bare.root },
        });
        const from_bare = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(bare.root, from_bare.root_path);
    }

    // First hit wins, and a later candidate is never read. A variable pointing
    // at a directory that exists but holds no sysroot stops discovery with
    // `NotAnNdk` when it is reached, so a build that returns the explicit
    // option instead proves the walk stopped where the contract says it stops.
    {
        var wrong = try Fixture.init(gpa);
        defer wrong.deinit();
        _ = try mkdir(&wrong, gpa, &.{"meta"});

        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_HOME", wrong.root },
            .{ "ANDROID_NDK_ROOT", root.root },
            .{ "ANDROID_NDK", bare.root },
        });
        const found = try Ndk.find(gpa, testing.io, option.root, &environ);
        try testing.expectEqualStrings(option.root, found.root_path);
    }

    // An absent IMPLICIT candidate is skipped rather than fatal, so an
    // unset-but-stale variable hands the turn to the next source instead of
    // ending discovery. The same path named as `-Dndk` is fatal instead, and
    // that half of the rule is pinned by the next test, which exists to make
    // the difference impossible to miss.
    {
        var stale = try Fixture.init(gpa);
        defer stale.deinit();
        const missing = try path.join(gpa, &.{ stale.root, "not-installed" });

        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_HOME", missing },
            .{ "ANDROID_NDK_ROOT", root.root },
        });
        const from_root = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(root.root, from_root.root_path);
    }
}

test "an absent explicit -Dndk stops the walk and an absent variable does not" {
    // The defect this catches: an explicit `-Dndk` and an inherited
    // `ANDROID_NDK_HOME` naming the SAME missing path used to have the same
    // answer, because both were "not on disk" and neither was fatal. The
    // option the user typed on purpose was dropped without a word and the
    // build linked whatever libc the shell happened to export — the whole
    // point of naming a path explicitly is that it is a pin, not a preference.
    //
    // Two `find` calls, one absent path, one environment map. Nothing else
    // differs between them: same host, same scratch trees, same bytes. Only
    // the ROLE of the missing path differs, and the roles answer differently.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const host = (try findHostTag()) orelse {
        const empty = try environOf(gpa, &[_][2][]const u8{});
        try testing.expectError(error.UnsupportedHost, Ndk.find(gpa, testing.io, null, &empty));
        return;
    };

    var scratch = try Fixture.init(gpa);
    defer scratch.deinit();
    var option = try Fixture.init(gpa);
    defer option.deinit();

    _ = try createTree(&option, gpa, host, .direct, .x86_64, &.{"21"});
    const missing = try path.join(gpa, &.{ scratch.root, "not-installed" });

    const environ = try environOf(gpa, &.{
        .{ "ANDROID_NDK_HOME", missing },
        .{ "ANDROID_NDK_ROOT", option.root },
    });

    // Named as the build option. There is nothing behind it, so the walk stops
    // here rather than handing back an NDK the caller never asked for.
    try testing.expectError(error.NdkNotFound, Ndk.find(gpa, testing.io, missing, &environ));

    // Named as a variable nobody necessarily authored for this build. The
    // walk moves on and the next source answers.
    const from_root = try Ndk.find(gpa, testing.io, null, &environ);
    try testing.expectEqualStrings(option.root, from_root.root_path);

    // The pin holds with nothing else set, where the walk would otherwise end
    // in the same error for an unrelated reason.
    const empty = try environOf(gpa, &[_][2][]const u8{});
    try testing.expectError(error.NdkNotFound, Ndk.find(gpa, testing.io, missing, &empty));

    // An option that names nothing is not a pin. `-Dndk=` and a value that is
    // only whitespace are the same statement, and both are skipped the way an
    // unset variable is, because refusing on them would break a caller whose
    // fallback the walk can satisfy.
    try testing.expectEqualStrings(
        option.root,
        (try Ndk.find(gpa, testing.io, "", &environ)).root_path,
    );
    try testing.expectEqualStrings(
        option.root,
        (try Ndk.find(gpa, testing.io, " \t\r\n", &environ)).root_path,
    );
}

test "a candidate is trimmed of trailing CR, LF and surrounding whitespace before probing" {
    // The defect this catches: a value that came out of a file rather than a
    // command line carries its terminator with it, and a path with one byte
    // of `\n` on the end is a path that is not on disk. Untrimmed, the walk
    // treats the real NDK as absent and answers from a source the caller never
    // named — for an explicit candidate that is a build linking a different
    // libc over a stray newline in `.env`.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const host = (try findHostTag()) orelse {
        const empty = try environOf(gpa, &[_][2][]const u8{});
        try testing.expectError(error.UnsupportedHost, Ndk.find(gpa, testing.io, null, &empty));
        return;
    };

    var trailing_lf = try Fixture.init(gpa);
    defer trailing_lf.deinit();
    var trailing_crlf = try Fixture.init(gpa);
    defer trailing_crlf.deinit();
    var padded = try Fixture.init(gpa);
    defer padded.deinit();

    _ = try createTree(&trailing_lf, gpa, host, .direct, .x86, &.{"21"});
    _ = try createTree(&trailing_crlf, gpa, host, .direct, .x86_64, &.{"21"});
    _ = try createTree(&padded, gpa, host, .direct, .arm64_v8a, &.{"21"});

    // A trailing LF, which is what a `.env` file and a Makefile both leave
    // behind. Probed as an implicit candidate...
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_HOME", try std.fmt.allocPrint(gpa, "{s}\n", .{trailing_lf.root}) },
        });
        const found = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(trailing_lf.root, found.root_path);
    }

    // ...and a CRLF pair, which is what a file written on Windows leaves
    // behind. Both bytes go, not just the LF, so this fails a trim that
    // splits on one scalar.
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_ROOT", try std.fmt.allocPrint(gpa, "{s}\r\n", .{trailing_crlf.root}) },
        });
        const found = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(trailing_crlf.root, found.root_path);
    }

    // Surrounding spaces, which is what quoting a path inside a value in a
    // shell leaves behind. The result is the trimmed path, so `root_path` is
    // usable as-is and does not carry the padding into the sysroot path.
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK", try std.fmt.allocPrint(gpa, "  {s}  ", .{padded.root}) },
        });
        const found = try Ndk.find(gpa, testing.io, null, &environ);
        try testing.expectEqualStrings(padded.root, found.root_path);
    }

    // The build option is trimmed the same way, and a present-and-padded
    // candidate still outranks the variables — trimming does not demote it.
    {
        const environ = try environOf(gpa, &.{
            .{ "ANDROID_NDK_HOME", trailing_crlf.root },
        });
        const explicit = try std.fmt.allocPrint(gpa, "\t{s}\t\n", .{trailing_lf.root});
        const found = try Ndk.find(gpa, testing.io, explicit, &environ);
        try testing.expectEqualStrings(trailing_lf.root, found.root_path);
    }
}

// ---------------------------------------------------------------------------
// 4. Error paths
// ---------------------------------------------------------------------------

test "a candidate that is not on disk yields NdkNotFound" {
    // The defect this catches: `NotAnNdk` and `NdkNotFound` are different
    // problems with different fixes, and conflating them sends a user to
    // inspect an NDK that was never the problem. `Ndk.open` maps a missing
    // root onto `NotAnNdk` on purpose — it has nowhere else to go — so the
    // discovery walk reports that nothing was found at all.
    //
    // The walk reaches that answer on two different grounds, and telling them
    // apart is the contract. An absent EXPLICIT candidate stops the walk where
    // it stands, because the user named that path deliberately and a build
    // that quietly links a different NDK is worse than one that stops. An
    // absent IMPLICIT candidate does not stop it: the environment is
    // inherited rather than authored for this build, and a stale
    // `ANDROID_NDK_HOME` left over from an uninstall hands the turn to the
    // next source instead of ending discovery.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();
    const missing = try path.join(gpa, &.{ fixture.root, "not-installed" });

    const empty = try environOf(gpa, &[_][2][]const u8{});
    if ((try findHostTag()) == null) {
        try testing.expectError(error.UnsupportedHost, Ndk.find(gpa, testing.io, null, &empty));
        return;
    }

    // Nothing set anywhere.
    try testing.expectError(error.NdkNotFound, Ndk.find(gpa, testing.io, null, &empty));

    // Everything set, and none of it on disk.
    const environ = try environOf(gpa, &.{
        .{ "ANDROID_NDK_HOME", missing },
        .{ "ANDROID_NDK_ROOT", missing },
        .{ "ANDROID_NDK", missing },
    });
    try testing.expectError(error.NdkNotFound, Ndk.find(gpa, testing.io, null, &environ));
    // The same absent path as `-Dndk`, with three valid-looking siblings
    // behind it that the walk is not allowed to reach.
    try testing.expectError(error.NdkNotFound, Ndk.find(gpa, testing.io, missing, &environ));
}

test "a path that exists but holds no NDK yields NotAnNdk" {
    // The defect this catches: an SDK root, a wrapper's outer directory and a
    // toolchain for a different host all exist on disk and all mean the same
    // thing to a caller — this is not an NDK — but they reach that answer by
    // different routes, and a resolver that gets one of them wrong blames the
    // user's configuration for a path they configured correctly.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // An SDK root: real, with NDK metadata, and no toolchain of its own.
    {
        var sdk = try Fixture.init(gpa);
        defer sdk.deinit();
        _ = try mkdir(&sdk, gpa, &.{"meta"});
        try Dir.cwd().writeFile(testing.io, .{
            .sub_path = try path.join(gpa, &.{ sdk.root, "meta", "abis.json" }),
            .data = "{}\n",
        });

        try testing.expectError(error.NotAnNdk, Ndk.open(gpa, testing.io, sdk.root, .linux_x86_64));
    }

    // A wrapper's outer directory: `bin/` and `libexec/` and no NDK anywhere,
    // which is the shape a caller most plausibly has in hand.
    {
        var wrapper = try Fixture.init(gpa);
        defer wrapper.deinit();
        _ = try mkdir(&wrapper, gpa, &.{"bin"});

        try testing.expectError(error.NotAnNdk, Ndk.open(gpa, testing.io, wrapper.root, .linux_x86_64));
    }

    // A toolchain is present, but for a host tag this machine did not ask for.
    // Reporting `NotAnNdk` here is right: the caller did name a real NDK, and
    // the only wrong thing about it is the host it was resolved against.
    {
        var other_host = try Fixture.init(gpa);
        defer other_host.deinit();
        _ = try createTree(&other_host, gpa, .darwin_x86_64, .direct, .arm64_v8a, &.{"35"});

        try testing.expectError(error.NotAnNdk, Ndk.open(gpa, testing.io, other_host.root, .linux_x86_64));
    }

    // A path that is not there at all.
    {
        var absent = try Fixture.init(gpa);
        defer absent.deinit();
        const missing = try path.join(gpa, &.{ absent.root, "not-installed" });

        try testing.expectError(error.NotAnNdk, Ndk.open(gpa, testing.io, missing, .linux_x86_64));
    }
}

test "an ABI the tree does not carry yields UnsupportedAbi" {
    // The defect this catches: `UnsupportedAbi` and `ApiLevelUnavailable` are
    // told apart by whether `usr/lib/<triple>` exists at all, and swapping the
    // two checks turns a clear "this NDK does not ship that ABI" into a
    // confusing "pick a level", with the caller left hunting through API
    // levels for an ABI problem.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();
    _ = try createTree(&fixture, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{ "21", "35" });
    const install = try Ndk.open(gpa, testing.io, fixture.root, .linux_x86_64);

    // Every ABI except the one the tree carries.
    for ([_]Abi{ .armeabi_v7a, .riscv64, .x86, .x86_64 }) |abi| {
        try testing.expectError(
            error.UnsupportedAbi,
            install.libcDirFor(gpa, testing.io, abi, Abi.arm64_v8a.minApiLevel()),
        );
        try testing.expectError(error.UnsupportedAbi, install.apiLevelsFor(gpa, testing.io, abi));
    }

    // The carried ABI still resolves, so the refusals above are about the ABI
    // and not about the tree being malformed.
    const levels = try install.apiLevelsFor(gpa, testing.io, .arm64_v8a);
    try testing.expectEqualSlices(u32, &.{ 21, 35 }, levels);
}

test "an API level the tree does not carry yields ApiLevelUnavailable" {
    // The defect this catches: `libcDirFor` produces the value a libc paths
    // file carries as `crt_dir`, and Zig's ELF linker turns that into a `-L`.
    // Handing back a path for a level that is not in the sysroot produces a
    // file that parses cleanly and then cannot find `crtbegin_dynamic.o`, which
    // reads as a broken NDK rather than as a wrong `-Dapi=`.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();
    const tree = try createTree(&fixture, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{ "21", "35" });
    const install = try Ndk.open(gpa, testing.io, fixture.root, .linux_x86_64);

    // 34 sits between two shipped levels, so it cannot be present by accident.
    try testing.expectError(
        error.ApiLevelUnavailable,
        install.libcDirFor(gpa, testing.io, .arm64_v8a, 34),
    );
    // 36 is above anything r29 declares.
    try testing.expectError(
        error.ApiLevelUnavailable,
        install.libcDirFor(gpa, testing.io, .arm64_v8a, 36),
    );

    // A shipped level resolves to its own directory, one level below the
    // triple directory.
    const crt_dir = try install.libcDirFor(gpa, testing.io, .arm64_v8a, 35);
    try testing.expectEqualStrings(try path.join(gpa, &.{ tree, "35" }), crt_dir);

    // The hazard the ABI table's high floor exists for. Zig resolves a bare
    // `-Dtarget=riscv64-linux-android` to API 29, and r29 ships no
    // `usr/lib/riscv64-linux-android/29`. Both halves are pinned, so a floor
    // that moves and a tree that changes cannot disagree quietly.
    var riscv = try Fixture.init(gpa);
    defer riscv.deinit();
    _ = try createTree(&riscv, gpa, .linux_x86_64, .direct, .riscv64, &.{"35"});
    const riscv_ndk = try Ndk.open(gpa, testing.io, riscv.root, .linux_x86_64);

    try testing.expectEqual(@as(u32, 35), Abi.riscv64.minApiLevel());
    try testing.expectError(
        error.ApiLevelUnavailable,
        riscv_ndk.libcDirFor(gpa, testing.io, .riscv64, 29),
    );
}

test "a host with no published NDK package yields UnsupportedHost" {
    // The defect this catches: reporting `NotAnNdk` for a host Google publishes
    // no package for. That error blames a path the user configured correctly,
    // and no `-Dndk` value can fix it, so the refusal sends the caller looking
    // in the wrong place. The distinction has to be held on every host, not
    // only on the one this suite happens to run on today.
    const refused = [_][]const u8{
        "aarch64-linux",
        "riscv64-linux",
        "x86-linux",
        "x86-windows",
        "aarch64-windows",
        "x86_64-freebsd",
    };
    for (refused) |arch_os| {
        const target = try std.zig.system.resolveTargetQuery(
            testing.io,
            try Target.Query.parse(.{ .arch_os_abi = arch_os }),
        );
        try testing.expectError(error.UnsupportedHost, Ndk.hostTag(target));
    }

    // The hosts that are served, so the refusals above are a property of the
    // table and not of the query parser.
    const served = [_]struct { arch_os: []const u8, want: HostTag }{
        .{ .arch_os = "x86_64-linux", .want = .linux_x86_64 },
        .{ .arch_os = "x86_64-macos", .want = .darwin_x86_64 },
        // Apple Silicon runs the darwin-x86_64 package under Rosetta, so it is
        // served even though Google never emits a darwin-arm64 package.
        .{ .arch_os = "aarch64-macos", .want = .darwin_x86_64 },
        .{ .arch_os = "x86_64-windows", .want = .windows_x86_64 },
    };
    for (served) |entry| {
        const target = try std.zig.system.resolveTargetQuery(
            testing.io,
            try Target.Query.parse(.{ .arch_os_abi = entry.arch_os }),
        );
        try testing.expectEqual(entry.want, try Ndk.hostTag(target));
    }
}

test "source.properties that names no revision yields VersionUnreadable, and absence yields nothing" {
    // The defect this catches: an unreadable version read as a usable NDK with
    // a version, or as a fatal error. A repackaged NDK need not carry the file
    // at all, and an unknown version never blocks a build; a file that is
    // present but unparsable has to be reported rather than silently treated as
    // absent, or a caller pinning against `29.0.14206865` proceeds without
    // knowing which NDK it was handed.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();
    _ = try createTree(&fixture, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{"35"});
    const install = try Ndk.open(gpa, testing.io, fixture.root, .linux_x86_64);

    // Absent is legal and leaves the version unknown.
    try testing.expect(try install.readVersion(gpa, testing.io) == null);

    const properties = try path.join(gpa, &.{ fixture.root, "source.properties" });

    // Present but carrying no `Pkg.Revision`.
    try Dir.cwd().writeFile(testing.io, .{
        .sub_path = properties,
        .data = "Pkg.Desc = Android NDK\nPkg.ReleaseName = r29\n",
    });
    try testing.expectError(error.VersionUnreadable, install.readVersion(gpa, testing.io));

    // Truncated: two components where three are required.
    try Dir.cwd().writeFile(testing.io, .{
        .sub_path = properties,
        .data = "Pkg.Revision = 29.0\n",
    });
    try testing.expectError(error.VersionUnreadable, install.readVersion(gpa, testing.io));

    // The real thing parses, and the version reaches the caller.
    try Dir.cwd().writeFile(testing.io, .{
        .sub_path = properties,
        .data = "Pkg.Desc = Android NDK\nPkg.Revision = 29.0.14206865\nPkg.ReleaseName = r29\n",
    });
    const version = (try install.readVersion(gpa, testing.io)).?;
    try testing.expectEqual(@as(u32, 29), version.major);
    try testing.expectEqual(@as(u32, 0), version.minor);
    try testing.expectEqual(@as(u32, 14206865), version.patch);
}

// ---------------------------------------------------------------------------
// 5. Both on-disk layouts
// ---------------------------------------------------------------------------

test "both on-disk layouts resolve, and both describe the same sysroot" {
    // The defect this catches: a resolver that probes only the direct shape.
    // Every other assertion in this file keeps passing, and every Nix user
    // fails, because nixpkgs' `androidenv` puts the NDK at
    // `<root>/libexec/android-sdk/ndk-bundle` and the root the caller was
    // handed holds no NDK at all. The error they see is `NotAnNdk`, which
    // points at their configuration rather than at the shape.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var direct = try Fixture.init(gpa);
    defer direct.deinit();
    var bundle = try Fixture.init(gpa);
    defer bundle.deinit();

    const direct_lib = try createTree(&direct, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{"35"});
    const bundle_lib = try createTree(&bundle, gpa, .linux_x86_64, .ndk_bundle, .arm64_v8a, &.{"35"});

    const from_direct = try Ndk.open(gpa, testing.io, direct.root, .linux_x86_64);
    const from_bundle = try Ndk.open(gpa, testing.io, bundle.root, .linux_x86_64);

    try testing.expectEqual(Ndk.Shape.direct, from_direct.shape);
    try testing.expectEqual(Ndk.Shape.ndk_bundle, from_bundle.shape);

    // The root each one reports is the directory that actually holds
    // `toolchains/`, which is the whole difference between the two shapes.
    try testing.expectEqualStrings(direct.root, from_direct.root_path);
    const bundle_root = try path.join(gpa, &.{ bundle.root, "libexec", "android-sdk", "ndk-bundle" });
    try testing.expectEqualStrings(bundle_root, from_bundle.root_path);

    // Past the NDK root the two are the same installation: the same sysroot
    // suffix, the same triple, the same API level. A caller that switched
    // packaging must not have to change anything downstream of discovery.
    const sysroot_suffix = try std.fmt.allocPrint(
        gpa,
        "toolchains{c}llvm{c}prebuilt{c}{s}{c}sysroot",
        .{ path.sep, path.sep, path.sep, HostTag.linux_x86_64.directoryName(), path.sep },
    );
    try testing.expect(std.mem.endsWith(u8, from_direct.sysroot(), sysroot_suffix));
    try testing.expect(std.mem.endsWith(u8, from_bundle.sysroot(), sysroot_suffix));

    const crt_suffix = try std.fmt.allocPrint(
        gpa,
        "usr{c}lib{c}{s}{c}35",
        .{ path.sep, path.sep, Abi.arm64_v8a.triple(), path.sep },
    );
    const direct_crt = try from_direct.libcDirFor(gpa, testing.io, .arm64_v8a, 35);
    const bundle_crt = try from_bundle.libcDirFor(gpa, testing.io, .arm64_v8a, 35);
    try testing.expect(std.mem.endsWith(u8, direct_crt, crt_suffix));
    try testing.expect(std.mem.endsWith(u8, bundle_crt, crt_suffix));

    // And each one found the tree that was actually built under it.
    try testing.expectEqualStrings(
        direct_lib,
        try path.join(gpa, &.{ from_direct.sysroot(), "usr", "lib", Abi.arm64_v8a.triple() }),
    );
    try testing.expectEqualStrings(
        bundle_lib,
        try path.join(gpa, &.{ from_bundle.sysroot(), "usr", "lib", Abi.arm64_v8a.triple() }),
    );

    // A root that holds both shapes answers with the direct one, because an
    // explicitly named root means the NDK is where it was pointed at.
    var both = try Fixture.init(gpa);
    defer both.deinit();
    _ = try createTree(&both, gpa, .linux_x86_64, .direct, .arm64_v8a, &.{"35"});
    _ = try createTree(&both, gpa, .linux_x86_64, .ndk_bundle, .arm64_v8a, &.{"35"});
    const from_both = try Ndk.open(gpa, testing.io, both.root, .linux_x86_64);
    try testing.expectEqual(Ndk.Shape.direct, from_both.shape);

    // Pointing at the inner directory of a bundled NDK resolves as the direct
    // shape: a caller who already knows where the NDK is should not have to
    // care which wrapper produced it.
    const from_inner = try Ndk.open(gpa, testing.io, bundle_root, .linux_x86_64);
    try testing.expectEqual(Ndk.Shape.direct, from_inner.shape);
}

// ---------------------------------------------------------------------------
// 6. API level enumeration
// ---------------------------------------------------------------------------

test "API levels enumerate as exactly the numeric directories, ascending" {
    // The defect this catches: a sysroot that grows a directory beside the API
    // levels. A future NDK revision may ship one, and an implementation that
    // assumed every child is a level either fails to parse at all or reports a
    // level that holds no `crtbegin_dynamic.o` — and the second failure
    // surfaces as a link error against a directory that genuinely exists, so
    // nothing about it looks like a bad API level.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit();
    const tree = try createTree(&fixture, gpa, .linux_x86_64, .direct, .arm64_v8a, &[_][]const u8{});

    // Unsorted and sparse, beside two names that are not levels at all. The
    // filesystem does not promise creation order either, so the sort has to be
    // the code's own work.
    for ([_][]const u8{ "35", "21", "30", "24", "debug", "llvm-strip" }) |entry| {
        _ = try mkdir(&fixture, gpa, &.{ tree, entry });
    }

    // A plain file whose name is a number. Only a directory names an API
    // level, so this must reach neither the enumeration nor the lookup.
    try Dir.cwd().writeFile(testing.io, .{
        .sub_path = try path.join(gpa, &.{ tree, "99" }),
        .data = "a stray file, not a directory\n",
    });

    const install = try Ndk.open(gpa, testing.io, fixture.root, .linux_x86_64);
    const levels = try install.apiLevelsFor(gpa, testing.io, .arm64_v8a);

    try testing.expectEqualSlices(u32, &.{ 21, 24, 30, 35 }, levels);

    // Every enumerated level resolves to the directory of the same name, so
    // the enumeration and the lookup agree on what a level is.
    for (levels) |level| {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{level}) catch unreachable;
        const expected = try path.join(gpa, &.{ tree, text });
        const crt_dir = try install.libcDirFor(gpa, testing.io, .arm64_v8a, level);
        try testing.expectEqualStrings(expected, crt_dir);
    }

    // A number that names no entry at all is refused rather than handed to the
    // linker, and `debug`, `llvm-strip` and the stray `99` file are all absent
    // from the enumeration above. Enumeration that invents a level and lookup
    // that invents a directory both end as a link error against a path that
    // looks entirely reasonable.
    //
    // The `99` case is the one the two halves of the library have to agree on:
    // `apiLevelsFor` filters on the entry's kind, `libcDirFor` on whether the
    // path is a directory, and if only one of the two asks, the other hands a
    // regular file to the libc paths file as `crt_dir`.
    try testing.expectError(
        error.ApiLevelUnavailable,
        install.libcDirFor(gpa, testing.io, .arm64_v8a, 99),
    );
    try testing.expectError(
        error.ApiLevelUnavailable,
        install.libcDirFor(gpa, testing.io, .arm64_v8a, 32),
    );
}
