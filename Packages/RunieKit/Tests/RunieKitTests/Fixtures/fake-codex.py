#!/usr/bin/env python3
"""Подставной `codex app-server` для тестов: отвечает по протоколу на одно сообщение."""
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

thread = "01aa0000-0000-7000-8000-000000000001"
for line in sys.stdin:
    msg = json.loads(line)
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake"}})
    elif method == "thread/start" or method == "thread/resume":
        tools = [t["name"] for t in msg["params"].get("dynamicTools", [])]
        send({"id": mid, "result": {"thread": {"id": thread}, "model": "gpt-test", "cwd": "/tmp", "tools": tools}})
    elif method == "account/rateLimits/read":
        send({"id": mid, "result": {"rateLimits": {"primary": {"usedPercent": 12, "resetsAt": 1800000000}}}})
    elif method == "model/list":
        send({"id": mid, "result": {"data": [{"id": "gpt-test", "model": "gpt-test", "displayName": "GPT Test", "description": "d"}]}})
    elif method == "turn/start":
        send({"id": mid, "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
        send({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": "turn-1"}}})
        send({"method": "item/started", "params": {"item": {"type": "commandExecution", "id": "cmd-1", "command": "/bin/zsh -lc 'rm -rf /tmp/x'"}}})
        send({"method": "item/commandExecution/requestApproval", "id": 900, "params": {"itemId": "cmd-1", "command": "/bin/zsh -lc 'rm -rf /tmp/x'"}})
    elif mid == 900 and "result" in msg:
        decision = msg["result"]["decision"]
        send({"method": "item/completed", "params": {"item": {"type": "commandExecution", "id": "cmd-1", "status": "completed" if decision == "accept" else "declined", "exitCode": 0, "aggregatedOutput": decision}}})
        send({"method": "item/started", "params": {"item": {"type": "agentMessage", "id": "msg-1"}}})
        send({"method": "item/agentMessage/delta", "params": {"itemId": "msg-1", "delta": "Гото"}})
        send({"method": "item/agentMessage/delta", "params": {"itemId": "msg-1", "delta": "во"}})
        send({"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": "msg-1", "text": "Готово"}}})
        send({"method": "thread/tokenUsage/updated", "params": {"tokenUsage": {"last": {"totalTokens": 5000}, "modelContextWindow": 200000}}})
        send({"method": "turn/completed", "params": {"turn": {"id": "turn-1", "status": "completed", "durationMs": 10}}})
