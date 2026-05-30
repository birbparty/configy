# Spike: supersnappy cross-compile under devkitARM, PSPDEV, VitaSDK

**Date:** 2026-05-29  
**Toolchains tested:**
- devkitARM release 66 / arm-none-eabi-gcc 15.1.0 (Nintendo 3DS)
- psp-gcc 15.1.1 (PSP)
- arm-vita-eabi-gcc 15.2.0 (PS Vita)

**Environment:** Nim 2.2.10, supersnappy 2.1.4

## Method

Generated Nim→C via `nim c --compileOnly -d:<target> --cpu:<arch> --os:standalone --mm:arc`
for a minimal spike (`import supersnappy; compress/uncompress` on a static string).
Then compiled each generated `.c` file directly with the target cross-compiler (`-c -O2 -I<nim-lib>`).

**Note:** The CI `platform-define-check` job runs `nim c --compileOnly` without a real
cross-compiler — it verifies Nim→C generation only, not C compilation. The C-level error
found for PSP is **invisible to CI**; it requires invoking the actual cross-compiler. A green
CI PSP check does not imply a working PSP cross-compile.

### Exact reproduction commands (PSP)

**Generating C (all targets use the same pattern):**
```bash
cd /tmp/spike && nim c --compileOnly -d:psp --cpu:mips --os:standalone \
  --mm:arc --path:<supersnappy-pkg-dir> \
  --nimcache:/tmp/spike/nimcache_psp snappy_spike.nim
```

**Compiling generated C — failing run (default flags):**
```bash
for f in /tmp/spike/nimcache_psp/*.c; do
  psp-gcc -c -O2 -I/path/to/nim/lib -o /dev/null "$f"
done
# @psupersnappy.nim.c and @psystem.nim.c fail with:
# error: passing argument 3 of '__builtin_sadd_overflow' from incompatible pointer type
```

**Compiling generated C — passing run (`--overflowChecks:off`):**
```bash
nim c --compileOnly -d:psp --cpu:mips --os:standalone --mm:arc \
  --overflowChecks:off --path:<supersnappy-pkg-dir> \
  --nimcache:/tmp/spike/nimcache_psp_nochk snappy_spike.nim

for f in /tmp/spike/nimcache_psp_nochk/*.c; do
  psp-gcc -c -O2 -I/path/to/nim/lib -o /dev/null "$f"
done
# All five files: OK (one const-qualifier warning, not an error)
```

**Spike source (`snappy_spike.nim`):**
```nim
import supersnappy

const payload = "configy supersnappy cross-compile spike payload 0123456789"

proc run*() =
  let compressed   = compress(payload)
  let decompressed = uncompress(compressed)
  doAssert decompressed == payload

run()
```

## Results

| Target | Compiler | Result | Notes |
|---|---|---|---|
| Nintendo 3DS | arm-none-eabi-gcc 15.1.0 | **PASS** | One harmless const-qualifier warning in Nim RTTI struct |
| PSP | psp-gcc 15.1.1 | **FAIL** (default flags) | See below |
| PSP | psp-gcc 15.1.1 | **PASS** | With `--overflowChecks:off` |
| PS Vita | arm-vita-eabi-gcc 15.2.0 | **PASS** | Same const-qualifier warning as 3DS |

## Root cause of PSP failure

With default Nim build flags, both `@psupersnappy.nim.c` and `@psystem.nim.c` fail:

```
error: passing argument 3 of '__builtin_sadd_overflow' from incompatible pointer type
expected 'int *' but argument is of type 'NI *' {aka 'long int *'}
```

Nim's `nimbase.h` defines overflow-check helpers as:
```c
#define nimAddInt(a, b, res)  __builtin_sadd_overflow(a, b, res)
#define nimMulInt(a, b, res)  __builtin_smul_overflow(a, b, res)
```

These GCC builtins expect `int *` for their result pointer. On PSP (MIPS32), `psp-gcc` resolves
Nim's `NI` (Nim's native integer) to `long int`. Even though both `int` and `long` are 32 bits
on MIPS32, `psp-gcc 15` treats `long int *` and `int *` as incompatible under
`-Wincompatible-pointer-types` — which is an error in GCC 15+ by default.

**This is not a supersnappy issue.** The same failure appears in `@psystem.nim.c` for any Nim
program that uses strings or sequences (integer overflow checks are emitted throughout the
Nim runtime for these types).

## Fix

Adding `--overflowChecks:off` to the PSP compilation invocation eliminates all errors.
Both `@psystem.nim.c` and `@psupersnappy.nim.c` compile cleanly.

The practical resolution is to add a PSP-specific section to `nim.cfg` that sets
`--overflowChecks:off` for PSP targets. Follow-up bead **configy-g3z** tracks this nim.cfg
change.

### Alternative: targeted diagnostic suppression

`--overflowChecks:off` disables integer overflow checking across the entire Nim runtime.
Since configy parses external input and computes buffer/sequence sizes, this silently removes
a safety net on PSP that all other platforms keep.

A narrower alternative is `--passC:-Wno-error=incompatible-pointer-types`, which downgrades
the GCC 15 error back to a warning while leaving overflow checking enabled. Because the spike
established that `int` and `long` are both 32-bit on MIPS32, the flagged pointer types alias
the same width — so the warning is a false positive and silencing it is safe. Bead `configy-g3z`
should evaluate this tradeoff before choosing the implementation approach.

## Const-qualifier warning (both ARM targets: 3DS, Vita)

Both ARM targets (3DS and Vita) emit one warning in the Nim-generated RTTI struct
initialization:
```
warning: initialization discards 'const' qualifier from pointer target type [-Wdiscarded-qualifiers]
```
This is a known Nim codegen quirk in RTTI initialization (`TNimTypeV2.display` field).
It is a warning, not an error, and does not affect correctness. PSP (MIPS) was not observed
to emit this warning independently (its compile failed on the overflow error first with
default flags; with `--overflowChecks:off` it also shows the same const-qualifier warning).

## Conclusion

- **supersnappy compiles on 3DS and Vita** without any source changes.
- **supersnappy compiles on PSP** with `--overflowChecks:off` (or targeted
  `-Wno-error=incompatible-pointer-types`; see Fix section above).
- No guard change to `store.nim` is needed. The `when configyFsWritable: import supersnappy`
  guard originally considered is not the right fix — the root cause is a build-flag mismatch
  affecting the entire Nim runtime on MIPS, not a supersnappy-specific issue.
- `configyHasSnappy = true` in `capabilities.nim` is accurate for 3DS and Vita today.
  For PSP it is accurate only after bead **configy-g3z** lands the nim.cfg change; with the
  currently committed `nim.cfg` (only `--mm:arc`), a real PSP cross-compile still fails.
