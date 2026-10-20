import std/strutils
import ../src/writing

for text in ["こんにちは", "カタカナ", "漢字", "ｶﾅ", "𠮷", "Englishと日本語"]:
  doAssert containsJapanese(text)
for text in ["", "Hello world", "café 😀", "한글"]:
  doAssert not containsJapanese(text)
let text = "前😀日本語後\n"
let selected = writingSelection(text, true, true, (2, 5))
doAssert selected.text == "日本語"
doAssert selected.a == 2 and selected.z == 5
doAssert writingSelection(text, true, true, (5, 2)).text == "日本語"
for flags in [(false, true), (true, false), (false, false)]:
  doAssert writingSelection(text, flags[0], flags[1], (2, 5)).text == text
doAssert writingSelection(text, true, true, (2, 5), whole = true).text == text
doAssert writingSelection("", false, false, (0, 0)).text == ""
doAssert writingSelection(text, true, true, (2, 2)).text == ""
doAssert writingProposal(text, selected, "Japanese\n") == "前😀Japanese後\n"
doAssert writingProposal(text, selected, "  Japanese  \n") == "前😀  Japanese  後\n"
doAssert writingProposal(text, selected, "Japanese\n\n") == "前😀Japanese\n後\n"
let whole = writingSelection(text, false, false, (0, 0))
doAssert writingProposal(text, whole, "English") == "English\n"
doAssert writingProposal(text, whole, "English\n") == "English\n"
doAssert writingProposal(text, selected, "- summary\n", true) == "前😀日本語\n- summary\n後\n"
doAssert writingProposal(text, whole, "- summary", true) == text & "- summary"
let noNewline = writingSelection("abc", false, false, (0, 0))
doAssert writingProposal("abc", noNewline, "key", true) == "abc\nkey"
doAssert writingProposal(text, selected, "", true) == text
doAssert writingProposal("", writingSelection("", false, false, (0, 0)), "draft\n") == "draft"
doAssert writingPrompt(translateAuto, "日本語").contains("into English")
doAssert writingPrompt(translateAuto, "English").contains("日本語に翻訳")
doAssert writingPrompt(translateJapanese, "日本語").contains("日本語に翻訳")
doAssert writingPrompt(translateEnglish, "English").contains("into English")
doAssert writingPrompt(draftInteractive, "notes", "my topic").contains("Topic: my topic")
for action in WritingAction:
  let prompt = writingPrompt(action, "source text")
  doAssert prompt.contains("source text")
  doAssert prompt.contains("Output only the result. No code fences, no preamble")
echo "writing ok"
