version = "0.1.0"
author = "darger contributors"
description = "A small GPU-rendered Emacs-style text editor"
license = "MIT"
srcDir = "src"
bin = @["darger"]
requires "nim >= 2.2.12", "windy == 0.5.0", "boxy == 0.7.0", "pixie == 6.1.0"
