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

# Conservative overhead for capacity check: VMS header + icon + block rounding.
# vmu_pkg_build pads to 512-byte blocks; we budget 2 blocks (1024 bytes) for overhead.
const vmsOverheadBlocks* = 2

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

import ./vmu_hash
export vmu_hash  # re-export so callers can reach hashFilename via vmu

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

# ── Forward: public write/read/delete/exists procs (configy-70t / configy-2n9) ─
#
# proc writeVmuFile*(logicalPath: string; payload: string)
#   Canonical pattern: vmu_pkg_build → vmufs_write → c_free(vmsBuf) in finally.
#   The c_free MUST be in a finally block so it runs even if vmufs_write fails.
#
# proc readVmuFile*(logicalPath: string): string
#   Canonical ordering (all steps required before any free):
#     1. var outbuf: pointer = nil  (init nil; only free if rc >= 0)
#     2. vmufs_read → rc check; raise on rc < 0 (outbuf not allocated)
#     3. vmu_pkg_parse → CRC check; raise on -1
#     4. copy pkg.data_len bytes out of pkg.data  (pkg.data borrows into outbuf)
#     5. c_free(outbuf) in finally (after copy, NOT before)
#
# proc existsVmuFile*(logicalPath: string): bool
# proc deleteVmuFile*(logicalPath: string)
#
# These depend on hashFilename and will land in subsequent tasks.
