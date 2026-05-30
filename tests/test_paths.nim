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

    test "configRoot ends with trailing separator":
      let root = configRoot()
      check root.len > 0
      check root[^1] == '/'

    test "configRoot contains vendor namespace":
      let root = configRoot()
      check strutils.contains(root, VendorNamespace)

    test "configRoot starts with home dir hidden dir":
      let root = configRoot()
      let home = getHomeDir()
      check root.startsWith(home)
      check strutils.contains(root, "." & VendorNamespace)

    test "configDir produces expected structure":
      let dir = configDir("myapp", "mylib")
      check dir.endsWith("/")
      check strutils.contains(dir, "myapp")
      check strutils.contains(dir, "mylib")
      check strutils.contains(dir, VendorNamespace)

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
