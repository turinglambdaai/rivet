#!/usr/bin/env python3
"""Behavioral GTK4/AT-SPI gate for the packaged Taskboard reference app."""

import argparse
import json
import time
from pathlib import Path

import pyatspi


def children(node):
    for index in range(node.childCount):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            continue


def walk(node):
    yield node
    for child in children(node):
        yield from walk(child)


def role_name(node):
    try:
        return node.getRoleName()
    except Exception:
        return "unknown"


def text_value(node):
    try:
        text = node.queryText()
        return text.getText(0, text.characterCount)
    except Exception:
        return None


def snapshot(node, depth=0, maximum_depth=8):
    result = {
        "name": node.name or "",
        "role": role_name(node),
    }
    value = text_value(node)
    if value is not None:
        result["text"] = value
    if depth < maximum_depth:
        result["children"] = [
            snapshot(child, depth + 1, maximum_depth) for child in children(node)
        ]
    return result


def wait_for(description, predicate, timeout=30.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {description}")


def find_application(name):
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        if name.casefold() in (application.name or "").casefold():
            return application
    return None


def find_named(root, name, role=None):
    for node in walk(root):
        if (node.name or "") != name:
            continue
        if role is None or role_name(node) == role:
            return node
    return None


def press(node):
    actions = node.queryAction()
    if actions.nActions < 1 or not actions.doAction(0):
        raise AssertionError(f"AT-SPI action failed for {node.name!r}")


def is_enabled(node):
    try:
        return node.getState().contains(pyatspi.STATE_ENABLED)
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    application = wait_for(
        "the Taskboard AT-SPI application",
        lambda: find_application(args.application),
    )
    window = wait_for(
        "the Taskboard frame",
        lambda: next(
            (node for node in walk(application) if role_name(node) == "frame"),
            None,
        ),
    )
    required = {
        "Tasks": "list",
        "New task": "push button",
        "Generate 1,000 tasks": "push button",
        "Application status": "label",
    }
    for name, role in required.items():
        wait_for(
            f"accessible {role} named {name!r}",
            lambda name=name, role=role: find_named(window, name, role),
        )
    wait_for(
        "the ready native controls",
        lambda: all(
            is_enabled(find_named(window, name, "push button"))
            for name in ("New task", "Generate 1,000 tasks")
        ),
    )

    before = snapshot(application)
    (args.output / "accessibility-before.json").write_text(
        json.dumps(before, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    new_task_count = sum(1 for node in walk(window) if (node.name or "") == "New task")
    press(find_named(window, "New task", "push button"))
    wait_for(
        "the RPC-created task row",
        lambda: sum(
            1 for node in walk(window) if (node.name or "") == "New task"
        )
        > new_task_count,
    )

    status = find_named(window, "Application status", "label")
    press(find_named(window, "Generate 1,000 tasks", "push button"))
    observed_progress = []
    deadline = time.monotonic() + 6.0
    while time.monotonic() < deadline:
        value = text_value(status) or ""
        if value and (not observed_progress or value != observed_progress[-1]):
            observed_progress.append(value)
        if value.startswith("Preparing task "):
            break
        time.sleep(0.01)
    else:
        raise AssertionError(
            "operation-progress Event never reached the accessible status; "
            f"observed={observed_progress!r}"
        )

    wait_for(
        "the RPC-driven 1,000-row state",
        lambda: find_named(window, "Generated task 1000"),
        timeout=15.0,
    )
    after = snapshot(application)
    (args.output / "accessibility-after.json").write_text(
        json.dumps(after, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "interaction-trace.json").write_text(
        json.dumps(
            {
                "application": args.application,
                "actions": ["press:new-task", "press:generate-demo"],
                "observedStatus": observed_progress,
                "assertions": [
                    "native frame exposed",
                    "stable roles and names exposed",
                    "RPC-created task appeared",
                    "operation-progress Event appeared",
                    "1,000-row State reached the UI",
                ],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
