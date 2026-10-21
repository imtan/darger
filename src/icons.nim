## File-type icons for the tree: Nerd Font glyphs (Iosevka Nerd Font Mono, the font
## the editor prefers, has them all at one cell) with a face for their colour. Pure;
## the extension decides whether the current font can show them.
import std/[strutils, os, unicode, tables]
import syntax

type Icon* = object
  glyph*: string
  face*: Face

proc icon(cp: int, face: Face): Icon = Icon(glyph: $Rune(cp), face: face)

const
  folderClosed = 0xE5FF
  folderOpen = 0xE5FE
  plainFile = 0xF016

let byName = {
  "dockerfile": icon(0xE7B0, fAnsi4), "docker-compose.yml": icon(0xE7B0, fAnsi4),
  "makefile": icon(0xE779, fComment), "cmakelists.txt": icon(0xE779, fComment),
  "gemfile": icon(0xE739, fAnsi1), "rakefile": icon(0xE739, fAnsi1), "guardfile": icon(0xE739, fAnsi1),
  "capfile": icon(0xE739, fAnsi1), "vagrantfile": icon(0xE739, fAnsi1), "brewfile": icon(0xE739, fAnsi1),
  "procfile": icon(0xE7A2, fComment),
  "license": icon(0xE60A, fAnsi3), "licence": icon(0xE60A, fAnsi3), "copying": icon(0xE60A, fAnsi3),
  ".gitignore": icon(0xE702, fAnsi1), ".gitattributes": icon(0xE702, fAnsi1),
  ".gitmodules": icon(0xE702, fAnsi1), ".git": icon(0xE702, fAnsi1),
  ".darger.el": icon(0xE632, fAnsi5), ".emacs": icon(0xE632, fAnsi5),
  ".vimrc": icon(0xE62B, fAnsi2), ".zshrc": icon(0xE795, fAnsi2), ".bashrc": icon(0xE795, fAnsi2),
}.toTable

let byExt = {
  "nim": icon(0xE677, fAnsi3), "nims": icon(0xE677, fAnsi3), "nimble": icon(0xE677, fAnsi3),
  "rb": icon(0xE739, fAnsi1), "ru": icon(0xE739, fAnsi1), "rake": icon(0xE739, fAnsi1),
  "gemspec": icon(0xE739, fAnsi1), "erb": icon(0xE60E, fAnsi1),
  "py": icon(0xE73C, fAnsi4), "pyi": icon(0xE73C, fAnsi4),
  "js": icon(0xE74E, fAnsi3), "mjs": icon(0xE74E, fAnsi3), "cjs": icon(0xE74E, fAnsi3), "jsx": icon(0xE74E, fAnsi3),
  "ts": icon(0xE628, fAnsi4), "tsx": icon(0xE628, fAnsi4),
  "json": icon(0xE60B, fAnsi3), "jsonc": icon(0xE60B, fAnsi3), "json5": icon(0xE60B, fAnsi3),
  "yml": icon(0xE6A8, fAnsi5), "yaml": icon(0xE6A8, fAnsi5),
  "md": icon(0xE73E, fAnsi4), "markdown": icon(0xE73E, fAnsi4), "mdx": icon(0xE73E, fAnsi4),
  "org": icon(0xE633, fAnsi2),
  "html": icon(0xE736, fAnsi1), "htm": icon(0xE736, fAnsi1), "xhtml": icon(0xE736, fAnsi1),
  "vue": icon(0xE6A0, fAnsi2), "svelte": icon(0xE697, fAnsi1),
  "css": icon(0xE749, fAnsi4), "less": icon(0xE749, fAnsi4),
  "scss": icon(0xE603, fAnsi5), "sass": icon(0xE603, fAnsi5),
  "haml": icon(0xE664, fAnsi1), "slim": icon(0xE664, fAnsi1),
  "sh": icon(0xE795, fAnsi2), "bash": icon(0xE795, fAnsi2), "zsh": icon(0xE795, fAnsi2),
  "fish": icon(0xE795, fAnsi2), "command": icon(0xE795, fAnsi2),
  "lock": icon(0xF023, fAnsi3),
  "sql": icon(0xE706, fAnsi3),
  "toml": icon(0xE6B2, fComment), "ini": icon(0xE615, fComment), "cfg": icon(0xE615, fComment),
  "conf": icon(0xE615, fComment), "config": icon(0xE615, fComment), "properties": icon(0xE615, fComment),
  "txt": icon(0xF15C, fPlain), "text": icon(0xF15C, fPlain), "log": icon(0xF15C, fPlain),
  "png": icon(0xF1C5, fAnsi5), "jpg": icon(0xF1C5, fAnsi5), "jpeg": icon(0xF1C5, fAnsi5),
  "gif": icon(0xF1C5, fAnsi5), "webp": icon(0xF1C5, fAnsi5), "svg": icon(0xF1C5, fAnsi5),
  "bmp": icon(0xF1C5, fAnsi5), "ico": icon(0xF1C5, fAnsi5), "heic": icon(0xF1C5, fAnsi5),
  "pdf": icon(0xF1C1, fAnsi1),
  "zip": icon(0xF1C6, fAnsi3), "tar": icon(0xF1C6, fAnsi3), "gz": icon(0xF1C6, fAnsi3),
  "tgz": icon(0xF1C6, fAnsi3), "bz2": icon(0xF1C6, fAnsi3), "xz": icon(0xF1C6, fAnsi3),
  "7z": icon(0xF1C6, fAnsi3), "rar": icon(0xF1C6, fAnsi3), "dmg": icon(0xF1C6, fAnsi3),
  "c": icon(0xE61E, fAnsi4), "h": icon(0xE61E, fAnsi4),
  "cpp": icon(0xE61D, fAnsi4), "cc": icon(0xE61D, fAnsi4), "cxx": icon(0xE61D, fAnsi4),
  "hpp": icon(0xE61D, fAnsi4), "hh": icon(0xE61D, fAnsi4),
  "go": icon(0xE627, fAnsi6), "rs": icon(0xE7A8, fAnsi1),
  "java": icon(0xE738, fAnsi1), "jar": icon(0xE738, fAnsi1),
  "kt": icon(0xE634, fAnsi5), "kts": icon(0xE634, fAnsi5), "scala": icon(0xE737, fAnsi1),
  "swift": icon(0xE755, fAnsi1), "lua": icon(0xE620, fAnsi4), "php": icon(0xE73D, fAnsi5),
  "ex": icon(0xE62D, fAnsi5), "exs": icon(0xE62D, fAnsi5),
  "el": icon(0xE632, fAnsi5), "elc": icon(0xE632, fAnsi5),
  "lisp": icon(0xE6B0, fAnsi5), "cl": icon(0xE6B0, fAnsi5), "scm": icon(0xE6B0, fAnsi5),
  "rkt": icon(0xE6B0, fAnsi5), "clj": icon(0xE6B0, fAnsi5),
  "vim": icon(0xE62B, fAnsi2),
  "glsl": icon(0xF121, fAnsi6), "vert": icon(0xF121, fAnsi6), "frag": icon(0xF121, fAnsi6),
  "xml": icon(0xE619, fAnsi1), "xsl": icon(0xE619, fAnsi1), "plist": icon(0xE619, fAnsi1),
  "csv": icon(0xF1C3, fAnsi2), "tsv": icon(0xF1C3, fAnsi2), "xls": icon(0xF1C3, fAnsi2), "xlsx": icon(0xF1C3, fAnsi2),
  "graphql": icon(0xE662, fAnsi5), "gql": icon(0xE662, fAnsi5),
  "ttf": icon(0xF031, fComment), "otf": icon(0xF031, fComment), "woff": icon(0xF031, fComment), "woff2": icon(0xF031, fComment),
  "mp3": icon(0xF001, fAnsi5), "wav": icon(0xF001, fAnsi5), "flac": icon(0xF001, fAnsi5),
  "m4a": icon(0xF001, fAnsi5), "ogg": icon(0xF001, fAnsi5),
  "mp4": icon(0xF03D, fAnsi5), "mov": icon(0xF03D, fAnsi5), "mkv": icon(0xF03D, fAnsi5),
  "webm": icon(0xF03D, fAnsi5), "avi": icon(0xF03D, fAnsi5),
  "epub": icon(0xF02D, fAnsi2), "mobi": icon(0xF02D, fAnsi2),
  "diff": icon(0xF440, fAnsi2), "patch": icon(0xF440, fAnsi2),
  "key": icon(0xF084, fAnsi3), "pem": icon(0xF084, fAnsi3), "crt": icon(0xF084, fAnsi3), "pub": icon(0xF084, fAnsi3),
}.toTable

proc iconFor*(name: string, isDir, expanded: bool): Icon =
  ## The icon for a row: folders by state (coloured like their names), files by
  ## well-known name first, then by extension, else a plain file glyph.
  if isDir: return icon(if expanded: folderOpen else: folderClosed, fKeyword)
  let lower = name.toLowerAscii
  if lower in byName: return byName[lower]
  if lower.startsWith("readme"): return icon(0xF02D, fAnsi4)  # a book
  if lower.startsWith(".env"): return icon(0xF462, fAnsi3)
  let ext = lower.splitFile.ext
  if ext.len > 1 and ext[1..^1] in byExt: return byExt[ext[1..^1]]
  icon(plainFile, fComment)
