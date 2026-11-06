#!/usr/bin/env python3
"""Validate Theme4Logic per-Logic hook manifests."""

from __future__ import annotations

import json
import sys
from pathlib import Path


REQUIRED_TOP_LEVEL = {
    "schemaVersion": int,
    "logicBundleIdentifier": str,
    "logicVersion": str,
    "logicBuild": str,
    "allowHooks": bool,
    "appKitHooks": list,
    "requiredAppKitHooks": list,
    "privateHooks": list,
    "probe": dict,
}


def _fail(path: Path, message: str) -> None:
    raise SystemExit(f"{path}: {message}")


def validate_manifest(path: Path) -> None:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        _fail(path, f"invalid JSON: {exc}")

    if not isinstance(data, dict):
        _fail(path, "manifest must be a JSON object")

    for key, typ in REQUIRED_TOP_LEVEL.items():
        if not isinstance(data.get(key), typ):
            _fail(path, f"{key} must be {typ.__name__}")

    if data["schemaVersion"] != 2:
        _fail(path, "schemaVersion must be 2")
    if data["logicBundleIdentifier"] != "com.apple.logic10":
        _fail(path, "logicBundleIdentifier must be com.apple.logic10")
    expected_name = f"logic-{data['logicVersion']}-hooks.json"
    if path.name != expected_name:
        _fail(path, f"filename must be {expected_name}")
    if not data["allowHooks"]:
        _fail(path, "checked release manifests must set allowHooks=true")

    appkit_hooks = data["appKitHooks"]
    if not appkit_hooks or not all(isinstance(h, str) and h for h in appkit_hooks):
        _fail(path, "appKitHooks must contain non-empty selector strings")
    if len(set(appkit_hooks)) != len(appkit_hooks):
        _fail(path, "appKitHooks must not contain duplicate selectors")
    required_appkit_hooks = data["requiredAppKitHooks"]
    if not required_appkit_hooks or not all(
        isinstance(h, str) and h for h in required_appkit_hooks
    ):
        _fail(path, "requiredAppKitHooks must contain non-empty selector strings")
    if len(set(required_appkit_hooks)) != len(required_appkit_hooks):
        _fail(path, "requiredAppKitHooks must not contain duplicate selectors")
    unknown_required = set(required_appkit_hooks) - set(appkit_hooks)
    if unknown_required:
        _fail(path, f"requiredAppKitHooks are not approved: {sorted(unknown_required)}")

    seen: set[tuple[str, str, str]] = set()
    for index, hook in enumerate(data["privateHooks"]):
        if not isinstance(hook, dict):
            _fail(path, f"privateHooks[{index}] must be an object")
        kind = hook.get("kind")
        class_name = hook.get("class")
        selector = hook.get("selector")
        if kind not in {"class", "instance", "interpose"}:
            _fail(path, f"privateHooks[{index}].kind is invalid")
        if not isinstance(class_name, str) or not class_name:
            _fail(path, f"privateHooks[{index}].class must be non-empty")
        if not isinstance(selector, str) or not selector:
            _fail(path, f"privateHooks[{index}].selector must be non-empty")
        key = (kind, class_name, selector)
        if key in seen:
            _fail(path, f"duplicate private hook: {kind} {class_name} {selector}")
        seen.add(key)

    if not seen:
        _fail(path, "privateHooks must not be empty")

    probe = data["probe"]
    for key in ("source", "checkedAt", "checkedBy"):
        if not isinstance(probe.get(key), str) or not probe[key]:
            _fail(path, f"probe.{key} must be non-empty")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_hook_manifests.py <manifest-dir>", file=sys.stderr)
        return 2
    root = Path(argv[1])
    manifests = sorted(root.glob("logic-*-hooks.json"))
    if not manifests:
        print(f"{root}: no hook manifests found", file=sys.stderr)
        return 1
    for manifest in manifests:
        validate_manifest(manifest)
    print(f"validated {len(manifests)} hook manifest(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
