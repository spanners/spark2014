from test_support import *
import glob

prove("length.adb",opt=["-P", "test.gpr", "--all-vcs"])
