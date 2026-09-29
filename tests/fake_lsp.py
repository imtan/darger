#!/usr/bin/env python3
"""A fake language server for tests/tlsp.nim: stdio by default, --tcp PORT to listen.

Diagnostics: every TODO word is a warning "todo left", every ERROR word an error
"error word". Positions are UTF-16 code units, as LSP requires."""
import json
import re
import socket
import sys
import urllib.parse

WORDS = ["printf", "print", "private", "target"]
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def u16(s):
    return len(s.encode("utf-16-le")) // 2


def index(line, units):
    """The str index of a UTF-16 column."""
    n = 0
    for i, ch in enumerate(line):
        if n >= units:
            return i
        n += u16(ch)
    return len(line)


def rng(line_no, line, a, z):
    return {"start": {"line": line_no, "character": u16(line[:a])},
            "end": {"line": line_no, "character": u16(line[:z])}}


class Server:
    def __init__(self, rd, wr):
        self.rd, self.wr, self.docs = rd, wr, {}

    def send(self, msg):
        body = json.dumps(msg).encode()
        self.wr.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.wr.flush()

    def read(self):
        length = None
        while True:
            line = self.rd.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            key, _, value = line.decode().partition(":")
            if key.strip().lower() == "content-length":
                length = int(value)
        return json.loads(self.rd.read(length))

    def lines(self, uri):
        return self.docs.get(uri, "").split("\n")

    def publish(self, uri):
        diags = []
        for n, line in enumerate(self.lines(uri)):
            for m in WORD.finditer(line):
                if m.group() == "TODO":
                    diags.append({"range": rng(n, line, m.start(), m.end()), "severity": 2,
                                  "message": "todo left", "source": "fake"})
                elif m.group() == "ERROR":
                    diags.append({"range": rng(n, line, m.start(), m.end()), "severity": 1,
                                  "message": "error word", "source": "fake", "code": 7})
        # Re-encoded like clangd does, leaving ':' unescaped.
        uri = "file://" + urllib.parse.quote(urllib.parse.unquote(uri[7:]), safe="/:")
        self.send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                   "params": {"uri": uri, "diagnostics": diags}})

    def word_at(self, params):
        pos = params["position"]
        line = self.lines(params["textDocument"]["uri"])[pos["line"]]
        i = index(line, pos["character"])
        for m in WORD.finditer(line):
            if m.start() <= i <= m.end():
                return m.group(), line[m.start():i]
        return "", ""

    def locations(self, uri, word):
        out = []
        for n, line in enumerate(self.lines(uri)):
            for m in WORD.finditer(line):
                if m.group() == word:
                    out.append({"uri": uri, "range": rng(n, line, m.start(), m.end())})
        return out

    def answer(self, method, params):
        if method == "initialize":
            return {"capabilities": {
                "textDocumentSync": 1,
                "completionProvider": {"triggerCharacters": ["."]},
                "hoverProvider": True, "definitionProvider": True,
                "referencesProvider": True, "documentFormattingProvider": True}}
        if method == "shutdown":
            return None
        if method == "textDocument/completion":
            _, prefix = self.word_at(params)
            pos = params["position"]
            start = {"line": pos["line"], "character": pos["character"] - u16(prefix)}
            items = []
            for w in WORDS:
                if not w.startswith(prefix):
                    continue
                item = {"label": w, "kind": 3, "detail": "fake"}
                if w == "printf":  # a snippet
                    item.update(insertTextFormat=2, insertText="printf(${1:fmt}, ${2|a,b|})$0")
                elif w == "print":  # an edit replacing the prefix
                    item["textEdit"] = {"range": {"start": start, "end": pos}, "newText": "print()"}
                items.append(item)
            return {"isIncomplete": False, "items": items}
        if method == "textDocument/hover":
            word, _ = self.word_at(params)
            return {"contents": {"kind": "plaintext", "value": "hover for " + word}} if word else None
        uri = params["textDocument"]["uri"]
        if method == "textDocument/definition":
            found = self.locations(uri, "target")
            return found[0] if found else None
        if method == "textDocument/references":
            word, _ = self.word_at(params)
            return self.locations(uri, word)
        if method == "textDocument/formatting":
            edits = []
            for n, line in enumerate(self.lines(uri)):
                kept = line.rstrip(" ")
                if kept != line:
                    edits.append({"range": rng(n, line, len(kept), len(line)), "newText": ""})
            return edits
        raise KeyError(method)

    def serve(self):
        """Handles messages until exit (True) or end of input (False)."""
        while True:
            msg = self.read()
            if msg is None:
                return False
            method, params = msg.get("method"), msg.get("params") or {}
            if "id" in msg:
                if method is None or method == "test/hang":
                    continue  # a response to one of our requests, or never answered
                try:
                    self.send({"jsonrpc": "2.0", "id": msg["id"], "result": self.answer(method, params)})
                except KeyError:
                    self.send({"jsonrpc": "2.0", "id": msg["id"],
                               "error": {"code": -32601, "message": "unknown " + method}})
            elif method == "exit":
                return True
            elif method in ("textDocument/didOpen", "textDocument/didChange"):
                doc = params["textDocument"]
                text = doc["text"] if method.endswith("didOpen") else params["contentChanges"][-1]["text"]
                self.docs[doc["uri"]] = text
                self.publish(doc["uri"])
            elif method == "textDocument/didClose":
                self.docs.pop(params["textDocument"]["uri"], None)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--tcp":
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", int(sys.argv[2])))
        listener.listen(4)
        while True:  # like Godot, keep serving after a client disconnects
            conn, _ = listener.accept()
            if Server(conn.makefile("rb"), conn.makefile("wb")).serve():
                return
            conn.close()
    Server(sys.stdin.buffer, sys.stdout.buffer).serve()


if __name__ == "__main__":
    main()
