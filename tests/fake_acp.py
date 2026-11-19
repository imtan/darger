#!/usr/bin/env python3
"""Offline ACP v1 fixture. No packages, credentials or network access."""
import json
import os
import sys

sid = "fake-session"
next_id = 100
prompt_id = None


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value), ensure_ascii=False), flush=True)


def result(id, value):
    send(dict(id=id, result=value))


def update(update_kind, **fields):
    send(dict(method="session/update", params=dict(sessionId=sid, update=dict(sessionUpdate=update_kind, **fields))))


def receive():
    line = sys.stdin.readline()
    if not line:
        raise SystemExit(0)
    msg = json.loads(line)
    with open("wire.jsonl", "a") as log:
        log.write(line)
    return msg


def rpc(method, **params):
    global next_id
    next_id += 1
    id = next_id
    send(dict(id=id, method=method, params=dict(sessionId=sid, **params)))
    while True:
        msg = receive()
        if msg.get("method") == "session/cancel":
            continue
        assert msg.get("id") == id, msg
        return msg


while True:
    msg = receive()
    method = msg.get("method")
    if method == "initialize":
        assert msg["params"]["protocolVersion"] == 1
        assert msg["params"]["clientCapabilities"] == dict(fs=dict(readTextFile=True, writeTextFile=True), terminal=True)
        result(msg["id"], dict(protocolVersion=1, agentCapabilities=dict(loadSession=True)))
    elif method == "session/new":
        assert os.path.realpath(msg["params"]["cwd"]) == os.getcwd()
        assert msg["params"]["mcpServers"] == []
        result(msg["id"], dict(sessionId=sid))
    elif method == "session/load":
        assert msg["params"]["sessionId"] == sid
        update("agent_message_chunk", content=dict(type="text", text="Restored"))
        result(msg["id"], {})
    elif method == "session/cancel":
        result(prompt_id, dict(stopReason="cancelled"))
    elif method == "session/prompt":
        prompt_id = msg["id"]
        text = msg["params"]["prompt"][0]["text"]
        if text == "cancel":
            continue
        if text.startswith("write"):
            read = rpc("fs/read_text_file", path=os.getcwd() + "/file.txt", line=1, limit=1)
            assert read["result"]["content"] == "unsaved\n", read
            update("agent_message_chunk", content=dict(type="text", text="Hello "))
            update("agent_message_chunk", content=dict(type="text", text="world"))
            update("agent_thought_chunk", content=dict(type="text", text="Thinking quietly"))
            update("plan", entries=[dict(content="Edit", status="in_progress")])
            update("tool_call", toolCallId="edit", title="Edit file", kind="edit", status="pending",
                   content=[dict(type="diff", path=os.getcwd() + "/file.txt", oldText="unsaved\n", newText="changed\n")])
            permission = rpc("session/request_permission", toolCall=dict(toolCallId="edit"),
                             options=[dict(optionId="yes", name="Allow once", kind="allow_once"),
                                      dict(optionId="no", name="Reject", kind="reject_once")])
            if permission["result"]["outcome"].get("optionId") == "yes":
                written = rpc("fs/write_text_file", path=os.getcwd() + "/file.txt", content="changed\n")
                update("agent_message_chunk", content=dict(type="text", text=" WRITE_OK" if "result" in written else " WRITE_REJECTED"))
            else:
                update("agent_message_chunk", content=dict(type="text", text=" PERMISSION_CANCELLED"))
        elif text == "terminal":
            created = rpc("terminal/create", command="/bin/sh", args=["-c", "printf 'terminal 日本語\\n'"],
                          env=[dict(name="ACP_TEST", value="a b")], outputByteLimit=100)
            if "result" in created:
                tid = created["result"]["terminalId"]
                waited = rpc("terminal/wait_for_exit", terminalId=tid)
                assert waited["result"]["exitCode"] == 0
                output = rpc("terminal/output", terminalId=tid)
                assert "日本語" in output["result"]["output"], output
                rpc("terminal/kill", terminalId=tid)
                rpc("terminal/release", terminalId=tid)
                update("agent_message_chunk", content=dict(type="text", text="TERMINAL_OK"))
            else:
                update("agent_message_chunk", content=dict(type="text", text="TERMINAL_REJECTED"))
        elif text in ("new", "empty"):
            written = rpc("fs/write_text_file", path=os.getcwd() + "/" + text + ".txt",
                          content="new content\n" if text == "new" else "")
            assert "result" in written, written
            update("agent_message_chunk", content=dict(type="text", text="CREATED"))
        elif text == "outside":
            denied = rpc("fs/read_text_file", path="/etc/passwd")
            assert "error" in denied
            update("agent_message_chunk", content=dict(type="text", text="OUTSIDE_DENIED"))
        elif "コードはまだ変更せず" in text:
            denied = rpc("fs/write_text_file", path=os.getcwd() + "/file.txt", content="bad")
            assert "error" in denied
            denied = rpc("terminal/create", command="false")
            assert "error" in denied
            update("agent_message_chunk", content=dict(type="text", text="# Plan\nTest first\n"))
        else:
            update("agent_message_chunk", content=dict(type="text", text="Approved " + text))
        result(prompt_id, dict(stopReason="end_turn"))
