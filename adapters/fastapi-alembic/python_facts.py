#!/usr/bin/env python3
"""AST-backed Python facts. Reads JSON on stdin and writes JSON on stdout."""

import ast
import json
import sys


payload = json.load(sys.stdin)
mode = payload["mode"]
results = []

for record in payload["records"]:
    try:
        tree = ast.parse(record["content"], filename=record["path"])
    except SyntaxError as error:
        print(f"{record['path']}:{error.lineno}: Python syntax error", file=sys.stderr)
        raise SystemExit(30)

    if mode == "symbols":
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                results.append(
                    {
                        "path": record["path"],
                        "kind": "class" if isinstance(node, ast.ClassDef) else "function",
                        "name": node.name,
                        "line": node.lineno,
                    }
                )
    elif mode == "routes":
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for decorator in node.decorator_list:
                if not isinstance(decorator, ast.Call) or not isinstance(decorator.func, ast.Attribute):
                    continue
                method = decorator.func.attr.upper()
                if method not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}:
                    continue
                if not decorator.args or not isinstance(decorator.args[0], ast.Constant):
                    continue
                route = decorator.args[0].value
                if not isinstance(route, str):
                    continue
                results.append(
                    {
                        "path": record["path"],
                        "method": method,
                        "route": route,
                        "handler": node.name,
                        "line": getattr(decorator, "lineno", node.lineno),
                    }
                )
    else:
        print(f"unknown mode {mode!r}", file=sys.stderr)
        raise SystemExit(40)

results.sort(key=lambda item: (item["path"], item["line"], item.get("method", ""), item["name"] if "name" in item else item["route"]))
json.dump({mode: results, "parser": "python-ast-v1"}, sys.stdout, separators=(",", ":"))
