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
        # GTK exposes the process/application name and the top-level window
        # title independently. The window title is the stable product-facing
        # identity and remains valid when a distribution renames the binary.
        for node in children(application):
            if (
                role_name(node) == "frame"
                and name.casefold() in (node.name or "").casefold()
            ):
                return application
    return None


def find_named(root, name, role=None):
    for node in walk(root):
        if (node.name or "") != name:
            continue
        if role is None or role_name(node) == role:
            return node
    return None


def find_described(root, description, role=None):
    """GTK's dynamic label text owns AX name; description stays stable."""
    for node in walk(root):
        try:
            if node.description != description:
                continue
            if role is None or role_name(node) == role:
                return node
        except Exception:
            continue
    return None


def selected_title(window):
    label = find_described(window, "Selected task title", "label")
    return text_value(label) if label is not None else None


def find_edit_draft(window):
    return find_described(window, "Task title draft")


def find_edit_error(window):
    return find_described(window, "Task edit error", "label")


def find_status(root):
    prefixes = (
        "Starting embedded Racket CS",
        "Loaded ",
        "Preparing task ",
        "Title updated for this session",
    )
    return next(
        (
            node
            for node in walk(root)
            if role_name(node) == "label"
            and (text_value(node) or "").startswith(prefixes)
        ),
        None,
    )


def press(node):
    actions = node.queryAction()
    if actions.nActions < 1 or not actions.doAction(0):
        raise AssertionError(f"AT-SPI action failed for {node.name!r}")


def edit_text(node, content):
    try:
        node.queryEditableText().setTextContents(content)
    except Exception as exc:
        raise AssertionError(
            f"native task title field is not AT-SPI editable: {exc}"
        ) from exc


def is_enabled(node):
    try:
        state = node.getState()
        # GTK 4.14 on Ubuntu 24.04 exposes actionable buttons as SENSITIVE
        # without also setting AT-SPI's optional ENABLED state. SENSITIVE is
        # the cross-toolkit state that means the control accepts input; newer
        # GTK releases commonly publish both.
        return state.contains(pyatspi.STATE_SENSITIVE) or state.contains(
            pyatspi.STATE_ENABLED
        )
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
    (args.output / "accessibility-discovered.json").write_text(
        json.dumps(snapshot(application), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    required = {
        "Tasks": "list",
        "New Task": "push button",
        "Generate 1,000": "push button",
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
            for name in ("New Task", "Generate 1,000")
        ),
    )

    before = snapshot(application)
    (args.output / "accessibility-before.json").write_text(
        json.dumps(before, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    new_task_count = sum(1 for node in walk(window) if (node.name or "") == "New task")
    press(find_named(window, "New Task", "push button"))
    wait_for(
        "the RPC-created task row",
        lambda: sum(
            1 for node in walk(window) if (node.name or "") == "New task"
        )
        > new_task_count,
    )

    # New Task's list row can become visible before the detail selection
    # settles; prove that the *selected* native detail actually changed.
    wait_for(
        "the new task selected in the detail pane",
        lambda: selected_title(window) == "New task",
    )

    # Real GTK4/AT-SPI draft/cancel/error/retry path. This touches the
    # packaged native app and sends real typed Racket RPCs, not a mock UI.
    def begin_edit():
        edit = wait_for(
            "enabled Edit title action",
            lambda: find_named(window, "Edit title", "push button")
            if (candidate := find_named(window, "Edit title", "push button"))
            and is_enabled(candidate)
            else None,
        )
        press(edit)
        return wait_for(
            "editable native title draft",
            lambda: find_edit_draft(window),
        )

    draft = begin_edit()
    edit_text(draft, "Discard via native AT-SPI")
    press(wait_for(
        "Discard draft action",
        lambda: find_named(window, "Discard draft", "push button"),
    ))
    wait_for(
        "discard preserves original selected title",
        lambda: selected_title(window) == "New task",
    )
    draft = begin_edit()
    edit_text(draft, "   ")
    press(wait_for(
        "Apply title action",
        lambda: find_named(window, "Apply for this session", "push button"),
    ))
    wait_for(
        "rejected backend edit keeps text and explains the error",
        lambda: (
            (field := find_edit_draft(window))
            and text_value(field) == "   "
            and (message := find_edit_error(window))
            and "Update failed; draft retained" in (text_value(message) or "")
            and is_enabled(field)
        ),
    )
    draft = find_edit_draft(window)
    edit_text(draft, "Edited via native AT-SPI")
    press(wait_for(
        "retry Apply action",
        lambda: find_named(window, "Apply for this session", "push button"),
    ))
    wait_for(
        "successful edit updates the selected detail title",
        lambda: selected_title(window) == "Edited via native AT-SPI",
    )

    status = wait_for("the live application status", lambda: find_status(window))
    press(find_named(window, "Generate 1,000", "push button"))
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
        lambda: text_value(status) == "Loaded 1000 tasks",
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
                "actions": [
                    "press:new-task", "edit:title", "discard:title",
                    "reject:empty-title", "retry:title", "apply:title",
                    "press:generate-demo",
                ],
                "observedStatus": observed_progress,
                "assertions": [
                    "native frame exposed",
                    "stable roles and names exposed",
                    "RPC-created task appeared",
                    "GTK4 edit draft cancel left the task unchanged",
                    "invalid title preserved the editable draft and reported failure",
                    "successful title reached Racket and the selected detail view",
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
