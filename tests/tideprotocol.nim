import std/[json, strutils, unittest, sequtils]
import ../src/ideprotocol

proc masked*(text: string, opcode = 1, final = true): string =
  result = wsFrame(text, opcode)
  if not final: result[0] = char(ord(result[0]) and 127)
  result[1] = char(ord(result[1]) or 128)
  let offset = if text.len < 126: 2 elif text.len <= 65535: 4 else: 10
  result = result[0..<offset] & "abcd" & text
  for i in 0..<text.len: result[offset+4+i] = char(ord(text[i]) xor ord("abcd"[i mod 4]))

suite "IDE protocol":
  test "RFC 6455 handshake and authentication":
    check wsAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nx-claude-code-ide-authorization: secret\r\n\r\n"
    check handshake(request, "secret").startsWith("HTTP/1.1 101")
    check handshake(request, "other").startsWith("HTTP/1.1 401")
    check handshake(request.replace("Version: 13", "Version: 12"), "secret").startsWith("HTTP/1.1 400")
    check handshake(request.replace("dGhlIHNhbXBsZSBub25jZQ==", "bad"), "secret").startsWith("HTTP/1.1 400")
    check handshake(request.replace("keep-alive, Upgrade", "notupgrade"), "secret").startsWith("HTTP/1.1 400")
  test "partial frames, masking and extended lengths":
    for length in [0, 1, 125, 126, 65535, 65536]:
      let payload = repeat("x", length)
      let wire = masked(payload)
      var input = wire[0..<wire.len-1]
      var frame: WsFrame
      check not takeFrame(input, frame)
      input.add wire[^1]
      check takeFrame(input, frame)
      check frame.payload == payload and frame.final and frame.opcode == 1
      check input.len == 0
  test "fragmentation with interleaved ping, unicode and close":
    var decoder: WsDecoder
    check decoder.message(WsFrame(opcode: 1, final: false, payload: "\xe6\x97")) == ""
    check decoder.message(WsFrame(opcode: 9, final: true, payload: "ping")) == ""
    check decoder.message(WsFrame(opcode: 0, final: true, payload: "\xa5本")) == "日本"
    expect ValueError: discard decoder.message(WsFrame(opcode: 0, final: true))
    expect ValueError: discard decoder.message(WsFrame(opcode: 1, final: true, payload: "\xff"))
    var frame: WsFrame
    var wire = masked("\x03\xe8done", 8)
    check takeFrame(wire, frame) and frame.opcode == 8
  test "reject malformed and oversized frames before allocation":
    for wire in [wsFrame("unmasked"), masked("x", 2), masked("x", 9, false), masked("x", 8), masked("\x03\xed", 8), "\x81\xff\x7f\xff\xff\xff\xff\xff\xff\xffabcd"]:
      var input = wire
      var frame: WsFrame
      expect ValueError: discard takeFrame(input, frame)
  test "lock schema and final edited diff contents":
    let info = lockInfo(42, @["/tmp/project"], repeat("a", 32))
    check info["pid"].getInt == 42 and info["ideName"].getStr == "darger"
    check info["transport"].getStr == "ws" and info["workspaceFolders"][0].getStr == "/tmp/project"
    check diffResult(true, "edited", "tab")["content"][1]["text"].getStr == "edited"
    check diffResult(false, "edited", "tab")["content"][0]["text"].getStr == "DIFF_REJECTED"
  test "JSON-RPC validation, allowlist, notifications and deferred results":
    let specs = toolSpecs(@["openDiff", "getCurrentSelection"])
    var called = false
    let handler: ToolHandler = proc(name: string, args, id: JsonNode): JsonNode =
      called = true
      if name == "openDiff": nil else: toolText("selection")
    check dispatchRpc("{", specs, handler)["error"]["code"].getInt == -32700
    for invalid in ["null", "[]", "{}", "{\"jsonrpc\":\"2.0\",\"id\":1}"]:
      check dispatchRpc(invalid, specs, handler)["error"]["code"].getInt == -32600
    check dispatchRpc($notification("notifications/initialized", newJObject()), specs, handler) == nil
    check not called
    let init = dispatchRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", specs, handler)
    check init["result"]["serverInfo"]["name"].getStr == "darger"
    let list = dispatchRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", specs, handler)
    check list["result"]["tools"].len == 2
    proc call(name: string, args = newJObject()): JsonNode =
      dispatchRpc($(%*{"jsonrpc": "2.0", "id": "x", "method": "tools/call", "params": {"name": name, "arguments": args}}), specs, handler)
    check call("darger_buffer_text")["error"]["code"].getInt == -32602
    check call("openDiff")["error"]["code"].getInt == -32602
    check not called
    check call("openDiff", %*{"old_file_path": "a", "new_file_path": "a", "tab_name": "t", "new_file_contents": 42})["error"]["code"].getInt == -32602
    check call("openDiff", %*{"old_file_path": "a", "new_file_path": "a", "tab_name": "t", "new_file_contents": "new"}) == nil
    check called
    check call("getCurrentSelection")["id"].getStr == "x"
    check toolSpecs(@ideToolNames).len == 18
