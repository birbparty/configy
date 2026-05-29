const configyVendor {.strdefine.} = ""
static:
  doAssert configyVendor == "testvendor", "tests/config.nims must set -d:configyVendor=testvendor"
