version = "0.1.0"
author = "darger contributors"
description = "A small GPU-rendered Emacs-style text editor"
license = "MIT"
srcDir = "src"
bin = @["darger"]
# windy is pinned exactly: patches/windy targets 0.5.0.
requires "nim >= 2.2.10", "windy == 0.5.0", "boxy == 0.7.0", "pixie == 6.1.0"
