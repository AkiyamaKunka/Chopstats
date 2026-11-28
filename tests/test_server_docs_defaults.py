"""The restaurant-lookup knob defaults an owner reads are the code's.

docs/SERVER_DEPLOY.md (the knob table and the sentence above it) and
.env.example each state a default for the CLAUDE_LOOKUP_* knobs. An owner
sets up a server from those two files, not from the code, so a default
that changes in claude_analyzer.py or lookup_jobs.py must change there
too. These tests fail when one side moves without the other.

The same holds for the app's busy wait, CLAUDE_API_BUSY_WAIT_SECONDS
(2026-11-28): its tests are at the end of this file.
"""
import os
import re

import pytest

import claude_analyzer
import lookup_jobs

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# knob -> the default the code uses, as the two files print it
CODE_DEFAULTS = {
    "CLAUDE_LOOKUP_MODEL": claude_analyzer.LOOKUP_MODEL_DEFAULT,
    "CLAUDE_LOOKUP_TIMEOUT_SECONDS": str(
        claude_analyzer.LOOKUP_TIMEOUT_SECONDS_DEFAULT),
    "CLAUDE_LOOKUP_INIT_SECONDS": str(
        claude_analyzer.LOOKUP_INIT_DEADLINE_SECONDS),
    "CLAUDE_LOOKUP_DAILY_CAP": str(lookup_jobs.DAILY_CAP_DEFAULT),
    "CLAUDE_LOOKUP_KEY_SOURCE": ",".join(
        claude_analyzer.LOOKUP_KEY_SOURCES_DEFAULT),
}


def _read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def _deploy_table():
    """{knob: (default cell, meaning cell)} from SERVER_DEPLOY.md."""
    rows = {}
    for line in _read("docs", "SERVER_DEPLOY.md").splitlines():
        m = re.match(r"^\| `(CLAUDE_LOOKUP_[A-Z_]+)` \| ([^|]+) \| (.*) \|$",
                     line)
        if m:
            assert m.group(1) not in rows, "knob listed twice: " + m.group(1)
            rows[m.group(1)] = (m.group(2).strip().strip("`"), m.group(3))
    return rows


def _env_example_lines():
    """{knob: its comment} from the commented knob lines of .env.example."""
    rows = {}
    for line in _read(".env.example").splitlines():
        m = re.match(r"^# (CLAUDE_LOOKUP_[A-Z_]+)=\s*#\s*(.*)$", line)
        if m:
            assert m.group(1) not in rows, "knob listed twice: " + m.group(1)
            rows[m.group(1)] = m.group(2)
    return rows


def _clamp(fn, monkeypatch, knob):
    """(lowest, highest) value [fn] returns for [knob]."""
    monkeypatch.setenv(knob, "-999999")
    low = fn()
    monkeypatch.setenv(knob, "999999")
    return low, fn()


def test_both_files_list_every_lookup_knob():
    knobs = set(CODE_DEFAULTS) | {"CLAUDE_LOOKUP_ENABLED"}
    assert set(_deploy_table()) == knobs
    assert set(_env_example_lines()) == knobs


@pytest.mark.parametrize("knob", sorted(CODE_DEFAULTS))
def test_deploy_guide_states_the_code_default(knob):
    assert _deploy_table()[knob][0] == CODE_DEFAULTS[knob]


def test_deploy_guide_says_the_endpoints_are_off_by_default(monkeypatch):
    monkeypatch.delenv("CLAUDE_LOOKUP_ENABLED", raising=False)
    assert lookup_jobs.is_enabled() is False
    assert _deploy_table()["CLAUDE_LOOKUP_ENABLED"][0] == "off"
    assert "(default off" in _env_example_lines()["CLAUDE_LOOKUP_ENABLED"]


def test_deploy_guide_states_the_code_clamps(monkeypatch):
    table = _deploy_table()
    low, high = _clamp(claude_analyzer.lookup_timeout_seconds, monkeypatch,
                       "CLAUDE_LOOKUP_TIMEOUT_SECONDS")
    assert "(%d–%d)" % (low, high) in table["CLAUDE_LOOKUP_TIMEOUT_SECONDS"][1]
    low, high = _clamp(claude_analyzer.lookup_init_deadline_seconds,
                       monkeypatch, "CLAUDE_LOOKUP_INIT_SECONDS")
    assert "(%d–%d)" % (low, high) in table["CLAUDE_LOOKUP_INIT_SECONDS"][1]


def test_deploy_guide_sentence_names_the_default_limit():
    text = " ".join(_read("docs", "SERVER_DEPLOY.md").split())
    assert ("the default limit is %d s"
            % claude_analyzer.LOOKUP_TIMEOUT_SECONDS_DEFAULT) in text


def test_env_example_states_the_code_defaults_and_clamps(monkeypatch):
    lines = _env_example_lines()
    assert lines["CLAUDE_LOOKUP_MODEL"].startswith(
        "%s (default)" % claude_analyzer.LOOKUP_MODEL_DEFAULT)
    for knob, fn in (
            ("CLAUDE_LOOKUP_TIMEOUT_SECONDS",
             claude_analyzer.lookup_timeout_seconds),
            ("CLAUDE_LOOKUP_INIT_SECONDS",
             claude_analyzer.lookup_init_deadline_seconds),
            ("CLAUDE_LOOKUP_DAILY_CAP", lookup_jobs.daily_cap)):
        low, high = _clamp(fn, monkeypatch, knob)
        assert ("(%s, clamp %d..%d)" % (CODE_DEFAULTS[knob], low, high)
                in lines[knob]), knob
    assert ("(%s)" % CODE_DEFAULTS["CLAUDE_LOOKUP_KEY_SOURCE"]
            in lines["CLAUDE_LOOKUP_KEY_SOURCE"])


# ─── CLAUDE_API_BUSY_WAIT_SECONDS: the app's wait for a busy CLI ────────
#
# SERVER_DEPLOY.md gives the knob a table of its own ("Two app requests
# at once"), SERVER.md repeats the numbers in its response contract, and
# .env.example lists the knob with the other analyzer knobs.

BUSY_KNOB = "CLAUDE_API_BUSY_WAIT_SECONDS"


def _busy_deploy_row():
    """(default cell, meaning cell) of the knob's row in SERVER_DEPLOY.md."""
    rows = [m.groups() for m in (
        re.match(r"^\| `%s` \| ([^|]+) \| (.*) \|$" % BUSY_KNOB, line)
        for line in _read("docs", "SERVER_DEPLOY.md").splitlines()) if m]
    assert len(rows) == 1, rows
    return rows[0][0].strip().strip("`"), rows[0][1]


def _busy_env_comment():
    lines = re.findall(r"(?m)^# %s=\s*#\s*(.*)$" % BUSY_KNOB,
                       _read(".env.example"))
    assert len(lines) == 1, lines
    return lines[0]


def test_both_files_state_the_busy_wait_default_and_clamp(monkeypatch):
    monkeypatch.delenv(BUSY_KNOB, raising=False)
    default = claude_analyzer.busy_wait_seconds()
    assert default == claude_analyzer.BUSY_WAIT_SECONDS_DEFAULT
    low, high = _clamp(claude_analyzer.busy_wait_seconds, monkeypatch,
                       BUSY_KNOB)
    assert (low, high) == (0, claude_analyzer.BUSY_WAIT_SECONDS_MAX)

    cell, meaning = _busy_deploy_row()
    assert cell == str(default)
    assert "(%d–%d)" % (low, high) in meaning
    # 0 is a documented setting, not only the bottom of the clamp.
    assert "`0` switches the wait off" in meaning
    assert "(%d, clamp %d..%d)" % (default, low, high) in _busy_env_comment()
    # Under systemd a comment after the number is part of the value, the
    # value is then junk, and junk reads as the default: `…=0   # off`
    # left the wait on. Both entries say so, with the default (review
    # 2026-11-28). The journal's line for it is pinned in
    # tests/test_claude_analyzer.py.
    advice = ("Write the number alone on its line: systemd keeps a comment "
              "after it as part of the value, the value is then not a "
              "number, and the wait stays at %d s" % default)
    assert advice in meaning
    assert advice in " ".join(
        _read(".env.example").replace("\n# ", " ").split())


def test_the_guides_state_the_busy_wait_numbers_the_code_uses():
    """The default wait, how many requests may wait, and the Retry-After
    of the busy 503: said in both guides. .env.example says how many may
    wait as well (its default and clamp are pinned above)."""
    wait = "the default wait is %d s" % claude_analyzer.BUSY_WAIT_SECONDS_DEFAULT
    places = "at most %d requests wait" % claude_analyzer.BUSY_WAIT_MAX_WAITERS
    header = "`Retry-After: %d`" % claude_analyzer.BUSY_RETRY_AFTER_SECONDS
    for name in ("SERVER_DEPLOY.md", "SERVER.md"):
        text = " ".join(_read("docs", name).split())
        assert wait in text, name
        assert places in text.lower(), name
        assert header in text, name
    assert places in " ".join(
        _read(".env.example").replace("\n# ", " ").split())


def _iphone_scan_deadline():
    """Seconds after which an iPhone background scan gives up on a request
    still running: iosRunDeadline in the app's background scan code."""
    found = re.findall(
        r"(?m)^const Duration iosRunDeadline = Duration\(seconds: (\d+)\);$",
        _read("app", "lib", "ui", "background_glue.dart"))
    assert len(found) == 1, (
        "app/lib/ui/background_glue.dart should have exactly one line "
        "`const Duration iosRunDeadline = Duration(seconds: N);` and has "
        "%d. The guides quote that deadline as the reason to keep the "
        "wait near 20 s: read it from where it is now." % len(found))
    return int(found[0])


def test_the_guides_give_the_iphone_scan_deadline_the_app_has():
    """The reason to keep the wait near 20 s is a number of the app's, not
    of the server's: how long an iPhone background scan gives its request.
    The deploy guide and .env.example quote it. When the app changes it,
    these sentences change with it, and the default wait is looked at
    again (tests/test_claude_analyzer.py compares the two)."""
    seconds = _iphone_scan_deadline()
    assert ("An iPhone background scan gives up on its request %d s after "
            "the scan began." % seconds) in " ".join(
                _read("docs", "SERVER_DEPLOY.md").split())
    assert ("an iPhone background scan gives up on its request after %d s"
            % seconds) in " ".join(
                _read(".env.example").replace("\n# ", " ").split())
