import std/[unittest, os, strutils]
import configy

suite "validateComponent":
  test "rejects empty string":
    expect ConfigPathError: validateComponent("")

  test "rejects forward slash":
    expect ConfigPathError: validateComponent("a/b")

  test "rejects backslash":
    expect ConfigPathError: validateComponent("a\\b")

  test "rejects bare double-dot":
    expect ConfigPathError: validateComponent("..")

  test "rejects colon anywhere":
    expect ConfigPathError: validateComponent("a:b")
    expect ConfigPathError: validateComponent(":leading")
    expect ConfigPathError: validateComponent("trailing:")

  test "allows embedded double-dot (not a traversal)":
    validateComponent("my..backup.json")

  test "allows normal filename":
    validateComponent("settings.json")

  test "allows single dot":
    validateComponent(".")

  test "allows alphanumeric and hyphens":
    validateComponent("my-app")
    validateComponent("v2")

suite "configRoot and configDir (desktop, non-Windows)":
  when not defined(windows) and not defined(ds3) and not defined(psp) and
       not defined(vita) and not defined(emscripten):

    proc withXdgConfigHome(value: string, body: proc()) =
      # Snapshot both the value and whether the var was set at all, so a
      # set-but-empty XDG_CONFIG_HOME in the environment is restored exactly.
      let savedValue = getEnv("XDG_CONFIG_HOME")
      let wasSet = existsEnv("XDG_CONFIG_HOME")
      if value.len > 0: putEnv("XDG_CONFIG_HOME", value)
      else: delEnv("XDG_CONFIG_HOME")
      try: body()
      finally:
        if wasSet: putEnv("XDG_CONFIG_HOME", savedValue)
        else: delEnv("XDG_CONFIG_HOME")

    test "configRoot ends with trailing separator":
      withXdgConfigHome(""):
        let root = configRoot()
        check root.len > 0
        check root[^1] == '/'

    test "configRoot contains vendor namespace":
      withXdgConfigHome(""):
        let root = configRoot()
        check strutils.contains(root, VendorNamespace)

    test "configRoot falls back to ~/.config when XDG_CONFIG_HOME is unset":
      withXdgConfigHome(""):
        let root = configRoot()
        check root.startsWith(getHomeDir() / ".config")
        check strutils.contains(root, VendorNamespace)

    test "configRoot respects XDG_CONFIG_HOME when set to absolute path":
      withXdgConfigHome("/tmp/xdg-test"):
        let root = configRoot()
        check root.startsWith("/tmp/xdg-test")
        check strutils.contains(root, VendorNamespace)

    test "configRoot ignores XDG_CONFIG_HOME if not absolute":
      withXdgConfigHome("relative/path"):
        let root = configRoot()
        check root.startsWith(getHomeDir())

    test "configRoot ignores empty XDG_CONFIG_HOME":
      withXdgConfigHome(""):
        let root = configRoot()
        check root.startsWith(getHomeDir())

    test "configDir produces expected structure":
      withXdgConfigHome(""):
        let dir = configDir("myapp", "mylib")
        check dir.endsWith("/")
        check strutils.contains(dir, "myapp")
        check strutils.contains(dir, "mylib")
        check strutils.contains(dir, VendorNamespace)
        check strutils.contains(dir, ".config")

    test "configDir raises on empty app":
      expect ConfigPathError: discard configDir("", "mylib")

    test "configDir raises on colon in dep":
      expect ConfigPathError: discard configDir("myapp", "my:dep")

    test "configFile includes filename at end":
      let path = configFile("myapp", "mylib", "settings.json")
      check path.endsWith("settings.json")
      check path.endsWith("/settings.json") or path.endsWith("\\settings.json")

    test "configFile raises on bad filename":
      expect ConfigPathError: discard configFile("myapp", "mylib", "../escape.json")
      expect ConfigPathError: discard configFile("myapp", "mylib", "")

    test "configDir without dep returns two-level path":
      withXdgConfigHome(""):
        let dir = configDir("myapp")
        check dir.endsWith("/")
        check strutils.contains(dir, "myapp")
        check not strutils.contains(dir, "mylib")

    test "configFile without dep includes filename directly under app":
      withXdgConfigHome(""):
        let path = configFile("myapp", "settings.json")
        check path.endsWith("settings.json")
        check not strutils.contains(path, "/mylib/")

    test "configFile dep-less and full differ only in dep segment":
      withXdgConfigHome(""):
        let short = configFile("myapp", "config.toml")
        let full  = configFile("myapp", "cache", "config.toml")
        check full.len > short.len
        check strutils.contains(full, "cache")
        check not strutils.contains(short, "cache")

    test "configRoot collapses trailing slash in XDG_CONFIG_HOME":
      withXdgConfigHome("/tmp/xdg-test/"):
        let root = configRoot()
        check not strutils.contains(root, "//")
        check root.startsWith("/tmp/xdg-test/")

when defined(emscripten):
  suite "configRoot — WASM (emscripten)":
    test "WASM root is config/<vendor>/":
      check configRoot() == "config/" & VendorNamespace & "/"
    test "WASM dep-less configDir":
      check configDir("myapp") == "config/" & VendorNamespace & "/myapp/"
    test "WASM full configDir":
      check configDir("myapp", "mylib") == "config/" & VendorNamespace & "/myapp/mylib/"
    test "WASM dep-less configFile":
      check configFile("myapp", "s.json") == "config/" & VendorNamespace & "/myapp/s.json"
    test "WASM full configFile":
      check configFile("myapp", "mylib", "s.json") == "config/" & VendorNamespace & "/myapp/mylib/s.json"

when defined(vita):
  suite "configRoot — PS Vita":
    test "Vita root is ux0:data/config/<vendor>/":
      check configRoot() == "ux0:data/config/" & VendorNamespace & "/"
    test "Vita dep-less configDir":
      check configDir("myapp") == "ux0:data/config/" & VendorNamespace & "/myapp/"
    test "Vita dep-less configFile":
      check configFile("myapp", "s.json") == "ux0:data/config/" & VendorNamespace & "/myapp/s.json"

when defined(psp):
  suite "configRoot — PSP":
    test "PSP root is ms0:/PSP/config/<vendor>/":
      check configRoot() == "ms0:/PSP/config/" & VendorNamespace & "/"
    test "PSP dep-less configDir":
      check configDir("myapp") == "ms0:/PSP/config/" & VendorNamespace & "/myapp/"
    test "PSP dep-less configFile":
      check configFile("myapp", "s.json") == "ms0:/PSP/config/" & VendorNamespace & "/myapp/s.json"

when defined(ds3):
  suite "configRoot — Nintendo 3DS":
    test "3DS root is sdmc:/config/<vendor>/":
      check configRoot() == "sdmc:/config/" & VendorNamespace & "/"
    test "3DS dep-less configDir":
      check configDir("myapp") == "sdmc:/config/" & VendorNamespace & "/myapp/"
    test "3DS dep-less configFile":
      check configFile("myapp", "s.json") == "sdmc:/config/" & VendorNamespace & "/myapp/s.json"

when defined(dreamcast):
  suite "configRoot — Dreamcast [PENDING: will fail until paths.nim arm lands]":
    test "Dreamcast root is /vmu/a1/<vendor>/":
      check configRoot() == "/vmu/a1/" & VendorNamespace & "/"
    test "Dreamcast dep-less configDir uses / not DirSep":
      check configDir("myapp") == "/vmu/a1/" & VendorNamespace & "/myapp/"
    test "Dreamcast full configDir":
      check configDir("myapp", "mylib") == "/vmu/a1/" & VendorNamespace & "/myapp/mylib/"
    test "Dreamcast dep-less configFile":
      check configFile("myapp", "s.json") == "/vmu/a1/" & VendorNamespace & "/myapp/s.json"
    test "Dreamcast full configFile":
      check configFile("myapp", "mylib", "s.json") == "/vmu/a1/" & VendorNamespace & "/myapp/mylib/s.json"
