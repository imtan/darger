## Pure text selection, prompts and proposals for the agent writing commands.
import std/[unicode, strutils]

type
  WritingAction* = enum
    translateAuto, translateJapanese, translateEnglish, proofread, proofreadEnglish,
    rewriteFormal, rewriteCasual, summarizeRegion, summarizeBuffer, extractKeywords,
    suggestTitle, draftNotes, draftInteractive
  WritingSelection* = object
    a*, z*: int
    text*: string

proc containsJapanese*(text: string): bool =
  for rune in text.runes:
    let n = int(rune)
    if n in 0x3040..0x30ff or n in 0x31f0..0x31ff or
        n in 0x3400..0x4dbf or n in 0x4e00..0x9fff or
        n in 0xf900..0xfaff or n in 0xff66..0xff9f or
        n in 0x20000..0x323af:
      return true

proc writingSelection*(text: string, regionActive, markSet: bool,
                       region: tuple[a, z: int], whole = false): WritingSelection =
  let runes = text.toRunes
  result.z = runes.len
  if regionActive and markSet and not whole:
    result.a = clamp(min(region.a, region.z), 0, runes.len)
    result.z = clamp(max(region.a, region.z), result.a, runes.len)
  result.text = $runes[result.a..<result.z]

proc writingPrompt*(action: WritingAction, text: string, topic = ""): string =
  let instruction = case action
    of translateAuto:
      if containsJapanese(text): "Translate the following text into English."
      else: "以下の文章を日本語に翻訳してください。"
    of translateJapanese: "以下の文章を日本語に翻訳してください。"
    of translateEnglish: "Translate the following text into English."
    of proofread: "以下の文章を校正・推敲してください。文体・トーン・内容の骨子は変えずに、改善した文章のみを出力してください。"
    of proofreadEnglish: "Please proofread and refine the following English text. Output only the corrected text."
    of rewriteFormal: "より丁寧でフォーマルなビジネス文体に書き直してください。書き直した文章のみを出力してください。"
    of rewriteCasual: "Rewrite the following text in a casual, friendly tone. Output only the rewritten text."
    of summarizeRegion, summarizeBuffer: "以下の文章を箇条書きで要約してください。"
    of extractKeywords: "Extract keywords from the following text. Output comma-separated keywords on one line."
    of suggestTitle: "Suggest 3 title candidates for the following text, one per line."
    of draftNotes: "The following text is a set of notes. Write a blog draft in Markdown based on these notes."
    of draftInteractive: "Write a blog draft in Markdown about the topic below, using the following text as context.\nTopic: " & topic
  instruction & "\nOutput only the result. No code fences, no preamble or explanations.\n--- TEXT START ---\n" &
    text & "\n--- TEXT END ---\n"

proc writingProposal*(text: string, selection: WritingSelection, output: string,
                      insertAfter = false): string =
  let runes = text.toRunes
  var answer = output
  if insertAfter:
    # Put the result on its own lines without consuming any source characters.
    if answer.len > 0:
      if selection.z > 0 and runes[selection.z - 1] != Rune(10): answer = "\n" & answer
      if selection.z < runes.len and not answer.endsWith("\n"): answer.add "\n"
    return $runes[0..<selection.z] & answer & $runes[selection.z..<runes.len]
  # Ignore one CLI-added/missing final newline, retaining other whitespace.
  if answer.endsWith("\n") and not selection.text.endsWith("\n"):
    answer.setLen(answer.len - 1)
  elif selection.text.endsWith("\n") and not answer.endsWith("\n"):
    answer.add "\n"
  $runes[0..<selection.a] & answer & $runes[selection.z..<runes.len]
