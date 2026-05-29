# Required: supplies -d:configyVendor for all test compiles.
# capabilities.nim has a static {.error.} guard that fails builds without this define.
switch("define", "configyVendor=testvendor")
