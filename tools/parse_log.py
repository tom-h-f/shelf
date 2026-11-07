"""Summarise a headless claude stream-json log: tool calls, errors, denials, result. Usage: python3 parse_log.py job.log"""
import json
import sys

tools, errors = [], []
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except json.JSONDecodeError:
        continue
    content = e.get("message", {}).get("content", []) if e.get("type") in ("assistant", "user") else []
    for c in content if isinstance(content, list) else []:
        if c.get("type") == "tool_use":
            i = c["input"]
            tools.append(f'{c["name"]}: {(i.get("description") or i.get("command") or i.get("file_path") or i.get("skill") or "")[:120]}')
        elif c.get("type") == "tool_result" and c.get("is_error"):
            errors.append(str(c.get("content"))[:240])
    if e.get("type") == "result":
        print(f'result: {e.get("subtype")}, turns {e.get("num_turns")}, ${e.get("total_cost_usd"):.3f}, {e.get("duration_ms", 0) / 1000:.0f}s')
        print("denials:", len(e.get("permission_denials") or []))
        for d in e.get("permission_denials") or []:
            print("   ", d["tool_name"], str(d["tool_input"])[:200])
        print(json.dumps(e.get("structured_output"), indent=1, ensure_ascii=False))
print(f"\n{len(tools)} tool calls:")
print("\n".join("  " + t for t in tools))
print(f"{len(errors)} tool errors:")
print("\n".join("  " + x for x in errors))
