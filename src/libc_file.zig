//! Renders an Android NDK sysroot into the libc paths file that Zig 0.16.0's
//! `std.zig.LibCInstallation.parse` reads.
//!
//! Zig 0.16.0 ships no bionic. `zig build-exe -target aarch64-linux-android`
//! links a freestanding binary, but the same command with `-lc` fails with
//! "unable to provide libc" until the compiler is handed a libc paths file
//! naming the NDK's headers and CRT objects. This module renders that file.
//!
//! The format is six `name=value` lines split on `\n`, with `#` starting a
//! comment. Six fields, all six mandatory.

const std = @import("std");

const Allocator = std.mem.Allocator;
const LibcPaths = @This();

/// The directory that holds `stdlib.h`.
///
/// On an Android sysroot this is `<sysroot>/usr/include`, which also holds
/// `sys/errno.h`; that is why `sys_include_dir` names the same directory.
/// An empty value makes `LibCInstallation.parse` reject the whole file.
/// Owned by the allocator given to `forAndroid`; released by `deinit`.
include_dir: []const u8,

/// The system-specific include directory: the one holding `sys/errno.h`, or
/// `vcruntime.h` on Windows.
///
/// Kept separate from `include_dir` because `LibCInstallation.parse` rejects
/// an empty `sys_include_dir` for every target, even where the two are the
/// same directory.
/// Owned by the allocator given to `forAndroid`; released by `deinit`.
sys_include_dir: []const u8,

/// The directory that holds `crt1.o` or `crt2.o`.
///
/// For Android this is `usr/lib/<triple>/<api-level>`, where the CRT objects
/// live and nowhere else: `crtbegin_dynamic.o`, `crtbegin_so.o`,
/// `crtbegin_static.o`, `crtend_android.o`, `crtend_so.o` and
/// `crt_pad_segment.o`, beside `libc.so`, `libm.so` and the `libc++.so` /
/// `libc++.a` linker scripts.
///
/// The API-agnostic archives are NOT there. `libc.a` and `libc++_shared.so`
/// are siblings of the numeric API directories, one level up in
/// `usr/lib/<triple>`. Verified by listing r29; `CONTRACT.md` D6 records it.
///
/// That is load-bearing: from this directory neither a static libc nor a
/// `libc++_shared` link is reachable, which is why the package's link gate
/// compiles with `.linkage = .dynamic` and the paths file carries no separate
/// library search path.
///
/// An empty value makes `LibCInstallation.parse` reject the whole file for
/// every non-Darwin target, Android included.
/// Owned by the allocator given to `forAndroid`; released by `deinit`.
crt_dir: []const u8,

/// The directory that holds `vcruntime.lib`. MSVC on Windows only.
///
/// Always `null` for Android, because bionic is not MSVC. `render` still
/// writes the key with an empty value: `LibCInstallation.parse` counts a key
/// only when it sees the line, so omitting it fails with "missing field" no
/// matter that Android has no use for it.
///
/// Borrowed, not owned: `forAndroid` leaves it `null`, a caller that sets it
/// sets it to memory it owns, and `deinit` does not free it.
msvc_lib_dir: ?[]const u8 = null,

/// The directory that holds `kernel32.lib`. MSVC on Windows only.
///
/// Always `null` for Android. Written present-but-empty by `render`, for the
/// same reason as `msvc_lib_dir`.
///
/// Borrowed, not owned: see `msvc_lib_dir`.
kernel32_lib_dir: ?[]const u8 = null,

/// The directory that holds `crtbeginS.o` and `crtendS.o`. Haiku only.
///
/// Always `null` for Android. Written present-but-empty by `render`, for the
/// same reason as `msvc_lib_dir`.
///
/// Borrowed, not owned: see `msvc_lib_dir`.
gcc_dir: ?[]const u8 = null,

/// Describes an Android sysroot, ready to be rendered.
///
/// The three paths this constructor takes are copied into the allocator passed
/// in and released by `deinit` with that same allocator, so a `LibcPaths`
/// outlives the strings it was built from. The three optional fields are left
/// `null` here and are borrowed when a caller sets them; `deinit` does not
/// free them.
pub fn forAndroid(
    gpa: Allocator,
    include_dir: []const u8,
    sys_include_dir: []const u8,
    crt_dir: []const u8,
) Allocator.Error!LibcPaths {
    const owned_include_dir = try gpa.dupe(u8, include_dir);
    errdefer gpa.free(owned_include_dir);
    const owned_sys_include_dir = try gpa.dupe(u8, sys_include_dir);
    errdefer gpa.free(owned_sys_include_dir);
    const owned_crt_dir = try gpa.dupe(u8, crt_dir);

    return .{
        .include_dir = owned_include_dir,
        .sys_include_dir = owned_sys_include_dir,
        .crt_dir = owned_crt_dir,
    };
}

/// Releases the three paths `forAndroid` copied and leaves `self` unusable.
///
/// Must be called with the allocator that was passed to `forAndroid`, and it
/// frees exactly what `forAndroid` copied — nothing else. `msvc_lib_dir`,
/// `kernel32_lib_dir` and `gcc_dir` are borrowed: `forAndroid` leaves them
/// `null`, a caller that sets one sets it to memory it owns, and `deinit` does
/// not touch it. That they are `null` for Android is a property of the
/// constructor, not of the type, so the guarantee here is about which fields
/// `deinit` frees and not about what those fields currently hold.
pub fn deinit(self: *LibcPaths, gpa: Allocator) void {
    gpa.free(self.include_dir);
    gpa.free(self.sys_include_dir);
    gpa.free(self.crt_dir);
    self.* = undefined;
}

/// Writes the six-field libc paths file that Zig reads.
///
/// The layout, the comment block, the field order and the trailing newline are
/// byte-for-byte those of `std.zig.LibCInstallation.render`, so a file written
/// here is indistinguishable from one Zig writes itself and reads back through
/// the same parser.
///
/// All six keys are always written. A `null` field becomes a bare `name=` with
/// an empty value, because `LibCInstallation.parse` requires every field to be
/// present and only then complains about empty ones. Dropping
/// `msvc_lib_dir`, `kernel32_lib_dir` or `gcc_dir` from an Android file is the
/// one mistake that fails even though Android needs none of them.
///
/// The bytes stay owned by `out`. Nothing is allocated here, and `out` is not
/// flushed.
pub fn render(self: LibcPaths, out: *std.Io.Writer) std.Io.Writer.Error!void {
    @setEvalBranchQuota(4000);
    try out.print(
        \\# The directory that contains `stdlib.h`.
        \\# On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        \\include_dir={s}
        \\
        \\# The system-specific include directory. May be the same as `include_dir`.
        \\# On Windows it's the directory that includes `vcruntime.h`.
        \\# On POSIX it's the directory that includes `sys/errno.h`.
        \\sys_include_dir={s}
        \\
        \\# The directory that contains `crt1.o` or `crt2.o`.
        \\# On POSIX, can be found with `cc -print-file-name=crt1.o`.
        \\# Not needed when targeting MacOS.
        \\crt_dir={s}
        \\
        \\# The directory that contains `vcruntime.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\msvc_lib_dir={s}
        \\
        \\# The directory that contains `kernel32.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\kernel32_lib_dir={s}
        \\
        \\# The directory that contains `crtbeginS.o` and `crtendS.o`
        \\# Only needed when targeting Haiku.
        \\gcc_dir={s}
        \\
    , .{
        self.include_dir,
        self.sys_include_dir,
        self.crt_dir,
        self.msvc_lib_dir orelse "",
        self.kernel32_lib_dir orelse "",
        self.gcc_dir orelse "",
    });
}

const testing = std.testing;

/// Renders an Android file into a freshly allocated buffer. Test helper.
fn renderAlloc(gpa: Allocator, include_dir: []const u8, crt_dir: []const u8) ![]u8 {
    var paths = try LibcPaths.forAndroid(gpa, include_dir, include_dir, crt_dir);
    defer paths.deinit(gpa);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    try paths.render(&buffer.writer);
    return buffer.toOwnedSlice();
}

/// Writes `text` to a scratch file and hands the path to `LibCInstallation.parse`.
///
/// The file lives in `std.testing`'s scratch directory, so a test never reads a
/// real NDK and never writes into the source tree. Whatever `gpa` hands back
/// belongs to `gpa`.
///
/// Pass an arena, not `testing.allocator`, when the parse is expected to
/// succeed. `LibCInstallation.deinit` is broken at this compiler line: `parse`
/// allocates each value with `dupeZ`, which takes one byte more than the value,
/// and stores it in a `?[]const u8` field that drops the sentinel, so `deinit`
/// frees a length one byte short of what was allocated and a bounds-checking
/// allocator rejects it. An arena sidesteps that without this test depending on
/// the upstream bug being fixed. The failure path inside `parse` is fine; its
/// `errdefer` holds the sentinel-typed slice and frees the right length.
/// Test helper.
fn parseRendered(
    gpa: Allocator,
    text: []const u8,
    target: *const std.Target,
) !std.zig.LibCInstallation {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "libc.cfg", .data = text });

    // std.testing puts the scratch directory at .zig-cache/tmp/<16 chars>, so
    // the joined path is short and bounded. Building it on the stack keeps
    // this helper allocation-free, which matters because two of its three
    // callers pass a leak-checked allocator.
    const sep = std.fs.path.sep;
    var path_buf: [128]u8 = undefined;
    const file_path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache{c}tmp{c}{s}{c}libc.cfg",
        .{ sep, sep, scratch.sub_path[0..], sep },
    );
    return std.zig.LibCInstallation.parse(gpa, testing.io, file_path, target);
}

/// The Android target `parse` is exercised against.
///
/// A real `aarch64-linux-android` target, so `parse` takes its non-Darwin
/// branch and enforces a non-empty `crt_dir`. Built through the resolver rather
/// than written as a literal, because `std.Target.Cpu` has no defaults.
fn androidTarget() !std.Target {
    return std.zig.system.resolveTargetQuery(
        testing.io,
        try std.Target.Query.parse(.{ .arch_os_abi = "aarch64-linux-android.29" }),
    );
}

test "forAndroid copies its three paths and leaves the platform trio unset" {
    const include = "/ndk/sysroot/usr/include";
    const crt = "/ndk/sysroot/usr/lib/aarch64-linux-android/35";

    var paths = try LibcPaths.forAndroid(testing.allocator, include, include, crt);
    defer paths.deinit(testing.allocator);

    try testing.expectEqualStrings(include, paths.include_dir);
    try testing.expectEqualStrings(include, paths.sys_include_dir);
    try testing.expectEqualStrings(crt, paths.crt_dir);

    // Owning, not borrowing: the copies are not the caller's literals.
    try testing.expect(paths.include_dir.ptr != include.ptr);
    try testing.expect(paths.crt_dir.ptr != crt.ptr);

    try testing.expect(paths.msvc_lib_dir == null);
    try testing.expect(paths.kernel32_lib_dir == null);
    try testing.expect(paths.gcc_dir == null);
}

test "deinit frees what forAndroid copied and never the three borrowed fields" {
    var paths = try LibcPaths.forAndroid(testing.allocator, "/inc", "/inc", "/crt");

    // String literals on purpose: a caller naming a Windows or Haiku directory
    // names a constant, so `deinit` freeing one of these would be a free of
    // memory this allocator never handed out. That is the assertion — it is
    // what fails, loudly and under this checking allocator, if a fourth free
    // ever grows into `deinit`.
    paths.msvc_lib_dir = "/win/vc/lib";
    paths.kernel32_lib_dir = "/win/sdk/lib";
    paths.gcc_dir = "/haiku/lib";

    // A non-null field must still reach the file: borrowed is a statement
    // about `deinit`, not about `render` silently dropping the value.
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    try paths.render(&buffer.writer);
    const text = try buffer.toOwnedSlice();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "\nmsvc_lib_dir=/win/vc/lib\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nkernel32_lib_dir=/win/sdk/lib\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "\ngcc_dir=/haiku/lib\n"));

    paths.deinit(testing.allocator);
}

test "render writes all six keys, empty for the three Android omits" {
    const text = try renderAlloc(
        testing.allocator,
        "/ndk/sysroot/usr/include",
        "/ndk/sysroot/usr/lib/aarch64-linux-android/35",
    );
    defer testing.allocator.free(text);

    // All six keys are present on their own line. Order and exact layout are
    // pinned byte-for-byte by the next test; this one only counts the keys the
    // parser refuses to do without. The leading newline keeps
    // "include_dir=" from matching inside "sys_include_dir=".
    for ([_][]const u8{
        "include_dir=",
        "sys_include_dir=",
        "crt_dir=",
        "msvc_lib_dir=",
        "kernel32_lib_dir=",
        "gcc_dir=",
    }) |key| {
        // The needle is the key at the start of a line, not a whole line: the
        // three valued keys are followed by their value, not by a newline.
        // The leading newline is what keeps "include_dir=" from matching
        // inside "sys_include_dir=".
        var needle_buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\n{s}", .{key});
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }

    // The three platform-specific keys are present with an empty value.
    try testing.expect(std.mem.indexOf(u8, text, "\nmsvc_lib_dir=\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nkernel32_lib_dir=\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "\ngcc_dir=\n"));

    // The three Android keys carry their values.
    try testing.expect(std.mem.indexOf(u8, text, "\ninclude_dir=/ndk/sysroot/usr/include\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nsys_include_dir=/ndk/sysroot/usr/include\n") != null);
    try testing.expect(
        std.mem.indexOf(u8, text, "\ncrt_dir=/ndk/sysroot/usr/lib/aarch64-linux-android/35\n") != null,
    );
}

test "render is byte-for-byte the layout Zig itself writes" {
    const text = try renderAlloc(
        testing.allocator,
        "/inc",
        "/crt",
    );
    defer testing.allocator.free(text);

    const expected =
        \\# The directory that contains `stdlib.h`.
        \\# On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        \\include_dir=/inc
        \\
        \\# The system-specific include directory. May be the same as `include_dir`.
        \\# On Windows it's the directory that includes `vcruntime.h`.
        \\# On POSIX it's the directory that includes `sys/errno.h`.
        \\sys_include_dir=/inc
        \\
        \\# The directory that contains `crt1.o` or `crt2.o`.
        \\# On POSIX, can be found with `cc -print-file-name=crt1.o`.
        \\# Not needed when targeting MacOS.
        \\crt_dir=/crt
        \\
        \\# The directory that contains `vcruntime.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\msvc_lib_dir=
        \\
        \\# The directory that contains `kernel32.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\kernel32_lib_dir=
        \\
        \\# The directory that contains `crtbeginS.o` and `crtendS.o`
        \\# Only needed when targeting Haiku.
        \\gcc_dir=
        \\
    ;
    try testing.expectEqualStrings(expected, text);
}

test "render output is accepted by the parser that will read it" {
    const include = "/ndk/sysroot/usr/include";
    const crt = "/ndk/sysroot/usr/lib/aarch64-linux-android/35";

    const text = try renderAlloc(testing.allocator, include, crt);
    defer testing.allocator.free(text);

    const target = try androidTarget();

    // An arena, because LibCInstallation.deinit miscounts; see parseRendered.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseRendered(arena.allocator(), text, &target);

    try testing.expectEqualStrings(include, parsed.include_dir.?);
    try testing.expectEqualStrings(include, parsed.sys_include_dir.?);
    try testing.expectEqualStrings(crt, parsed.crt_dir.?);

    // parse maps an empty value to null; the file still carries the key.
    try testing.expect(parsed.msvc_lib_dir == null);
    try testing.expect(parsed.kernel32_lib_dir == null);
    try testing.expect(parsed.gcc_dir == null);
}

// There is deliberately no test here that asserts `parse` REJECTS a
// malformed file. Every rejection path in `LibCInstallation.parse` calls
// `log.err` before it returns, and Zig's test runner fails a run that logged an
// error, so such a test cannot assert what it wants without also failing the
// gate. What that test would prove is std's rule, not this module's: the two
// obligations this module owns are covered above, namely that all six keys are
// emitted and that the result parses.
