#!/usr/bin/env python3
"""Parse a Claude Code JSONL transcript to extract the last prompt context and options.

Reads the transcript file (last ~50 lines for performance), finds the last
assistant message, and extracts:
- AskUserQuestion tool_use: question text + options as buttons
- Otherwise: last text block (truncated to ~200 chars)

Outputs JSON to stdout:
  {"context": "...", "options": [{"label": "...", "callback_data": "0"}, ...]}
"""

import json
import sys
from collections import deque


def tail_lines(filepath, n=50):
    """Read last n lines of a file. JSONL lines can be very large, so we
    use a deque to keep memory bounded while reading the full file."""
    d = deque(maxlen=n)
    with open(filepath, "r", errors="replace") as f:
        for line in f:
            d.append(line)
    return list(d)


def extract_context(transcript_path):
    lines = tail_lines(transcript_path, 50)

    # Parse all JSONL lines, collecting messages and tool_result IDs
    parsed = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        parsed.append(obj)

    assistant_messages = []
    # Collect tool_use_ids that have a tool_result (i.e., already answered)
    answered_tool_ids = set()
    for obj in parsed:
        msg = obj.get("message", {})
        role = msg.get("role", "")
        if role == "assistant":
            assistant_messages.append(msg)
        elif role == "user":
            for block in msg.get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    tid = block.get("tool_use_id", "")
                    if tid:
                        answered_tool_ids.add(tid)

    if not assistant_messages:
        return {"context": "Claude Code is waiting for your input.", "options": []}

    # Scan backward for a PENDING AskUserQuestion (no tool_result yet).
    for msg in reversed(assistant_messages):
        content_blocks = msg.get("content", [])
        for block in content_blocks:
            if block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                if block.get("id", "") in answered_tool_ids:
                    break  # already answered, stop scanning
                inp = block.get("input", {})
                questions = inp.get("questions", [])
                if not questions:
                    continue

                q = questions[0]
                question_text = q.get("question", "Claude is asking a question")
                options_raw = q.get("options", [])

                context = f"Claude is asking:\n\n{question_text}"
                options = []
                for i, opt in enumerate(options_raw):
                    label = opt.get("label", f"Option {i+1}")
                    # Telegram callback_data max 64 bytes; use index
                    options.append({"label": label, "callback_data": str(i)})

                return {"context": context, "options": options}

    # No pending AskUserQuestion — extract last text block
    last_msg = assistant_messages[-1]
    content_blocks = last_msg.get("content", [])
    for block in reversed(content_blocks):
        if block.get("type") == "text":
            text = block.get("text", "").strip()
            if text:
                truncated = text[:200] + ("…" if len(text) > 200 else "")
                return {"context": f"Claude says:\n\n{truncated}", "options": []}

    return {"context": "Claude Code is waiting for your input.", "options": []}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"context": "Claude Code is waiting for your input.", "options": []}))
        sys.exit(0)

    transcript_path = sys.argv[1]
    try:
        result = extract_context(transcript_path)
    except Exception:
        result = {"context": "Claude Code is waiting for your input.", "options": []}

    print(json.dumps(result))
