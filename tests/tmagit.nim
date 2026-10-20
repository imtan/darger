import ../src/magit

let entries = parseStatus("?? new file\0 M changed\0M  staged\0MM both\0R  renamed\0old name\0RM newer\0older\0")
doAssert entries.len == 6
doAssert entries[0].untracked and not entries[0].staged and not entries[0].unstaged
doAssert entries[0].path == "new file"
doAssert entries[1].unstaged and not entries[1].staged
doAssert entries[2].staged and not entries[2].unstaged
doAssert entries[3].staged and entries[3].unstaged
doAssert entries[4].oldPath == "old name" and entries[4].path == "renamed"
doAssert entries[4].statusLabel(true) == "R old name -> renamed"
doAssert entries[5].staged and entries[5].unstaged
doAssert entries[5].statusLabel(false) == "M older -> newer"
doAssert parseStatus("").len == 0
doAssert parseStatus("R  incomplete\0").len == 0
let special = parseStatus("?? 日本語\nwith\ttab\0 D deleted\0 C copy\0original\0")
doAssert special.len == 3
doAssert special[0].path == "日本語\nwith\ttab"
doAssert special[0].statusLabel(false) == "? 日本語\\nwith\\ttab"
doAssert special[1].unstaged
doAssert special[2].oldPath == "original"
echo "magit ok"
