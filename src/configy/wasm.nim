import std/options
import configy/capabilities
import configy/errors

when defined(emscripten):
  proc setItem*(key, value: string) {.raises: [ConfigUnsupportedError].} =
    ## Maps to JS localStorage.setItem. v1: raises ConfigUnsupportedError.
    raise newException(ConfigUnsupportedError,
      "configy: localStorage write not implemented (WASM v1 stub)")

  proc getItem*(key: string): Option[string] {.raises: [].} =
    ## Maps to JS localStorage.getItem. v1: returns none().
    none(string)

  proc removeItem*(key: string): bool {.raises: [ConfigUnsupportedError].} =
    ## Maps to JS localStorage.removeItem. v1: raises ConfigUnsupportedError.
    raise newException(ConfigUnsupportedError,
      "configy: localStorage delete not implemented (WASM v1 stub)")

  proc hasItem*(key: string): bool {.raises: [].} =
    ## Maps to JS localStorage check. v1: returns false.
    false
