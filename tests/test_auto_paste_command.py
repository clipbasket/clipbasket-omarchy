#!/usr/bin/env python3
"""Auto-paste must insert the clipboard, never type it.

Typing via `wl-paste | wtype -` sends Return for every newline (which
submits chats and forms) and keystrokes each character (slow on long clips).
"""

from pathlib import Path

PANEL = Path(__file__).resolve().parents[1] / "Panel.qml"


def auto_paste_function_source() -> str:
    text = PANEL.read_text()
    start = text.index("function autoPasteCommand")
    # Function body ends at the first closing brace at the same indent as
    # `function` (two spaces), not a nested one.
    end = text.index("\n  }\n", start)
    return text[start : end + len("\n  }")]


def test_text_auto_paste_does_not_type_clipboard_contents() -> None:
    src = auto_paste_function_source()
    assert "wl-paste --no-newline | wtype -" not in src, (
        "text/url auto-paste still types the clipboard; newlines become Enter"
    )


def test_text_auto_paste_sends_a_paste_keystroke() -> None:
    src = auto_paste_function_source()
    # Omarchy's clipboard paste uses Shift+Insert so terminals and text
    # fields both insert clipboard contents without treating newlines as Enter.
    assert "wtype -M shift -k Insert -m shift" in src, (
        "text/url auto-paste must send Shift+Insert, not type the clip"
    )


if __name__ == "__main__":
    test_text_auto_paste_does_not_type_clipboard_contents()
    test_text_auto_paste_sends_a_paste_keystroke()
    print("ok")
