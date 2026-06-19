import std/unittest
import configy/vmu_hash

# Host-runnable characterization tests for the VMU filename hash.
# No KOS cross-toolchain required — vmu_hash.nim is pure Nim.
# These pin the FROZEN FORMAT CONTRACT (v0.5.0) and must not be changed
# without also bumping the format version in vmu_hash.nim.

suite "hashFilename — format contract":
  test "output is always 11 chars":
    check hashFilename("/vmu/a1/testvendor/myapp/s.json").len == 11
    check hashFilename("x").len == 11
    check hashFilename("").len == 11

  test "output contains only 0-9 and A-Z (base-36 uppercase)":
    const validChars = {'0'..'9', 'A'..'Z'}
    let h = hashFilename("/vmu/a1/testvendor/myapp/s.json")
    for c in h:
      check c in validChars

  test "same path always produces the same hash (determinism)":
    let path = "/vmu/a1/testvendor/myapp/settings.json"
    check hashFilename(path) == hashFilename(path)

  test "write-read-delete-exists parity: identical string for all four ops":
    let path = "/vmu/a1/testvendor/myapp/config.json"
    let write  = hashFilename(path)
    let read   = hashFilename(path)
    let delete = hashFilename(path)
    let exists = hashFilename(path)
    check write == read
    check write == delete
    check write == exists

  test "different paths produce different hashes (basic collision resistance)":
    check hashFilename("/vmu/a1/testvendor/app1/s.json") !=
          hashFilename("/vmu/a1/testvendor/app2/s.json")
    check hashFilename("/vmu/a1/testvendor/myapp/a.json") !=
          hashFilename("/vmu/a1/testvendor/myapp/b.json")
    check hashFilename("/vmu/a1/vendor1/app/s.json") !=
          hashFilename("/vmu/a1/vendor2/app/s.json")

  test "case-sensitive: paths differing only in case are distinct":
    check hashFilename("/vmu/a1/testvendor/MyApp/s.json") !=
          hashFilename("/vmu/a1/testvendor/myapp/s.json")

suite "hashFilename — pinned values (v0.5.0 format contract)":
  # Specific output values are pinned here. If any of these fail, the algorithm
  # has changed and previously-written VMU files are now orphaned.
  # Update the format version and provide a migration tool before changing.
  test "known hash for dep-less configFile path":
    check hashFilename("/vmu/a1/testvendor/myapp/settings.json") == "256NZDL89TA"

  test "known hash for full (with-dep) configFile path":
    check hashFilename("/vmu/a1/testvendor/myapp/mylib/settings.json") == "B66Y8DMQ8OO"

  test "known hash for empty string (edge case)":
    check hashFilename("") == "NIIHZJ4UX45"
