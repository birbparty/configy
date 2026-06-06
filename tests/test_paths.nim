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
      let saved = getEnv("XDG_CONFIG_HOME")
      if value.len > 0: putEnv("XDG_CONFIG_HOME", value)
      else: delEnv("XDG_CONFIG_HOME")
      try: body()
      finally:
        if saved.len > 0: putEnv("XDG_CONFIG_HOME", saved)
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
