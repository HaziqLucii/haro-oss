"""A run can be an app on a phone or emulator: the rail then shows a phone card and no browser
address. The kind comes from ``[scripts.run.<id>] kind`` or is guessed from the command."""

from __future__ import annotations

import pytest

from haro import config, lifecycle


@pytest.mark.parametrize(
    "command,kind,expected",
    [
        ('serial=$(sh .haro/device.sh) && flutter run -d "$serial"', None, True),
        ("flutter run", None, True),
        ("flutter run -d chrome", None, False),
        ("flutter run -d web-server --web-port 4000", None, False),
        ("flutter run -d linux", None, False),
        ("flutter run --device-id chrome", None, False),
        ("flutter run --device-id=linux", None, False),
        ("flutter run -d=macos", None, False),
        ("npx react-native run-android", None, False),
        ("npx react-native run-android", "device", True),
        ("npm run dev", None, False),
        ("npm run dev", "device", True),
        ("flutter run", "web", False),
        ("flutter run", "bogus", True),
    ],
)
def test_is_device_run(command, kind, expected):
    assert lifecycle.is_device_run(command, kind) is expected


def test_the_kind_is_read_from_the_run_table():
    runs = config._parse_run_scripts(
        {
            "app": {"command": "flutter run", "default": True, "kind": "Device"},
            "docs": {"command": "npm run docs", "kind": "web"},
            "odd": {"command": "x", "kind": "nonsense"},
            "plain": "npm start",
        }
    )
    assert [(r.id, r.kind) for r in runs] == [
        ("app", "device"), ("docs", "web"), ("odd", None), ("plain", None),
    ]
