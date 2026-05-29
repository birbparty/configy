type
  ConfigError* = object of CatchableError

  ConfigPathError* = object of ConfigError

  ConfigIOError* = object of ConfigError

  ConfigParseError* = object of ConfigError

  ConfigUnsupportedError* = object of ConfigError
