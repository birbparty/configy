# KOS VMU API Catalog — Exact Signatures for vmu.nim

Sourced from `~/git/workspace/KallistiOS/kernel/arch/dreamcast/include/dc/` on 2026-06-19.
These are the APIs that `src/configy/vmu.nim` will bind via `{.importc.}`.

---

## Slot lookup — dc/maple.h

```c
/* Port A = 0, Unit 0 = main device (controller), Unit 1 = slot 1 (a1 = VMU) */
maple_device_t * maple_enum_dev(int p, int u);
/* Returns NULL if no device at (p, u). Never throws. */

/* Alternatively: get Nth device of a given function type */
maple_device_t * maple_enum_type(int n, uint32 func);
#define MAPLE_FUNC_MEMCARD  0x02000000
```

**For configy**: use `maple_enum_dev(0, 1)` — port 0, unit 1 — to get the VMU at slot a1.
This is a direct address lookup, faster and more deterministic than `maple_enum_type`.
Null-safe: returns `NULL` if no VMU inserted; `isPresent()` must check for NULL.

```c
/* maple_device_t — opaque in practice; we never dereference fields directly */
typedef struct maple_device {
    /* ... internal fields ... */
} maple_device_t;
```

---

## High-level VMU FS — dc/vmufs.h

**Use these, not the low-level vmufs_file_write/read (those require manual root/FAT/dir management).**

```c
/* Write a file. If VMUFS_OVERWRITE is set and fn exists, old file is deleted first (atomic). */
#define VMUFS_OVERWRITE  1
#define VMUFS_VMUGAME    2  /* not used by configy */
#define VMUFS_NOCOPY     4  /* not used by configy */
int vmufs_write(maple_device_t *dev, const char *fn, void *inbuf, int insize, int flags);
/* Returns: 0 on success, <0 on failure */

/* Read a file. Allocates *outbuf via malloc(); caller must free() with C free(), not Nim dealloc. */
int vmufs_read(maple_device_t *dev, const char *fn, void **outbuf, int *outsize);
/* Returns: 0 on success, <0 on failure. If <0, *outbuf is NOT allocated — do not free. */

/* Delete a file. */
int vmufs_delete(maple_device_t *dev, const char *fn);
/* Returns: 0 on success, -1 if not found, -2 on other failure */

/* Free block count (512 bytes each). Check BEFORE writing. */
int vmufs_free_blocks(maple_device_t *dev);
/* Returns: number of free 512-byte blocks. NEVER hard-code 200 — blk_cnt is runtime. */
```

**Filename constraint** (from `vmu_dir_t`):
```c
typedef struct {
    /* ... */
    char filename[12];  /* NO null terminator — exactly 12 chars, space-padded or truncated */
    /* ... */
} vmu_dir_t;
```
VMU filenames are at most **12 bytes**, no null terminator in the on-disk struct.
configy's hash must produce ≤12 uppercase ASCII chars.

**cstring NUL invariant**: `vmufs_write(fn: cstring)` uses the C string until a NUL byte.
The hash implementation MUST produce ≤11 chars so a 12th NUL byte fits, OR produce
exactly 12 chars and rely on KOS truncating to `min(strlen, 12)` — the latter is fragile
and relies on undocumented KOS behavior. **Recommended**: cap the hash to 11 chars to
guarantee NUL safety regardless of KOS version.

**Collision policy**: Two distinct logical paths can hash to the same ≤12-char name,
silently overwriting each other on a 128 KB device. The plan must specify one of:
- **Ignore** (accepted risk — document the collision probability given expected file counts)
- **Detect and error** — check `existsVmuFile(hash)` on write; if exists and hash matches
  a different logical path, raise `ConfigIOError("VMU filename collision")`
- **Detect and probe** — append a suffix and retry (complex, changes hash parity invariant)

For configy, **document as accepted risk** is appropriate: a typical deployment has
<10 config files, making a 12-char-uppercase-namespace collision negligibly unlikely.

**Low-level functions** (NOT used by configy directly — for reference only):
```c
/* These require pre-reading root/FAT/dir buffers — use vmufs_read/write/delete above */
int vmufs_file_read(maple_device_t *dev, uint16 *fat, vmu_dir_t *dirent, void *outbuf);
int vmufs_file_write(maple_device_t *dev, vmu_root_t *root, uint16 *fat, vmu_dir_t *dir,
                     vmu_dir_t *newdirent, void *filebuf, int size);
int vmufs_file_delete(vmu_root_t *root, uint16 *fat, vmu_dir_t *dir, const char *fn);
int vmufs_fat_free(vmu_root_t *root, uint16 *fat);  /* use vmufs_free_blocks instead */
```

---

## VMS Package — dc/vmu_pkg.h

**Required to make files visible in the BIOS memory manager.**

```c
typedef struct vmu_pkg {
    char        desc_short[20];     /* Short file description (space-padded) */
    char        desc_long[36];      /* Long file description (space-padded) */
    char        app_id[20];         /* Application ID (space-padded) */
    int         icon_cnt;           /* Number of icon frames (1 for static) */
    int         icon_anim_speed;    /* Animation speed (irrelevant for 1 frame) */
    int         eyecatch_type;      /* Use VMUPKG_EC_NONE (0) for configy */
    int         data_len;           /* Payload byte count (set to payload size) */
    uint16_t    icon_pal[16];       /* Icon palette — ARGB4444, 16 entries */
    uint8_t    *icon_data;          /* Icon bitmap — 512 bytes per frame (32x32 4bpp) */
    uint8_t    *eyecatch_data;      /* NULL when eyecatch_type = VMUPKG_EC_NONE */
    const uint8_t *data;            /* Payload bytes (compressed configy data) */
} vmu_pkg_t;

#define VMUPKG_EC_NONE  0   /* No eyecatch — use this for configy */

/* Build: convert vmu_pkg_t → flat byte array for writing.
   Allocates *dst via C malloc(); caller must c_free(*dst) after vmufs_write returns.
   src.data is BORROWED (caller still owns the payload buffer across this call).
   Returns: 0 on success, <0 on failure */
int vmu_pkg_build(vmu_pkg_t *src, uint8_t **dst, int *dst_size);

/* Parse: flat byte array → vmu_pkg_t (read path).
   pkg->data BORROWS a pointer into the source `data` buffer — it is NOT a copy.
   Do NOT free `data` until you have copied `pkg->data_len` bytes out of `pkg->data`.
   Returns: 0 on success, -1 on bad CRC */
int vmu_pkg_parse(uint8_t *data, size_t data_size, vmu_pkg_t *pkg);
```

**Icon requirements** (from `vmu_pkg_load_icon` docs):
- 32×32 pixels, 4bpp paletted
- ≤16 colors (≤15 with transparency)
- 512 bytes per frame (32*32/2 = 512)
- Single frame (icon_cnt=1) for a static icon
- `icon_pal[16]` entries in ARGB4444 format (uint16_t each)

---

## fs_vmu.h — VFS layer

The VFS mounts each VMU card at `/vmu/<port><unit>/`:
- Port A, Slot 1 → `/vmu/a1/`
- Port B, Slot 1 → `/vmu/b1/`

Standard libc file ops work (`open`/`read`/`write`/`close`) via this VFS.
**No subdirectories** — the VMU is a flat filesystem.

```c
/* Set header for an open fd (before close, to attach VMS metadata) */
static inline int fs_vmu_set_header(file_t fd, const vmu_pkg_t *pkg);

/* Set a default header for all new files (simpler alternative) */
static inline int fs_vmu_set_default_header(const vmu_pkg_t *pkg);
```

**Note for configy**: `vmufs_write` is preferred over raw fd I/O for simplicity. However,
`vmufs_write` writes **whatever bytes you give it verbatim** — it does NOT add a VMS header
automatically. For the file to be visible in the BIOS memory manager and parseable by
`vmu_pkg_parse` on read-back, the write path MUST run `vmu_pkg_build` first and pass the
resulting VMS-packaged buffer to `vmufs_write`. The `fs_vmu_set_header` / `fs_vmu_set_default_header`
functions are for the fd-based VFS path only and are `static inline` (no linkable symbol —
do not `importc` them; use `vmufs_write` + `vmu_pkg_build` instead).

---

## FFI Memory Ownership (CRITICAL — read before implementing)

Three KOS functions allocate C-heap memory that Nim must release with C `free`, not
`dealloc` or the GC. Wrong deallocation = crash or silent heap corruption.

```nim
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
```

### vmufs_read ownership

```nim
proc readVmuFile*(logicalPath: string): string =
  let dev = vmuSlotA1()
  if dev == nil: raise newException(ConfigIOError, "VMU not present")
  var outbuf: pointer = nil
  var outsize: cint = 0
  let rc = vmufs_read(dev, hashFilename(logicalPath), addr outbuf, addr outsize)
  if rc < 0:
    # rc < 0 means outbuf was NOT allocated — do not free
    raise newException(ConfigIOError, "vmufs_read failed: " & $rc)
  # outbuf is now a C-malloc'd buffer owned by us
  try:
    var pkg: VmuPkg
    if vmu_pkg_parse(cast[ptr uint8](outbuf), csize_t(outsize), addr pkg) < 0:
      raise newException(ConfigParseError, "VMU file CRC check failed")
    # pkg.data is a BORROW into outbuf — copy before freeing
    result = newString(pkg.data_len)
    copyMem(addr result[0], pkg.data, pkg.data_len)
    # pkg.data_len, not outsize — don't include 512-byte block padding
  finally:
    c_free(outbuf)  # always free, even on exception
```

### vmu_pkg_build ownership

```nim
proc writeVmuFile*(logicalPath: string; payload: string) =
  let dev = vmuSlotA1()
  if dev == nil: raise newException(ConfigUnsupportedError, "VMU not present")
  # Check capacity before attempting write
  let needed = (payload.len + VMS_HEADER_OVERHEAD + 511) div 512
  if int(vmufs_free_blocks(dev)) < needed:
    raise newException(ConfigIOError, "VMU out of space")
  var pkg = buildVmuPkg(payload)  # fill vmu_pkg_t with icon + payload
  var vmsBuf: ptr uint8 = nil
  var vmsSize: cint = 0
  if vmu_pkg_build(addr pkg, addr vmsBuf, addr vmsSize) < 0:
    raise newException(ConfigIOError, "vmu_pkg_build failed")
  try:
    let fn = hashFilename(logicalPath)
    if vmufs_write(dev, fn, vmsBuf, vmsSize, VMUFS_OVERWRITE) < 0:
      raise newException(ConfigIOError, "vmufs_write failed for " & logicalPath)
  finally:
    c_free(vmsBuf)  # always free the VMS-packaged buffer
```

**Notes**:
- `pkg.data` (source payload) is caller-owned across `vmu_pkg_build` — it may be
  the Nim `string.cstring` which is valid until the string is GC'd. Keep `payload`
  alive across the call.
- `VMS_HEADER_OVERHEAD` ≈ 128 bytes header + 512 bytes icon + padding. A static `const`
  of 2 blocks (1024 bytes) is a safe conservative estimate for capacity checks.
- `vmufs_write` writes the `vmsBuf` verbatim; no additional padding is needed as
  `vmu_pkg_build` already rounds up to 512-byte block boundaries internally.
  On read, use `pkg.data_len` (not block size) to bound the payload slice.

### 512-byte block padding responsibility

`vmu_pkg_build` is responsible for padding the output buffer to a 512-byte boundary.
`vmufs_write` takes that pre-padded buffer. configy does **not** need to pad. On read,
`pkg.data_len` gives the un-padded payload length — use it, not `outsize`.

---

## Nim FFI binding plan for vmu.nim

```nim
# Headers needed
{.passC: "-I$KOS_BASE/include -I$KOS_BASE/kernel/arch/dreamcast/include".}

# maple.h types
type MapleDevice {.importc: "maple_device_t", header: "dc/maple.h", incompleteStruct.} = object
proc maple_enum_dev(p, u: cint): ptr MapleDevice
  {.importc: "maple_enum_dev", header: "dc/maple.h".}
const MAPLE_FUNC_MEMCARD = 0x02000000'u32

# vmufs.h
const VMUFS_OVERWRITE = 1.cint
proc vmufs_write(dev: ptr MapleDevice; fn: cstring; inbuf: pointer; insize, flags: cint): cint
  {.importc: "vmufs_write", header: "dc/vmufs.h".}
proc vmufs_read(dev: ptr MapleDevice; fn: cstring; outbuf: ptr pointer; outsize: ptr cint): cint
  {.importc: "vmufs_read", header: "dc/vmufs.h".}
proc vmufs_delete(dev: ptr MapleDevice; fn: cstring): cint
  {.importc: "vmufs_delete", header: "dc/vmufs.h".}
proc vmufs_free_blocks(dev: ptr MapleDevice): cint
  {.importc: "vmufs_free_blocks", header: "dc/vmufs.h".}

# vmu_pkg.h
type VmuPkg {.importc: "vmu_pkg_t", header: "dc/vmu_pkg.h".} = object
  desc_short: array[20, char]
  desc_long:  array[36, char]
  app_id:     array[20, char]
  icon_cnt, icon_anim_speed, eyecatch_type, data_len: cint
  icon_pal:   array[16, uint16]
  icon_data, eyecatch_data: ptr uint8
  data: ptr uint8
proc vmu_pkg_build(src: ptr VmuPkg; dst: ptr ptr uint8; dst_size: ptr cint): cint
  {.importc: "vmu_pkg_build", header: "dc/vmu_pkg.h".}
proc vmu_pkg_parse(data: ptr uint8; data_size: csize_t; pkg: ptr VmuPkg): cint
  {.importc: "vmu_pkg_parse", header: "dc/vmu_pkg.h".}
# Note: VmuPkg mirrors the C struct layout; add a compile-time check:
#   static_assert(sizeof(vmu_pkg_t) == sizeof(VmuPkg), "VmuPkg layout mismatch")
# or keep VmuPkg opaque (use incompleteStruct + access via separate procs) if layout stability
# across KOS versions is a concern.
```

---

## Lookup path for a1 slot

```nim
proc vmuSlotA1(): ptr MapleDevice =
  maple_enum_dev(0, 1)  # port 0, unit 1 = a1

proc isPresent*(): bool {.raises: [].} =
  vmuSlotA1() != nil

proc freeBlocks*(): int {.raises: [].} =
  let dev = vmuSlotA1()
  if dev == nil: return 0
  int(vmufs_free_blocks(dev))
```

---

## VMS metadata defaults for configy

When building a `vmu_pkg_t` for `vmu_pkg_build`, use these defaults:

```nim
proc buildVmuPkg(payload: string): VmuPkg =
  # desc_short/desc_long/app_id: space-padded (not NUL-padded) in the on-disk header
  copyMem(addr result.desc_short[0], cstring("configy"), 7)  # or app-specific if provided
  copyMem(addr result.desc_long[0],  cstring("configy data"), 12)
  copyMem(addr result.app_id[0],     cstring("configy"), 7)
  result.icon_cnt        = 1          # one static frame
  result.icon_anim_speed = 255        # max speed (irrelevant for 1 frame)
  result.eyecatch_type   = 0          # VMUPKG_EC_NONE
  result.data_len        = cint(payload.len)
  result.icon_pal        = CONFIGY_VMU_ICON_PAL  # committed const (task configy-9e5)
  result.icon_data       = addr CONFIGY_VMU_ICON_DATA[0]  # 512-byte committed const
  result.eyecatch_data   = nil
  result.data            = cast[ptr uint8](payload.cstring)
  # Keep payload alive until vmu_pkg_build returns
```

---

## Critical constraints (confirmed from headers)

| Constraint | Source | Value |
|-----------|--------|-------|
| Filename max length | `vmu_dir_t.filename[12]` | **≤11 chars recommended** (leave room for cstring NUL) |
| File size granularity | `vmu_pkg_build` handles padding | **512-byte blocks; vmu_pkg_build pads; use `pkg.data_len` on read** |
| Subdirectory support | vmufs.h + fs_vmu.h docs | **None — flat FS only** |
| Free block query | `vmufs_free_blocks(dev)` | **Runtime — never hard-code 200; check before write** |
| VMS CRC check | `vmu_pkg_parse` returns -1 on bad CRC | Must handle as `ConfigParseError` |
| Icon | `vmu_pkg_t.icon_data` | **512 bytes (32×32 4bpp), icon_pal[16] ARGB4444** |
| Overwrite | `vmufs_write(..., VMUFS_OVERWRITE)` | Atomic delete-then-write |
| Mutex | `vmufs_mutex_lock/unlock` | Higher-level `vmufs_*` functions manage internally |
| vmufs_read alloc | C `malloc` | Must `c_free` in `finally`; don't free on rc<0 |
| vmu_pkg_build alloc | C `malloc` | Must `c_free` in `finally` |
| pkg.data borrow | Points into vmufs_read buffer | Copy `data_len` bytes before freeing the read buffer |
| Collision policy | hash namespace is 11-char uppercase | Document as accepted risk for <10 files |
| Capacity check | `vmufs_free_blocks` × 512 | Check before write; account for ≈2 block VMS overhead |
