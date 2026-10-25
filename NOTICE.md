# NOTICE

This package (`zig-ndk`) ships Zig source that *describes* an Android NDK
sysroot. It does not redistribute an NDK or any Google or LLVM artefact: this
tree contains no C code, NDK header, or part of a Google or LLVM binary. The NDK
is licensed by its publisher, is not vendored or copied here, and is read at
build time from wherever the consumer's NDK lives.

The Android NDK is not MIT-licensed, and nixpkgs does not classify it as free.
`devenv.nix` and the CI `link` job download and unpack NDK r29 under Google's
Android SDK Terms (<https://developer.android.com/studio/terms>), which are also
reproduced on the download page (<https://developer.android.com/ndk/downloads>).
Entering `devenv shell` therefore downloads a licence-restricted artefact. Read
those terms before you do. This repository takes no position on what they allow.

`zig-ndk` is MIT licensed by its author; see `LICENSE`. This file records the
one respect in which that is not the whole story: parts of this repository are
reproduced from the Zig standard library.

## Reproduced from Zig

* **Origin:** `lib/std/zig/LibCInstallation.zig` in the Zig 0.17.0
  distribution (tag `0.17.0`).
* **Copyright holder:** Zig contributors.
* **Licence:** MIT (Expat) — the same terms as Zig's own `LICENSE`, reproduced
  in full below.

### What was taken

Two fragments, each byte-for-byte identical to the file named above.

* **The `render` output block** in `src/libc_file.zig`, including its comments
  and expected-output test fixture.
* **One line of code** — `if (line.len == 0 or line[0] == '#') continue;` in
  `test/integration_test.zig`. It filters blank lines and `#` comments.

Nothing else from `lib/std` is reproduced here. The remaining long lines this
repository shares with `lib/std` — `self.* = undefined;`,
`const builtin = @import("builtin");`, `try testing.expectEqualStrings(` and
the like — are Zig idioms that carry no authorship.

### Why it is reproduced

`zig-ndk` writes the libc paths file that the Zig compiler reads back through
`std.zig.LibCInstallation.parse`. The property that makes the generated file
acceptable to that parser is byte-identity with the output of
`LibCInstallation.render`: same layout, same comment block, same field order,
same trailing newline. A file written here is meant to be indistinguishable
from one Zig writes itself. Any drift in the comment text or the field order
would break the contract the whole package rests on, so the text is
reproduced exactly rather than paraphrased.

The upstream copyright notice and permission follow.

---

The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.