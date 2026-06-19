# VMU filename hash — pure Nim, no KOS FFI.
#
# Provides hashFilename*, which is used by vmu.nim for all VMU file operations
# and is testable on the host without the KOS cross-toolchain.

# ── FROZEN FORMAT CONTRACT (v0.5.0, 2026-06-19) ──────────────────────────────
#
# Algorithm : FNV-1a 64-bit over the UTF-8 bytes of logicalPath
# Encoding  : base-36 (0-9, A-Z), 11 uppercase chars, big-endian digit order
# NUL safety: 11 chars + Nim string's implicit NUL = 12 bytes
#             ≤ vmu_dir_t.filename[12] (the on-disk field never includes a NUL)
# Collision  : accepted risk — 36^11 ≈ 1.32×10^17 combinations (effective space;
#              the 64-bit hash is truncated to 11 base-36 digits = ~57 bits);
#              negligible for <10 files
#
# ⚠ WARNING: Changing the algorithm or output length orphans all previously-written
# VMU files. A VMU holds only ~100KB of user saves; there is no migration path.
# NEVER modify this function without bumping the format version and providing
# a migration tool.
#
# Hash parity invariant: hashFilename(path) MUST return the identical string for
# write, read, delete, and exists operations given the same logicalPath argument.
# This is the ONLY place that maps configy logical paths to VMU filenames.

proc hashFilename*(logicalPath: string): string =
  ## Maps a configy logical path to an 11-char uppercase base-36 VMU filename.
  ## Deterministic and case-sensitive: two paths differing only in case are distinct.
  ## See module header for the format contract and collision policy.
  const
    fnvOffset   = 14695981039346656037'u64
    fnvPrime    = 1099511628211'u64
    base36Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    outputLen   = 11
  var h = fnvOffset
  for c in logicalPath:
    h = h xor uint64(ord(c))
    h = h * fnvPrime
  result = newString(outputLen)
  var n = h
  for i in countdown(outputLen - 1, 0):
    result[i] = base36Chars[int(n mod 36)]
    n = n div 36
