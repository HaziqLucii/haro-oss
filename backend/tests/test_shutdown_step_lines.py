"""The desktop app's closing screen reads ``[shutdown] <key> <n>ms [detail]`` lines from the
backend log (app/lib/backend/backend_steps.dart): one token for the key, ms, then free text."""

from __future__ import annotations

import re
import time

from haro import main

LINE = re.compile(r"^\[(boot|shutdown)\] (\S+) (\d+)ms(?: (.+))?$")


def test_a_shutdown_step_prints_one_parseable_line(capsys):
    main._shutdown_step("dev_servers", time.perf_counter(), "2")
    main._shutdown_step("snapshot", time.perf_counter())
    lines = capsys.readouterr().out.strip().splitlines()
    parsed = [LINE.match(line) for line in lines]
    assert all(parsed)
    assert [(m.group(2), m.group(4)) for m in parsed] == [("dev_servers", "2"), ("snapshot", None)]
