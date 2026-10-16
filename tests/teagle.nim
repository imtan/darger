import std/[strutils]
import ../src/eagle

let info = """{"status":"success","data":{"folders":[],"library":{"path":"/Users/x/Dropbox/L.library","name":"L"}}}"""
doAssert libraryPath(info) == "/Users/x/Dropbox/L.library"
let list = """{"status":"success","data":[
 {"id":"A1","name":"cat","ext":"PNG","tags":["cute","animal","a","b","c","d"]},
 {"id":"B2","name":"notes","ext":"pdf","tags":[]},
 {"id":"C3","name":"山","ext":"jpg"}]}"""
let its = items(list)
doAssert its.len == 2 and its[0].ext == "png" and its[1].name == "山"      # the pdf is skipped, ext lowered
doAssert itemLabel(its[0]) == "cat.png  [cute, animal, a, b, c]" and itemLabel(its[1]) == "山.jpg"
doAssert originalPath(its[0], "/Users/x/Dropbox/L.library") == "/Users/x/Dropbox/L.library/images/A1.info/cat.png"
doAssert abbreviateHome("/Users/x/Dropbox/L.library/images/A1.info/cat.png", "/Users/x") == "~/Dropbox/L.library/images/A1.info/cat.png"
doAssert abbreviateHome("/opt/img.png", "/Users/x") == "/opt/img.png"
doAssert thumbnailPath(its[0], "/L") == "/L/images/A1.info/cat_thumbnail.png"
doAssert abbreviateHome("/Users/x/a.png", "/Users/x/") == "~/a.png"  # getHomeDir() has a trailing slash
import std/os
doAssert abbreviateHome(getHomeDir() & "pic.png") == "~/pic.png"
let fl = folders("""{"status":"success","data":[{"id":"F1","name":"AI","children":[{"id":"F2","name":"sub","children":[]}]},{"id":"F3","name":"かわいい"}]}""")
doAssert fl.len == 3 and fl[1].label == "AI/sub" and fl[1].id == "F2" and fl[2].label == "かわいい"
doAssert listQuery() == "/api/item/list?limit=200&orderBy=-MTIME"
doAssert listQuery(keyword = "猫 犬") == "/api/item/list?limit=200&orderBy=-MTIME&keyword=%E7%8C%AB+%E7%8A%AC"
doAssert listQuery(folder = "F2").endsWith("&folders=F2")
doAssertRaises(ValueError): discard apiData("""{"status":"error"}""")
echo "eagle ok"
