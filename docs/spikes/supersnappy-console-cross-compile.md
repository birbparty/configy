# Spike: supersnappy cross-compile under devkitARM, PSPDEV, VitaSDK

**Date:** 2026-05-29  
**Toolchains tested:**
- devkitARM release 66 / arm-none-eabi-gcc 15.1.0 (Nintendo 3DS)
- psp-gcc 15.1.1 (PSP)
- arm-vita-eabi-gcc 15.2.0 (PS Vita)

## Method

Generated Nim→C via `nim c --compileOnly -d:<target> --cpu:<arch> --os:standalone --mm:arc`
for a minimal spike (`import supersnappy; compress/uncompress` on a static string).
Then compiled each generated `.c` file directly with the target cross-compiler (`-c -O2`).

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

The practical resolution is to add a `[PSP]` section to `nim.cfg` (or an equivalent
platform nim.cfg) that sets `--overflowChecks:off` for PSP targets. This is appropriate
for release console builds; development builds can re-enable it once the Nim MIPS NI
mapping is resolved upstream.

A follow-up bead (configy-psp-overflow) tracks the nim.cfg change.

## Const-qualifier warning (all ARM targets)

All three targets emit one warning in the Nim-generated RTTI struct initialization:
```
warning: initialization discards 'const' qualifier from pointer target type [-Wdiscarded-qualifiers]
```
This is a known Nim codegen quirk in RTTI initialization (`TNimTypeV2.display` field).
It is a warning, not an error, and does not affect correctness.

## Conclusion

- **supersnappy compiles on 3DS and Vita** without any source changes.
- **supersnappy compiles on PSP** with `--overflowChecks:off`.
- No guard change to `store.nim` is needed. The `when configyFsWritable: import supersnappy`
  guard originally considered is not the right fix — the root cause is a build-flag mismatch
  affecting the entire Nim runtime on MIPS, not a supersnappy-specific issue.
- `configyHasSnappy = true` in `capabilities.nim` remains accurate; all three console targets
  can compile supersnappy given correct build flags.
