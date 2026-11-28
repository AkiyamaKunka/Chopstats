"""The restaurant-lookup knob defaults an owner reads are the code's.

docs/SERVER_DEPLOY.md (the knob table and the sentence above it) and
.env.example each state a default for the CLAUDE_LOOKUP_* knobs. An owner
sets up a server from those two files, not from the code, so a default
that changes in claude_analyzer.py or lookup_jobs.py must change there
too. These tests fail when one side moves without the other.

The same holds for the app's busy wait, CLAUDE_API_BUSY_WAIT_SECONDS
(2026-11-28), and for the answer memo, CLAUDE_API_ANSWER_MEMO_SECONDS
(2026-11-28): their tests are at the end of this file.
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
    The deploy guide and .env.example quote it, and so does SERVER.md,
    where it says that such a scan often does not get its answer in time.
    When the app changes the number, these sentences change with it, and
    the default wait is looked at again (tests/test_claude_analyzer.py
    compares the two)."""
    seconds = _iphone_scan_deadline()
    assert ("An iPhone background scan gives up on its request %d s after "
            "the scan began." % seconds) in " ".join(
                _read("docs", "SERVER_DEPLOY.md").split())
    assert ("it gives up on its request %d s after the scan began"
            % seconds) in " ".join(_read("docs", "SERVER.md").split())
    assert ("an iPhone background scan gives up on its request after %d s"
            % seconds) in " ".join(
                _read(".env.example").replace("\n# ", " ").split())


def test_the_guides_say_how_long_a_reply_can_take(monkeypatch):
    """A reply to the app can take the wait for a busy CLI and then one
    whole analysis. SERVER_TLS.md gives those numbers to whoever puts a
    proxy in front: it said "about two minutes", which was the analysis
    alone. And curl in the deploy guide's smoke test F must be given more
    than the longest case, or a slow pass is cut off and reads as a
    failure: its 170 s were set before the wait existed (review
    2026-11-28)."""
    monkeypatch.delenv("CLAUDE_ANALYZER_TIMEOUT_SECONDS", raising=False)
    analysis = claude_analyzer._timeout_seconds()
    wait = claude_analyzer.BUSY_WAIT_SECONDS_DEFAULT
    highest = claude_analyzer.BUSY_WAIT_SECONDS_MAX
    tls = " ".join(_read("docs", "SERVER_TLS.md").split())
    assert ("a photo or text analysis is given up to %d s" % analysis) in tls
    assert ("first waits for it, up to %d s." % wait) in tls
    assert ("So a reply can take up to %d s, and up to %d s with `%s` at "
            "its highest (%d)." % (analysis + wait, analysis + highest,
                                   BUSY_KNOB, highest)) in tls

    deploy = _read("docs", "SERVER_DEPLOY.md")
    limits = re.findall(
        r"curl -s -m (\d+) -o /tmp/photo_reply\.json[^\n]*\\\n"
        r"[^\n]*/api/analyze_photo\n", deploy)
    assert len(limits) == 1, limits
    assert int(limits[0]) > analysis + highest
    assert ("curl gives it %s s: the longest wait for a busy CLI, %d s, "
            "then one analysis at its limit, %d s" % (
                limits[0], highest, analysis)) in deploy


def test_the_deploy_guide_quotes_the_journal_lines_the_code_writes():
    """The busy-wait section tells the owner what to look for in the
    journal: the start of every line about a request that found another
    analysis on the CLI, and the line of a lookup that a request stopped
    (a Telegram photo that stopped one and then ran has no other line:
    tests/test_claude_analyzer.py). Both are the analyzer's own words."""
    guide = " ".join(_read("docs", "SERVER_DEPLOY.md").split())
    source = _read("claude_analyzer.py")
    for line in ("Claude CLI busy",
                 "Restaurant lookup pre-empted by a foreground request."):
        assert "`%s`" % line in guide, line
        assert '"%s' % line in source, line


# ─── CLAUDE_API_ANSWER_MEMO_SECONDS: the answer kept for the same request
# (2026-11-28) ─────────────────────────────────────────────────────────
#
# SERVER_DEPLOY.md gives the knob a table of its own ("The same photo
# again"), SERVER.md repeats the numbers in its response contract, and
# .env.example lists the knob after the busy wait.

MEMO_KNOB = "CLAUDE_API_ANSWER_MEMO_SECONDS"


def _knob_deploy_row(knob):
    """(default cell, meaning cell) of [knob]'s row in SERVER_DEPLOY.md."""
    rows = [m.groups() for m in (
        re.match(r"^\| `%s` \| ([^|]+) \| (.*) \|$" % knob, line)
        for line in _read("docs", "SERVER_DEPLOY.md").splitlines()) if m]
    assert len(rows) == 1, rows
    return rows[0][0].strip().strip("`"), rows[0][1]


def _knob_env_comment(knob):
    lines = re.findall(r"(?m)^# %s=\s*#\s*(.*)$" % knob,
                       _read(".env.example"))
    assert len(lines) == 1, lines
    return lines[0]


def _flat(text):
    return " ".join(text.replace("\n# ", " ").split())


def test_both_files_state_the_answer_memo_default_and_clamp(monkeypatch):
    monkeypatch.delenv(MEMO_KNOB, raising=False)
    default = claude_analyzer.answer_memo_seconds()
    assert default == claude_analyzer.ANSWER_MEMO_SECONDS_DEFAULT
    low, high = _clamp(claude_analyzer.answer_memo_seconds, monkeypatch,
                       MEMO_KNOB)
    assert (low, high) == (0, claude_analyzer.ANSWER_MEMO_SECONDS_MAX)

    cell, meaning = _knob_deploy_row(MEMO_KNOB)
    assert cell == str(default)
    assert "(%d–%d)" % (low, high) in meaning
    # 0 is a documented setting, not only the bottom of the clamp.
    assert "`0` switches it off" in meaning
    assert ("(%d, clamp %d..%d)" % (default, low, high)
            in _knob_env_comment(MEMO_KNOB))
    # The same systemd trap as the busy wait's: a comment after the value
    # makes it junk, and junk reads as the default, which is "on". The
    # journal's line for it is pinned in tests/test_answer_memo.py.
    advice = ("Write the number alone on its line: systemd keeps a comment "
              "after it as part of the value, the value is then not a "
              "number, and answers are still kept for %d s" % default)
    assert advice in meaning
    assert advice in _flat(_read(".env.example"))


def test_the_guides_state_the_answer_memo_numbers_the_code_uses():
    """How long an answer is kept and how many: in both guides and in
    .env.example, from the code's constants. The 10 minutes of the smoke
    test F paragraph and of the "on purpose" paragraph are the default,
    said in minutes."""
    seconds = claude_analyzer.ANSWER_MEMO_SECONDS_DEFAULT
    assert seconds % 60 == 0, seconds
    minutes = seconds // 60
    entries = claude_analyzer.ANSWER_MEMO_MAX_ENTRIES
    deploy = _flat(_read("docs", "SERVER_DEPLOY.md"))
    assert ("the default is %d s (%d minutes). At most %d answers are kept"
            % (seconds, minutes, entries)) in deploy
    assert "A repeat within %d minutes proves nothing new" % minutes in deploy
    assert ("A request you repeat on purpose within the %d minutes"
            % minutes) in deploy
    server = _flat(_read("docs", "SERVER.md"))
    assert ("keep each answer in memory for %d minutes" % minutes) in server
    assert ("(the default is %d s, at most %d answers)" % (seconds, entries)
            ) in server
    assert "at most %d answers" % entries in _flat(_read(".env.example"))


def test_the_memo_section_gives_the_iphone_scan_deadline_the_app_has():
    """The reason the memo exists is the app's deadline, as for the busy
    wait: the new section in the deploy guide quotes it too."""
    seconds = _iphone_scan_deadline()
    assert ("an iPhone background scan gives up on its request %d s after "
            "the scan began, and the app's own scan stops when you leave "
            "the app" % seconds) in _flat(_read("docs", "SERVER_DEPLOY.md"))


def test_the_deploy_guide_quotes_the_memo_line_the_code_writes(monkeypatch,
                                                               caplog):
    """The deploy guide's example of the journal's line for an answer
    from memory is what the analyzer writes for an answer 42 s old,
    word for word."""
    import logging
    monkeypatch.delenv(MEMO_KNOB, raising=False)
    now = [5000.0]
    monkeypatch.setattr(claude_analyzer, "_memo_clock", lambda: now[0])
    key = b"k" * 32
    claude_analyzer.clear_answer_memo()
    claude_analyzer._remember_answer(key, {"is_food": True})
    now[0] += 42
    with caplog.at_level(logging.INFO, logger="claude_analyzer"):
        assert claude_analyzer._remembered_answer(key, "photo") == {
            "is_food": True}
    claude_analyzer.clear_answer_memo()
    lines = [r.getMessage() for r in caplog.records
             if r.name == "claude_analyzer"]
    assert len(lines) == 1, lines
    assert "`%s`" % lines[0] in _flat(_read("docs", "SERVER_DEPLOY.md"))
    assert lines[0].startswith("Answered from memory — app photo request")


# ─── What the memo serves, and what the endpoints write (review
# 2026-11-28) ──────────────────────────────────────────────────────────

def _ios_background_gap_seconds():
    """How long after one iPhone background scan begins the next may: the
    frequency AppDelegate.swift registers with workmanager_apple, whose
    task handler (0.9.1+2, handlePeriodicTask) submits the next request
    that far ahead as each run starts."""
    found = re.findall(
        r"(?m)^\s*frequency: NSNumber\(value: (\d+) \* 60\)\)$",
        _read("app", "ios", "Runner", "AppDelegate.swift"))
    assert len(found) == 1, (
        "app/ios/Runner/AppDelegate.swift should register the background "
        "scan with exactly one `frequency: NSNumber(value: N * 60))` and "
        "has %d. The guides say the memo does not reach from one "
        "background scan to the next because of that gap: read it from "
        "where it is now." % len(found))
    return int(found[0]) * 60


def test_the_guides_say_the_memo_does_not_reach_the_next_background_scan():
    """The memo serves a photo sent again within its window: the open app,
    the app's retry, a copy behind its first. It does not serve one iPhone
    background scan to the next, which comes no sooner than the app's gap
    after one begins: past the default window. The guides said "the phone
    sends the same photo again at its next scan" and "That answer is not
    lost" (review 2026-11-28). Now they give the gap, from the app; and
    while the default window is not shorter than it, the sentence is not
    true, so this pin fails before the guides can say it."""
    gap = _ios_background_gap_seconds()
    assert gap % 60 == 0, gap
    assert claude_analyzer.ANSWER_MEMO_SECONDS_DEFAULT < gap
    sentence = ("no sooner than %d minutes after one begins" % (gap // 60))
    deploy = _flat(_read("docs", "SERVER_DEPLOY.md"))
    assert ("It does not serve one background scan to the next. The app "
            "asks iOS for the next background scan " + sentence) in deploy
    assert ("is past the default %d minutes, and it is analyzed again"
            % (claude_analyzer.ANSWER_MEMO_SECONDS_DEFAULT // 60)) in deploy
    assert "sends the same photo again at its next scan" not in deploy
    server = _flat(_read("docs", "SERVER.md"))
    assert ("It does not serve the next background scan: the app asks iOS "
            "for the next one " + sentence) in server
    assert "That answer is not lost" not in server
    assert sentence in _flat(_read(".env.example"))


def _app_string(key):
    """[key]'s English text in the app (app/lib/l10n/app_en.arb)."""
    import json
    return json.loads(_read("app", "lib", "l10n", "app_en.arb"))[key]


def test_the_deploy_guide_names_every_place_that_repeats_a_request():
    """A request repeated on purpose within the window gets the same
    answer back. The guide named two places that do that and missed the
    third, the one a user reaches for after a meal was taken for not food:
    Log › From recent photos picks the photo again, reads the same
    original bytes and sends the same request (review 2026-11-28). The
    names are the app's own."""
    deploy = _flat(_read("docs", "SERVER_DEPLOY.md"))
    start = deploy.index("A request you repeat on purpose within the")
    paragraph = deploy[start:deploy.index("Set the knob to `0`", start)]
    assert "Three places in the app do that" in paragraph
    for label in (_app_string("testProvider"),
                  _app_string("covAnalyzeAgain"),
                  "%s › %s" % (_app_string("fabLog"),
                               _app_string("addFromPhotos"))):
        assert "**%s**" % label in paragraph, label


def _api_view_docstring(name):
    """The docstring of the app endpoint [name] in telegram_bot.py."""
    import ast
    tree = ast.parse(_read("telegram_bot.py"))
    found = [ast.get_docstring(node) for node in ast.walk(tree)
             if isinstance(node, ast.FunctionDef) and node.name == name]
    assert len(found) == 1, found
    return found[0]


def test_the_guides_promise_no_meal_row_not_nothing_on_disk(monkeypatch):
    """An app analysis does leave files on the server, so the endpoints'
    contract is "no meal row, no ledger entry", and "nothing on disk" is
    said of the answer memo alone (review 2026-11-28). The two reasons, as
    the code has them:

      * the photo, leftover and text runs start the CLI without
        --no-session-persistence, which only the lookup passes; without it
        the CLI saves each session to disk (claude --help), and a photo
        run's session holds the prompt and the photo;
      * the GLM path writes the photo to a temp file for its run.

    When neither holds any more, this pin changes with the guides."""
    seen = []

    def run(cmd, **kwargs):
        seen.append(cmd)
        if "--mcp-config" in cmd:
            path = re.search(r"image file at (\S+), then answer",
                             cmd[2]).group(1)
            with open(path, "rb") as f:
                seen.append(f.read())
        return type("Proc", (), {"returncode": 1, "stdout": "",
                                 "stderr": ""})()

    for knob in ("CLAUDE_ANALYZER_EXTRA_FLAGS", "CLAUDE_ANALYZER_MODEL"):
        monkeypatch.delenv(knob, raising=False)
    monkeypatch.setenv("GLM_PLAN_KEY", "test-plan-key")
    monkeypatch.setattr(claude_analyzer, "_npx_path",
                        lambda: "/usr/local/bin/npx")
    monkeypatch.setattr(claude_analyzer.subprocess, "run", run)
    photo = b"\xff\xd8\xff" + b"a photo"
    claude_analyzer._attempt_stream("/usr/local/bin/claude", photo, {}, 0.0,
                                    "the prompt")
    claude_analyzer._attempt_glm_vision("/usr/local/bin/claude", photo, {},
                                        0.0, "the prompt")
    stream, glm, glm_file = seen
    assert "--input-format" in stream
    assert "--no-session-persistence" not in stream
    assert "--no-session-persistence" in claude_analyzer.build_lookup_argv(
        "claude", "{}", "sonnet")
    assert "--mcp-config" in glm and glm_file == photo

    server = _flat(_read("docs", "SERVER.md"))
    assert ("analysis routes are *pure* — they return the analysis and "
            "write no meal row and no ledger entry;") in server
    deploy = _read("docs", "SERVER_DEPLOY.md")
    assert ("# F. one whole analysis through the API (ONE plan run; no meal "
            "row): expect http 200") in deploy
    for text in (server, _flat(deploy)):
        assert "nothing to disk" not in text
        assert "writes nothing to disk" not in text
    doc = _api_view_docstring("api_analyze_photo")
    assert "no meal row, no ledger entry, no Telegram card:" in doc
    assert "disk" not in doc
    # The memo itself keeps nothing on disk, and the guides say so of it.
    assert ("The memo holds only the answer and a hash of the request, "
            "never the photo, and only in memory: none of it goes to disk"
            ) in _flat(deploy)
