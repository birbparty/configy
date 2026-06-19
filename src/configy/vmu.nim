# VMU persistence layer for Dreamcast.
#
# Compiled ONLY when -d:dreamcast is active (imported inside `when defined(dreamcast):`
# arms in store.nim and fs.nim). Never import this module on the host build path.
#
# Ordering contract:
#   - configy does NOT call maple_init / maple_shutdown. The host application brings up
#     KOS (including maple_init) before calling any configy proc.
#   - The VMU at slot a1 (port 0, unit 1) may be absent at any time; all procs that
#     require a device check isPresent() or accept nil from vmuSlotA1().
#   - Caller must not hold a maple_device_t* across any KOS maple poll loop. For configy's
#     use (read/write during app startup or explicit save), this is not a concern.

# ── C free (for C-malloc'd buffers returned by vmufs_read and vmu_pkg_build) ─

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

# ── Maple device (opaque) ────────────────────────────────────────────────────

type
  MapleDevice {.importc: "maple_device_t", header: "dc/maple.h",
                incompleteStruct.} = object

proc maple_enum_dev(p, u: cint): ptr MapleDevice
  {.importc: "maple_enum_dev", header: "dc/maple.h".}

# ── vmufs.h — high-level VMU filesystem ops ──────────────────────────────────
#
# These manage root/FAT/dir internally. Do NOT use the low-level
# vmufs_file_read/write/delete variants (they require manual block management).

const vmufsOverwrite* = 1.cint  # Atomic delete-then-write if file exists

proc vmufs_write(dev: ptr MapleDevice; fn: cstring; inbuf: pointer;
                 insize, flags: cint): cint
  {.importc: "vmufs_write", header: "dc/vmufs.h".}

proc vmufs_read(dev: ptr MapleDevice; fn: cstring; outbuf: ptr pointer;
                outsize: ptr cint): cint
  {.importc: "vmufs_read", header: "dc/vmufs.h".}
  # *outbuf is C-malloc'd ONLY on success (rc >= 0). On failure (rc < 0), *outbuf
  # is NOT allocated — do NOT call c_free. Always initialise outbuf = nil before call.

proc vmufs_delete(dev: ptr MapleDevice; fn: cstring): cint
  {.importc: "vmufs_delete", header: "dc/vmufs.h".}

proc vmufs_free_blocks(dev: ptr MapleDevice): cint
  {.importc: "vmufs_free_blocks", header: "dc/vmufs.h".}

# ── vmu_pkg.h — VMS packaging (required for BIOS memory manager visibility) ──

const vmupkgEcNone* = 0.cint  # No eyecatch

type
  VmuPkg {.importc: "vmu_pkg_t", header: "dc/vmu_pkg.h".} = object
    desc_short:      array[20, char]
    desc_long:       array[36, char]
    app_id:          array[20, char]
    icon_cnt:        cint
    icon_anim_speed: cint
    eyecatch_type:   cint
    data_len:        cint
    icon_pal:        array[16, uint16]
    icon_data:       ptr uint8
    eyecatch_data:   ptr uint8
    data:            ptr uint8  # BORROW: points into caller's buffer; do not free this field

proc vmu_pkg_build(src: ptr VmuPkg; dst: ptr ptr uint8; dst_size: ptr cint): cint
  {.importc: "vmu_pkg_build", header: "dc/vmu_pkg.h".}
  # *dst is C-malloc'd ONLY on success (rc >= 0). On failure (rc < 0), *dst is NOT
  # allocated — do NOT c_free. On success, caller must c_free(*dst) in a finally
  # block that also covers vmufs_write failure (i.e. free on all exit paths once allocated).

proc vmu_pkg_parse(data: ptr uint8; data_size: csize_t; pkg: ptr VmuPkg): cint
  {.importc: "vmu_pkg_parse", header: "dc/vmu_pkg.h".}
  # pkg->data BORROWS a pointer into `data` — NOT a copy.
  # Copy pkg.data_len bytes BEFORE freeing the source buffer.

# ── Slot constants ────────────────────────────────────────────────────────────
#
# Port A, Unit 1 = the standard save-game VMU slot on Dreamcast.
# Both the isPresent() probe and all read/write paths use these constants —
# they must never diverge.

const
  vmuPort* = 0.cint  # Port A
  vmuUnit* = 1.cint  # Unit 1 (slot 1 = a1)


proc vmuSlotA1(): ptr MapleDevice {.inline.} =
  maple_enum_dev(vmuPort, vmuUnit)

# ── Public query procs ────────────────────────────────────────────────────────

proc isPresent*(): bool {.raises: [].} =
  ## Returns true if a VMU is inserted at port A, slot 1 (a1).
  ## Cheap pointer lookup via maple_enum_dev — safe to call repeatedly.
  vmuSlotA1() != nil

proc freeBlocks*(): int {.raises: [].} =
  ## Returns the number of free 512-byte blocks on the a1 VMU.
  ## Returns 0 if no VMU is present or the FS is unreadable. Never hard-code a
  ## threshold — always query. Negative KOS error codes are clamped to 0.
  let dev = vmuSlotA1()
  if dev == nil: return 0
  result = int(vmufs_free_blocks(dev))
  if result < 0: result = 0

proc vmuIsWritable*(): bool {.raises: [].} =
  ## Returns true only if a VMU is present at slot a1 AND has at least one
  ## free 512-byte block. False on Maple not up / no VMU inserted / full card.
  ## Best-effort heuristic — a true result does not guarantee a subsequent write
  ## succeeds (card could be write-protected, FAT corrupt, or removed afterwards).
  ## Intended for use by fs.isWritable() on dreamcast; wired in configy-pw6.
  let dev = vmuSlotA1()
  if dev == nil: return false
  int(vmufs_free_blocks(dev)) > 0  # negative (FS error) → false; 0 (full) → false

import ./vmu_hash
export vmu_hash  # re-export so callers can reach hashFilename via vmu

import ./errors
import ./capabilities  # VendorNamespace ({.strdefine.} configyVendor)

# ── Default icon (32×32, 4bpp, 1 frame) ──────────────────────────────────────
#
# A minimal placeholder glyph for the BIOS file manager.
# Format: 4bpp paletted, high nibble = left pixel, low nibble = right pixel.
# 512 bytes (32 rows × 16 bytes/row). Palette uses ARGB1555 (1+5+5+5 bits).
#
# Visual: white-bordered black box (2px border on all sides).
# Uses only 3 palette entries: 0=transparent, 1=black, 2=white.
# Replace with a real icon once the art requirement is finalized.

const vmuDefaultIconPal*: array[16, uint16] = [
  0x0000'u16,  # 0: transparent (unused pixels)
  0x8000'u16,  # 1: opaque black (inner area)
  0xFFFF'u16,  # 2: opaque white (2px border)
  0x0000'u16, 0x0000'u16, 0x0000'u16, 0x0000'u16,  # 3-6:  unused
  0x0000'u16, 0x0000'u16, 0x0000'u16, 0x0000'u16,  # 7-10: unused
  0x0000'u16, 0x0000'u16, 0x0000'u16, 0x0000'u16,  # 11-14: unused
  0x0000'u16,                                         # 15:    unused
]

const vmuDefaultIconData*: array[512, uint8] = [
  # row 0  (top border — all white)
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  # row 1  (top border — all white)
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  # rows 2-29 (white left/right border, black interior)
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  0x22'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8,
  0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x11'u8, 0x22'u8,
  # row 30 (bottom border — all white)
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  # row 31 (bottom border — all white)
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
  0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8, 0x22'u8,
]

# ── VMS packaging helpers ─────────────────────────────────────────────────────

proc fillPaddedStr(dst: var openArray[char]; src: string) {.inline.} =
  # Space-pad a char array from src. KOS metadata fields are space-padded,
  # NOT NUL-padded; padding with spaces is the correct on-disk format.
  let n = min(src.len, dst.len)
  for i in 0 ..< n:        dst[i] = src[i]
  for i in n ..< dst.len:  dst[i] = ' '

proc buildVmuPkg(payload: string): VmuPkg =
  # Populate a VmuPkg for vmu_pkg_build. The returned struct BORROWS payload's
  # cstring in the `data` field — payload must outlive this struct across the
  # vmu_pkg_build call.
  fillPaddedStr(result.desc_short, VendorNamespace & " config")
  fillPaddedStr(result.desc_long,  VendorNamespace & " configy data")
  fillPaddedStr(result.app_id,     VendorNamespace)
  result.icon_cnt        = 1.cint
  result.icon_anim_speed = 255.cint
  result.eyecatch_type   = vmupkgEcNone
  result.data_len        = cint(payload.len)
  result.icon_pal        = vmuDefaultIconPal
  result.icon_data       = cast[ptr uint8](unsafeAddr vmuDefaultIconData[0])
  result.eyecatch_data   = nil
  result.data            = cast[ptr uint8](cstring(payload))

# ── Public write / read / exists / delete ────────────────────────────────────

proc writeVmuFile*(logicalPath: string; payload: string)
    {.raises: [ConfigIOError].} =
  ## Write payload to the VMU at slot a1 under logicalPath.
  ## VMS-packages the payload (required for BIOS memory manager visibility).
  ## Raises ConfigIOError if the VMU is absent, packaging fails, or write fails.
  let dev = vmuSlotA1()
  if dev == nil:
    raise newException(ConfigIOError, "VMU not present (slot a1)")
  # ARC keep-alive invariant: buildVmuPkg borrows payload's buffer (non-sink param
  # under ARC → no copy, no destroy; pkg.data points at writeVmuFile's payload).
  # payload must not be moved or sunk before vmu_pkg_build returns.
  var pkg = buildVmuPkg(payload)
  var vmsBuf: ptr uint8 = nil
  var vmsSize: cint = 0
  if vmu_pkg_build(addr pkg, addr vmsBuf, addr vmsSize) < 0:
    raise newException(ConfigIOError,
      "vmu_pkg_build failed for " & logicalPath)
  # vmsBuf is C-malloc'd from here; free even if capacity check or write fails
  try:
    let neededBlocks = (int(vmsSize) + 511) div 512
    let available = freeBlocks()
    # Conservative check: when VMUFS_OVERWRITE deletes an existing file, the
    # freed blocks are not credited here. Re-saving a config on a near-full card
    # may produce a false-positive "VMU full" even if the overwrite would fit.
    # This is safe (writes are only rejected, not silently broken), and acceptable
    # given configy's typical <10 small files per card.
    if available < neededBlocks:
      raise newException(ConfigIOError,
        "VMU full (" & $available & " blocks free, need " & $neededBlocks & ")")
    let fn = hashFilename(logicalPath)
    if vmufs_write(dev, cstring(fn), vmsBuf, vmsSize, vmufsOverwrite) < 0:
      raise newException(ConfigIOError,
        "vmufs_write failed for " & logicalPath)
  finally:
    c_free(vmsBuf)

proc readVmuFile*(logicalPath: string): string
    {.raises: [ConfigIOError, ConfigParseError].} =
  ## Read and unwrap a VMS-packaged payload from the VMU at slot a1.
  ## Raises ConfigIOError if the VMU is absent or the read fails.
  ## Raises ConfigParseError if the VMS CRC check fails.
  let dev = vmuSlotA1()
  if dev == nil:
    raise newException(ConfigIOError, "VMU not present (slot a1)")
  var outbuf: pointer = nil  # nil: only c_free when rc >= 0
  var outsize: cint = 0
  let fn = hashFilename(logicalPath)
  if vmufs_read(dev, cstring(fn), addr outbuf, addr outsize) < 0:
    raise newException(ConfigIOError,
      "vmufs_read failed for " & logicalPath)
  # outbuf is C-malloc'd from here; pkg.data borrows into it — copy first
  try:
    var pkg: VmuPkg
    if vmu_pkg_parse(cast[ptr uint8](outbuf), csize_t(outsize),
                     addr pkg) < 0:
      raise newException(ConfigParseError,
        "VMU file CRC check failed for " & logicalPath)
    result = newString(pkg.data_len)
    if pkg.data_len > 0:
      copyMem(addr result[0], pkg.data, pkg.data_len)
  finally:
    c_free(outbuf)

proc existsVmuFile*(logicalPath: string): bool {.raises: [].} =
  ## Returns true if a file exists on the VMU for logicalPath.
  ## Uses a read-probe (VMU has no stat/exists call); returns false if the
  ## VMU is absent or the file is not found.
  let dev = vmuSlotA1()
  if dev == nil: return false
  var outbuf: pointer = nil
  var outsize: cint = 0
  let fn = hashFilename(logicalPath)
  let rc = vmufs_read(dev, cstring(fn), addr outbuf, addr outsize)
  if rc >= 0:
    c_free(outbuf)
    return true
  return false

proc deleteVmuFile*(logicalPath: string): bool {.raises: [ConfigIOError].} =
  ## Delete the VMU file for logicalPath. Returns true if deleted, false if
  ## the file was not found (idempotent; matches deleteConfig's bool contract).
  ## Raises ConfigIOError if the VMU is absent or deletion fails (-2).
  let dev = vmuSlotA1()
  if dev == nil:
    raise newException(ConfigIOError, "VMU not present (slot a1)")
  let fn = hashFilename(logicalPath)
  let rc = vmufs_delete(dev, cstring(fn))
  if rc == 0:  return true   # deleted
  if rc == -1: return false  # not found — idempotent
  raise newException(ConfigIOError,
    "vmufs_delete failed for " & logicalPath)
