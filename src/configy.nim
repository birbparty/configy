import configy/capabilities
import configy/errors
import configy/paths
import configy/fs
import configy/store
export capabilities, errors, paths, fs, store
when defined(emscripten):
  import configy/wasm
  export wasm
