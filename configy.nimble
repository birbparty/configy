# Package

version       = "0.1.0"
author        = "Matt Spurlin"
description   = "Cross-platform configuration path resolver and storage library for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"
requires "supersnappy >= 2.0.2"

# Tasks

task test, "Run the test suite":
  exec "testament pattern 'tests/test_*.nim'"
