"""The answer memo (2026-11-28): an app photo or leftover request sent
again gets the answer the server already worked out.

Why it exists. The server runs one Claude analysis at a time, and it
cannot see a phone hang up: the handler runs to its end. An iPhone
background scan gives up on its request 22 s after it began, and the open
app's scan stops when its user leaves it. The server then finished the
analysis and threw the answer away, and the phone sent the same photo
again at its next scan: a second full run on the owner's plan.

The contract these tests hold (claude_analyzer, the section above
analyze_text_prompt):

  * only /api/analyze_photo and /api/analyze_leftover use it; Telegram,
    /upload and /api/text_intent never do;
  * the key is a SHA-256 over everything that goes into the run, and over
    nothing a caller sends that the server ignores;
  * only a successful analysis is kept, in memory, for
    CLAUDE_API_ANSWER_MEMO_SECONDS (600 by default, 0 = off), at most 64
    answers, the oldest dropped first;
  * it is looked up before the request waits for the CLI (a hit takes no
    lock and is no waiter) and again once the request holds the lock;
  * a hit is the same 200 body as an analysis, with one journal line that
    says how old the answer is and nothing else;
  * any text a caller can send gives a key, a lone surrogate included;
  * the memo reads its clock with its lock held;
  * a sign-in from the phone empties it, and an analysis that was running
    through the sign-in is not kept.

Through the real endpoints and the real analyzer: only the CLI process
(subprocess.run), the memo's clock and, where a test needs it, the wait
for the CLI's lock or the memo's own lock are stood in for. No test
sleeps: time moves on the stand-in clock, and threads are followed
through events.
"""
import ast
import base64
import hashlib
import inspect
import json
import logging
import os
import socket
import struct
import subprocess
import threading
from types import SimpleNamespace

import pytest

import claude_analyzer
import telegram_bot


KEY = {"X-API-Key": "secret-key"}
KNOB = "CLAUDE_API_ANSWER_MEMO_SECONDS"

ANSWER = {"is_food": True, "meal_description": "Char siu rice",
          "total_calories": 640, "total_protein_g": 32, "total_carbs_g": 80,
          "total_fat_g": 20,
          "food_items": [{"name": "char siu", "estimated_calories": 340},
                         {"name": "rice", "estimated_calories": 300}]}

JPEG = b"\xff\xd8\xff" + b"the lunch photo"
OTHER_JPEG = b"\xff\xd8\xff" + b"another photo"

ORIGINAL = json.dumps({
    "meal_description": "Char siu rice", "total_calories": 640,
    "food_items": [{"name": "rice", "estimated_calories": 300}]})


def _b64(data):
    return base64.b64encode(data).decode()


def _photo_body(**over):
    """The app's photo request (ServerAnalyzer.buildRequest): the image,
    the dietary profile, the day's earlier meals, the reply language and
    the plan. A value of None leaves that field out."""
    body = {"image_b64": _b64(JPEG),
            "dietary_profile": "Cantonese home cooking",
            "recent_meals": [{"time": "08:10", "meal_description": "Congee",
                              "total_calories": 300,
                              "food_items": [{"name": "congee",
                                              "estimated_calories": 300}]}],
            "lang": "zh",
            "backend": "claude"}
    body.update(over)
    return {k: v for k, v in body.items() if v is not None}


def _leftover_body(**over):
    """The app's leftover request (ServerAnalyzer.leftoverIntent)."""
    body = {"image_b64": _b64(JPEG), "original_analysis": ORIGINAL,
            "backend": "claude"}
    body.update(over)
    return {k: v for k, v in body.items() if v is not None}


# (path, body builder, the reply's answer field, the journal's word)
ENDPOINTS = [
    ("/api/analyze_photo", _photo_body, "analysis", "photo"),
    ("/api/analyze_leftover", _leftover_body, "leftover", "leftover"),
]
ENDPOINT_IDS = ["photo", "leftover"]


def _stream_reply(answer_text):
    return SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
        "type": "result", "subtype": "success", "is_error": False,
        "result": answer_text, "num_turns": 1}))


class _FakeCli:
    """subprocess.run for the analyzer: records each start, and answers
    ANSWER unless a behaviour is queued for that start. With [go] set to
    an Event, a run waits for it (the analysis "takes time")."""

    def __init__(self):
        self.starts = []
        self.behaviours = []
        self.entered = threading.Event()
        self.go = None
        self._lock = threading.Lock()

    def __call__(self, cmd, **kwargs):
        with self._lock:
            self.starts.append({"cmd": cmd, "input": kwargs.get("input")})
            behaviour = self.behaviours.pop(0) if self.behaviours else None
        self.entered.set()
        if self.go is not None:
            assert self.go.wait(10), "the test never let the analysis end"
        if behaviour is not None:
            return behaviour(cmd, kwargs)
        return _stream_reply(json.dumps(ANSWER))


def _fake_cli(monkeypatch):
    """The real analyzer with only the CLI process stood in for, every
    knob at its default."""
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    for knob in ("CLAUDE_ANALYZER_DISPATCH", "CLAUDE_API_BUSY_WAIT_SECONDS",
                 KNOB, "CLAUDE_ANALYZER_MODEL",
                 "CLAUDE_ANALYZER_EXTRA_FLAGS"):
        monkeypatch.delenv(knob, raising=False)
    monkeypatch.setattr(claude_analyzer.shutil, "which",
                        lambda *a, **k: "/usr/local/bin/claude")
    cli = _FakeCli()
    monkeypatch.setattr(claude_analyzer.subprocess, "run", cli)
    return cli


class _Clock:
    def __init__(self, monkeypatch, start=1000.0):
        self.now = start
        monkeypatch.setattr(claude_analyzer, "_memo_clock", lambda: self.now)

    def advance(self, seconds):
        self.now += seconds


def _memo_lines(caplog):
    return [r.getMessage() for r in caplog.records
            if r.name == "claude_analyzer"
            and r.getMessage().startswith("Answered from memory")]


# ─── A hit, and the limit ─────────────────────────────────────────────

@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_the_same_request_inside_the_limit_runs_no_cli(
        client, monkeypatch, caplog, path, body, field, word):
    """The next scan sends the photo again 599 s later: the same 200 body,
    byte for byte, and no CLI run. The journal says how old the answer is
    and nothing about it: no food, no hash."""
    cli = _fake_cli(monkeypatch)
    clock = _Clock(monkeypatch)
    first = client.http.post(path, headers=KEY, json=body())
    assert first.status_code == 200
    assert first.get_json()[field] == ANSWER
    assert len(cli.starts) == 1

    clock.advance(599)
    with caplog.at_level(logging.INFO, logger="claude_analyzer"):
        again = client.http.post(path, headers=KEY, json=body())
    assert again.status_code == 200
    assert again.get_data() == first.get_data()
    assert again.headers["Content-Type"] == first.headers["Content-Type"]
    assert len(cli.starts) == 1, "the photo was analyzed a second time"
    assert _memo_lines(caplog) == [
        f"Answered from memory — app {word} request: the answer is 599 s "
        "old, and the CLI did not run."]
    (key,) = list(claude_analyzer._ANSWER_MEMO)
    for secret in ("Char siu", "char siu", "640", key.hex(), key.hex()[:16],
                   _b64(JPEG)):
        assert secret not in caplog.text, secret


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_the_same_request_past_the_limit_is_analyzed_again(
        client, monkeypatch, path, body, field, word):
    """At the limit (600 s) the answer still counts; a moment past it the
    request is analyzed again, and that new answer is the one kept."""
    cli = _fake_cli(monkeypatch)
    clock = _Clock(monkeypatch)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    clock.advance(600)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    assert len(cli.starts) == 1
    clock.advance(0.5)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    assert len(cli.starts) == 2, "an answer past its limit was handed out"
    clock.advance(10)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    assert len(cli.starts) == 2, "the second answer was not kept"
    assert len(claude_analyzer._ANSWER_MEMO) == 1


# ─── The key ──────────────────────────────────────────────────────────

# name -> (path, body) of a request that differs from the base photo
# request in that one part. The base has no model and no effort (the
# server's default), so that a model or an effort is one change.
_ONE_PART_CHANGED = {
    "image": ("/api/analyze_photo",
              lambda: _photo_body(image_b64=_b64(OTHER_JPEG))),
    "profile": ("/api/analyze_photo",
                lambda: _photo_body(dietary_profile="Vegetarian")),
    "recent meals": ("/api/analyze_photo", lambda: _photo_body(recent_meals=[
        {"time": "08:10", "meal_description": "Congee and a fried dough "
         "stick", "total_calories": 520,
         "food_items": [{"name": "congee", "estimated_calories": 300},
                        {"name": "youtiao", "estimated_calories": 220}]}])),
    "language": ("/api/analyze_photo", lambda: _photo_body(lang=None)),
    "backend": ("/api/analyze_photo", lambda: _photo_body(backend="doubao")),
    "model": ("/api/analyze_photo", lambda: _photo_body(model="sonnet")),
    "effort": ("/api/analyze_photo", lambda: _photo_body(effort="low")),
    "endpoint": ("/api/analyze_leftover", _leftover_body),
    "upload key": ("/api/analyze_photo", _photo_body),
}


@pytest.mark.parametrize("part", sorted(_ONE_PART_CHANGED))
def test_each_part_that_goes_into_the_run_changing_is_a_miss(
        client, monkeypatch, part):
    """Each of these can change the answer: the photo; the profile, the
    day's earlier meals (the leftover check) and the reply language, which
    are all in the composed prompt; the plan, model and effort; the
    endpoint; and which of the two accepted upload keys sent it. Each
    change is a run of its own, and neither answer replaces the other."""
    cli = _fake_cli(monkeypatch)
    monkeypatch.setenv("DOUBAO_PLAN_KEY", "test-plan-key")
    monkeypatch.setattr(telegram_bot, "ANDROID_API_KEY_RETIRING",
                        "retiring-key")
    path, body = _ONE_PART_CHANGED[part]
    headers = {"X-API-Key": "retiring-key"} if part == "upload key" else KEY

    assert client.http.post("/api/analyze_photo", headers=KEY,
                            json=_photo_body()).status_code == 200
    assert len(cli.starts) == 1
    assert client.http.post(path, headers=headers,
                            json=body()).status_code == 200
    assert len(cli.starts) == 2, f"a request with another {part} was a hit"
    # Both are kept, each under its own key.
    assert client.http.post("/api/analyze_photo", headers=KEY,
                            json=_photo_body()).status_code == 200
    assert client.http.post(path, headers=headers,
                            json=body()).status_code == 200
    assert len(cli.starts) == 2
    assert len(claude_analyzer._ANSWER_MEMO) == 2


def test_what_the_server_ignores_does_not_split_the_memo(client, monkeypatch):
    """A field the server does not read, the client header, a blank
    profile, a model or effort sent as "", and a field inside a recent meal
    that the whitelist drops: none of them changes the run, so none of
    them may make the same photo a second run."""
    cli = _fake_cli(monkeypatch)
    base = _photo_body(dietary_profile=None)
    assert client.http.post("/api/analyze_photo", headers=KEY,
                            json=base).status_code == 200
    meal = dict(base["recent_meals"][0], total_protein_g=12,
                photo_md5="0123abcd")
    for headers, body in [
            (dict(KEY, **{"X-Client-Platform": "ios"}), base),
            (KEY, dict(base, photo_id="IMG_0042", scan="background")),
            (KEY, dict(base, dietary_profile="   ")),
            (KEY, dict(base, model="", effort="")),
            (KEY, dict(base, recent_meals=[meal]))]:
        resp = client.http.post("/api/analyze_photo", headers=headers,
                                json=body)
        assert resp.status_code == 200
        assert resp.get_json()["analysis"] == ANSWER
    assert len(cli.starts) == 1
    assert len(claude_analyzer._ANSWER_MEMO) == 1


def test_the_key_covers_each_part_and_lets_none_run_together():
    """At the key itself: one change of any part is another key, the
    endpoint alone too (the endpoint test above also changes the prompt).
    The parts are length-prefixed, so ("ab", "c") is not ("a", "bc"). A
    model or effort that the run does not use (_plan_choice) is no part.
    No scope, no key: the call has no memo."""
    base = dict(kind="photo", scope=("analyze_photo", "current"),
                image_bytes=JPEG, prompt="the composed prompt",
                backend="claude", model=None, effort=None,
                read_fallback=False)

    def key(**over):
        return claude_analyzer._answer_memo_key(**dict(base, **over))

    first = key()
    assert isinstance(first, bytes) and len(first) == 32
    assert key() == first
    seen = {first}
    for over in ({"kind": "leftover"},
                 {"scope": ("analyze_leftover", "current")},
                 {"scope": ("analyze_photo", "retiring")},
                 {"image_bytes": JPEG + b"."},
                 {"prompt": "the composed prompt."},
                 {"backend": "doubao"},
                 {"model": "sonnet"},
                 {"effort": "low"},
                 {"read_fallback": True}):
        other = key(**over)
        assert other not in seen, over
        seen.add(other)
    assert key(model="not-a-plan-model") == first
    assert key(effort="max") == first
    assert key(backend="glm", model="sonnet", effort="low") == key(
        backend="glm")
    assert key(scope=("ab", "c")) != key(scope=("a", "bc"))
    assert key(prompt="ab", image_bytes=b"c") != key(prompt="a",
                                                      image_bytes=b"bc")
    assert key(scope=None) is None


# ─── Caller text that strict UTF-8 cannot encode ─────────────────────
#
# A lone surrogate is a str Python holds and strict UTF-8 refuses to
# encode. JSON carries one as an escape (`\ud83c`), and json.loads reads
# it back as one. The app writes one that way: dart:convert's jsonEncode
# escapes an unpaired surrogate, and the leftover compact cuts a long
# meal_description at 200 UTF-16 units (compactOriginalAnalysis in
# app/lib/core/leftover_logic.dart), which can split an emoji in two.
# main analyzed such a request; the memo's key turned it into a 500 that
# the app retried at every scan (review 2026-11-28).

LONE = "\ud83c"        # the first half of a food emoji, cut off
OTHER_LONE = "\ud83d"  # the first half of another one

# where the text is -> (path, the request with [lone] in that place)
_LONE_SURROGATE_REQUESTS = {
    "profile": ("/api/analyze_photo", lambda lone: _photo_body(
        dietary_profile="No pork " + lone)),
    "recent meal": ("/api/analyze_photo", lambda lone: _photo_body(
        recent_meals=[{"time": "08:10", "meal_description": "Congee " + lone,
                       "total_calories": 300,
                       "food_items": [{"name": "congee",
                                       "estimated_calories": 300}]}])),
    "leftover original": ("/api/analyze_leftover", lambda lone: _leftover_body(
        original_analysis=json.dumps({
            "meal_description": "Char siu rice " + lone,
            "total_calories": 640,
            "food_items": [{"name": "rice", "estimated_calories": 300}]}))),
}


@pytest.mark.parametrize("where", sorted(_LONE_SURROGATE_REQUESTS))
def test_a_lone_surrogate_in_caller_text_is_analyzed_and_remembered(
        client, monkeypatch, where):
    """A lone surrogate in the profile, in a recent meal or in the leftover
    request's meal is analyzed as on main: a 200, and the CLI is given the
    text. The key stays exact: the same request again is a hit, and one
    with another lone surrogate is a run of its own."""
    cli = _fake_cli(monkeypatch)
    path, build = _LONE_SURROGATE_REQUESTS[where]

    def send(lone):
        raw = json.dumps(build(lone))  # ensure_ascii: escapes, as Dart's
        assert "\\" + "ud83" in raw and lone not in raw
        return client.http.post(path, headers=KEY, data=raw,
                                content_type="application/json")

    first = send(LONE)
    assert first.status_code == 200, first.get_data(as_text=True)[:200]
    assert len(cli.starts) == 1
    assert "\\" + "ud83c" in cli.starts[0]["input"]
    again = send(LONE)
    assert again.status_code == 200
    assert again.get_data() == first.get_data()
    assert len(cli.starts) == 1, "the same request was analyzed again"
    other = send(OTHER_LONE)
    assert other.status_code == 200
    assert len(cli.starts) == 2, "another lone surrogate was a hit"
    assert len(claude_analyzer._ANSWER_MEMO) == 2


def test_the_key_takes_any_text_python_can_hold():
    """At the key itself: lone surrogates of either half give a key, each
    its own, and none is the key of the text without it. Two lone halves
    side by side are not the character they would make together; the
    JSON reader never gives that pair as two (it joins an escaped pair
    into one character), and two keys for one prompt cost a run at most."""
    def key(prompt):
        return claude_analyzer._answer_memo_key(
            "photo", ("analyze_photo", "current"), JPEG, prompt, "claude",
            None, None, read_fallback=False)

    # Joined at run time: a literal "🍔" is the one character.
    halves = "No pork " + LONE + "\udf54"
    assert len(halves) == len("No pork ") + 2
    texts = ["No pork", "No pork " + LONE, "No pork " + OTHER_LONE,
             "No pork \udf54", halves, "No pork \U0001f354"]
    keys = [key(text) for text in texts]
    assert all(isinstance(k, bytes) and len(k) == 32 for k in keys)
    assert len(set(keys)) == len(texts)
    assert key("No pork " + LONE) == keys[1]


# ─── Only a success is kept ──────────────────────────────────────────

def _plan_refused(cmd, kwargs):
    return SimpleNamespace(returncode=1, stderr="", stdout=json.dumps({
        "type": "result", "is_error": True, "api_error_status": 429,
        "result": "You have hit your usage limit."}))


def _timed_out(cmd, kwargs):
    raise subprocess.TimeoutExpired(cmd, 120)


def _junk(cmd, kwargs):
    return _stream_reply("I cannot see a meal in this picture.")


def _empty_object(cmd, kwargs):
    return _stream_reply("{}")


# failure -> (how the CLI behaves, None for "busy"; the reply's "retry")
_FAILURES = {
    "busy": (None, True),
    "plan refused": (_plan_refused, "later"),
    "timed out": (_timed_out, "later"),
    "junk reply": (_junk, False),
    "empty reply": (_empty_object, False),
}


@pytest.mark.parametrize("failure", sorted(_FAILURES))
@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_a_failed_request_is_not_kept(client, monkeypatch, path, body, field,
                                      word, failure):
    """A busy, refused, timed-out or empty answer is never kept: the same
    request afterwards is analyzed, and that success is kept."""
    cli = _fake_cli(monkeypatch)
    behaviour, retry = _FAILURES[failure]
    if behaviour is None:
        # Another analysis holds the CLI for longer than the wait.
        real_wait = claude_analyzer._wait_for_cli
        monkeypatch.setattr(claude_analyzer, "_wait_for_cli",
                            lambda seconds: False)
        assert claude_analyzer._CLI_LOCK.acquire(blocking=False)
        try:
            failed = client.http.post(path, headers=KEY, json=body())
        finally:
            claude_analyzer._CLI_LOCK.release()
        monkeypatch.setattr(claude_analyzer, "_wait_for_cli", real_wait)
    else:
        cli.behaviours.append(behaviour)
        failed = client.http.post(path, headers=KEY, json=body())
    assert failed.status_code == 503
    assert failed.get_json()["retry"] == retry
    assert len(claude_analyzer._ANSWER_MEMO) == 0
    runs = len(cli.starts)

    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    assert len(cli.starts) == runs + 1
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    assert len(cli.starts) == runs + 1, "the success was not kept"


def test_a_kept_answer_is_a_copy_both_ways(monkeypatch):
    """The Telegram path writes analyzed_by into the dict it gets back,
    and a caller may change what it was handed. Neither reaches the kept
    answer: it is copied in, and copied out at each hit."""
    cli = _fake_cli(monkeypatch)
    scope = ("analyze_photo", "current")

    def analyze():
        return claude_analyzer.analyze_food_photo(
            JPEG, "the composed prompt", allow_file_fallback=False,
            raise_on_busy=True, memo_scope=scope)

    first = analyze()
    first["analyzed_by"] = "claude"
    first["food_items"].append({"name": "egg", "estimated_calories": 90})
    second = analyze()
    assert second == ANSWER
    second["food_items"].clear()
    assert analyze() == ANSWER
    assert len(cli.starts) == 1


# ─── Bounds and the knob ─────────────────────────────────────────────

def test_at_most_64_answers_are_kept_the_oldest_dropped_first(monkeypatch):
    """A fixed bound, oldest stored first out; a lookup does not make an
    answer younger. An answer past the limit is dropped at the next store
    even when the memo is not full. A failure (None, {}) and a call with
    no key keep nothing."""
    monkeypatch.delenv(KNOB, raising=False)
    clock = _Clock(monkeypatch)
    assert claude_analyzer.ANSWER_MEMO_MAX_ENTRIES == 64
    keys = [hashlib.sha256(b"request %d" % i).digest() for i in range(66)]
    for i in range(65):
        claude_analyzer._remember_answer(keys[i], {"n": i})
        clock.advance(1)
    memo = claude_analyzer._ANSWER_MEMO
    assert len(memo) == 64
    assert claude_analyzer._remembered_answer(keys[0], "photo") is None
    assert claude_analyzer._remembered_answer(keys[1], "photo") == {"n": 1}
    claude_analyzer._remember_answer(keys[65], {"n": 65})
    assert len(memo) == 64
    assert claude_analyzer._remembered_answer(keys[1], "photo") is None
    assert claude_analyzer._remembered_answer(keys[2], "photo") == {"n": 2}

    claude_analyzer.clear_answer_memo()
    claude_analyzer._remember_answer(keys[0], {"n": 0})
    clock.advance(500)
    claude_analyzer._remember_answer(keys[1], {"n": 1})
    clock.advance(150)  # the first is now 650 s old, the second 150 s
    claude_analyzer._remember_answer(keys[2], {"n": 2})
    assert list(memo) == [keys[1], keys[2]]

    for answer in (None, {}, [ANSWER], "text"):
        claude_analyzer._remember_answer(keys[3], answer)
    claude_analyzer._remember_answer(None, {"n": 4})
    assert list(memo) == [keys[1], keys[2]]


class _LockThatLetsAStoreInFirst:
    """A stand-in for _ANSWER_MEMO_LOCK. The first time it is taken,
    [first] runs before the real lock is: another thread's store that got
    to the lock first, as the scheduler may order them."""

    def __init__(self, first):
        self._lock = threading.Lock()
        self._first = first

    def __enter__(self):
        first, self._first = self._first, None
        if first is not None:
            first()
        self._lock.acquire()
        return self

    def __exit__(self, *exc_info):
        self._lock.release()
        return False


def test_a_lookup_that_meets_a_store_at_the_lock_gets_the_answer(
        monkeypatch):
    """Copy B looks up just as copy A's run returns, and A's store takes the
    memo's lock first. B reads the clock with the lock held, so A's answer
    is 0 s old to it: B gets it, and it stays kept. B used to read the
    clock before the lock, found an answer stored after that, threw it
    away as if it were from the future and ran the photo again (review
    2026-11-28)."""
    monkeypatch.delenv(KNOB, raising=False)
    clock = _Clock(monkeypatch)
    key = hashlib.sha256(b"one request").digest()

    def a_stores():
        clock.advance(1)
        claude_analyzer._remember_answer(key, {"n": 1})

    monkeypatch.setattr(claude_analyzer, "_ANSWER_MEMO_LOCK",
                        _LockThatLetsAStoreInFirst(a_stores))
    assert claude_analyzer._remembered_answer(key, "photo") == {"n": 1}
    assert list(claude_analyzer._ANSWER_MEMO) == [key]


def test_answers_are_kept_in_the_order_of_their_clock(monkeypatch):
    """Two stores meet at the memo's lock: B has started, and A takes the
    lock first. Each store reads the clock with the lock held, so the memo
    is oldest first in time as well as in order. _remember_answer's
    pruning relies on that: it stops at the first answer still in time."""
    monkeypatch.delenv(KNOB, raising=False)
    clock = _Clock(monkeypatch)
    a, b = (hashlib.sha256(name).digest() for name in (b"a", b"b"))

    def a_stores():
        clock.advance(1)
        claude_analyzer._remember_answer(a, {"n": "a"})

    monkeypatch.setattr(claude_analyzer, "_ANSWER_MEMO_LOCK",
                        _LockThatLetsAStoreInFirst(a_stores))
    claude_analyzer._remember_answer(b, {"n": "b"})
    memo = claude_analyzer._ANSWER_MEMO
    assert list(memo) == [a, b]
    times = [stored_at for stored_at, _ in memo.values()]
    assert times == sorted(times), times


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_the_knob_at_zero_keeps_nothing_and_hands_nothing_out(
        client, monkeypatch, path, body, field, word):
    """On by default; CLAUDE_API_ANSWER_MEMO_SECONDS=0 is every request a
    run of its own again: an answer kept before is not handed out, and
    nothing new is kept, so another photo sent at 0 is analyzed again
    once the memo is back on."""
    cli = _fake_cli(monkeypatch)
    for _ in range(2):
        assert client.http.post(path, headers=KEY,
                                json=body()).status_code == 200
    assert len(cli.starts) == 1
    monkeypatch.setenv(KNOB, "0")
    for _ in range(2):
        assert client.http.post(path, headers=KEY,
                                json=body()).status_code == 200
    assert len(cli.starts) == 3
    other = body(image_b64=_b64(OTHER_JPEG))
    assert client.http.post(path, headers=KEY, json=other).status_code == 200
    assert len(cli.starts) == 4
    assert len(claude_analyzer._ANSWER_MEMO) == 1  # the one from before
    monkeypatch.delenv(KNOB)
    assert client.http.post(path, headers=KEY, json=other).status_code == 200
    assert len(cli.starts) == 5, "an answer was kept while the knob was 0"


def test_answer_memo_knob_default_zero_clamp_and_junk(monkeypatch):
    monkeypatch.delenv(KNOB, raising=False)
    assert claude_analyzer.answer_memo_seconds() == 600
    for raw, seconds in [("0", 0), ("300", 300), (" 120 ", 120), ("-5", 0),
                         ("999999", 3600), ("junk", 600), ("", 600),
                         ("12.5", 600)]:
        monkeypatch.setenv(KNOB, raw)
        assert claude_analyzer.answer_memo_seconds() == seconds, raw


def test_an_answer_memo_value_that_is_not_a_number_is_named_in_the_journal(
        monkeypatch, caplog):
    """As for the busy wait: systemd keeps a comment after a value as part
    of the value, so `…=0   # off` would leave the memo on without a word.
    One WARNING for each such value, however often the knob is read; the
    value cut to 40 characters; nothing else from the environment."""
    monkeypatch.setattr(claude_analyzer, "_ANSWER_MEMO_JUNK_SEEN", set())
    monkeypatch.setenv("ANDROID_API_KEY", "upload-key-stays-out")
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "plan-token-stays-out")

    def warnings():
        return [r.getMessage() for r in caplog.records
                if r.name == "claude_analyzer"
                and r.levelno == logging.WARNING]

    with caplog.at_level(logging.INFO, logger="claude_analyzer"):
        monkeypatch.setenv(KNOB, "0   # off")
        for _ in range(3):
            assert claude_analyzer.answer_memo_seconds() == 600
        assert warnings() == [
            "CLAUDE_API_ANSWER_MEMO_SECONDS is not a whole number: "
            "'0   # off'. Answers are still kept for its default, 600 s. "
            "Write the number alone on its line: systemd keeps a comment "
            "after it as part of the value."]
        monkeypatch.setenv(KNOB, "10m")
        assert claude_analyzer.answer_memo_seconds() == 600
        assert len(warnings()) == 2 and ": '10m'. " in warnings()[1]
        for raw in ("0", "600", "-1", "999999", "", "   "):
            monkeypatch.setenv(KNOB, raw)
            claude_analyzer.answer_memo_seconds()
        assert len(warnings()) == 2
        monkeypatch.setenv(KNOB, "x" * 40 + "the-rest-stays-out")
        assert claude_analyzer.answer_memo_seconds() == 600
        assert ": '" + "x" * 40 + "'…. " in warnings()[2]
    assert "stays-out" not in caplog.text


def test_the_busy_wait_warning_is_word_for_word_what_it_was(monkeypatch,
                                                            caplog):
    """The two knobs now share the warning's code; the busy wait's line,
    which its own test and the deploy guide quote, did not change."""
    monkeypatch.setattr(claude_analyzer, "_BUSY_WAIT_JUNK_SEEN", set())
    monkeypatch.setattr(claude_analyzer, "_ANSWER_MEMO_JUNK_SEEN", set())
    monkeypatch.setenv("CLAUDE_API_BUSY_WAIT_SECONDS", "0 # off")
    monkeypatch.setenv(KNOB, "0 # off")
    with caplog.at_level(logging.WARNING, logger="claude_analyzer"):
        claude_analyzer.busy_wait_seconds()
        claude_analyzer.answer_memo_seconds()
    lines = [r.getMessage() for r in caplog.records
             if r.name == "claude_analyzer"]
    assert lines[0] == (
        "CLAUDE_API_BUSY_WAIT_SECONDS is not a whole number: '0 # off'. "
        "The wait stays at its default, 20 s. Write the number alone on "
        "its line: systemd keeps a comment after it as part of the value.")
    assert lines[1].startswith("CLAUDE_API_ANSWER_MEMO_SECONDS is not")
    assert len(lines) == 2


# ─── The lock: a hit takes none, a duplicate that waited runs none ────

@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_a_hit_while_the_cli_is_busy_is_answered_at_once(
        client, monkeypatch, path, body, field, word):
    """Another analysis holds the CLI, and then a restaurant lookup does:
    the same request is answered from memory at once both times. It does
    not wait, is not counted as a waiter and stops no lookup."""
    cli = _fake_cli(monkeypatch)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200

    def no_lock(*a, **kw):
        pytest.fail("a remembered answer took the CLI's lock")

    monkeypatch.setattr(claude_analyzer, "_cli_for_request", no_lock)
    monkeypatch.setattr(claude_analyzer, "_wait_for_cli", no_lock)
    cancel = threading.Event()
    assert claude_analyzer._CLI_LOCK.acquire(blocking=False)
    try:
        busy = client.http.post(path, headers=KEY, json=body())
        monkeypatch.setitem(claude_analyzer._LOOKUP_STATE, "holding", True)
        monkeypatch.setitem(claude_analyzer._LOOKUP_STATE, "cancel", cancel)
        monkeypatch.setitem(claude_analyzer._LOOKUP_STATE, "preempted", False)
        looking_up = client.http.post(path, headers=KEY, json=body())
        assert claude_analyzer._CLI_LOCK.locked()
    finally:
        claude_analyzer._CLI_LOCK.release()
    for resp in (busy, looking_up):
        assert resp.status_code == 200
        assert resp.get_json()[field] == ANSWER
        assert "Retry-After" not in resp.headers
    assert claude_analyzer._LOOKUP_STATE["fg_waiting"] == 0
    assert claude_analyzer._LOOKUP_STATE["preempted"] is False
    assert not cancel.is_set()
    assert len(cli.starts) == 1


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_a_duplicate_that_waited_behind_its_first_copy_runs_no_cli(
        client, monkeypatch, caplog, path, body, field, word):
    """The phone sends the photo again while its first copy is still being
    analyzed (the busy wait makes it wait). When the first run ends, the
    second gets its answer from memory, and no second run starts."""
    cli = _fake_cli(monkeypatch)
    cli.go = threading.Event()
    waiting = threading.Event()
    real_wait = claude_analyzer._wait_for_cli

    def wait(seconds):
        waiting.set()
        return real_wait(seconds)

    monkeypatch.setattr(claude_analyzer, "_wait_for_cli", wait)
    app = client.http.application
    replies = {}

    def send(name):
        replies[name] = app.test_client().post(path, headers=KEY,
                                               json=body())

    first = threading.Thread(target=send, args=("first",))
    second = threading.Thread(target=send, args=("second",))
    with caplog.at_level(logging.INFO, logger="claude_analyzer"):
        first.start()
        try:
            assert cli.entered.wait(5), "the first analysis did not start"
            second.start()
            assert waiting.wait(5), "the second copy did not wait for the CLI"
        finally:
            cli.go.set()
            first.join(10)
            second.join(10)
    assert replies["first"].status_code == 200
    assert replies["second"].status_code == 200
    assert replies["second"].get_data() == replies["first"].get_data()
    assert len(cli.starts) == 1, "the duplicate started a second run"
    lines = [r.getMessage() for r in caplog.records
             if r.name == "claude_analyzer"]
    assert any(line.startswith(f"Claude CLI busy — app {word} request "
                               "waited") for line in lines), lines
    assert len(_memo_lines(caplog)) == 1
    assert claude_analyzer._LOOKUP_STATE["fg_waiting"] == 0
    assert not claude_analyzer._CLI_LOCK.locked()


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_many_copies_of_one_request_at_once_lead_to_one_run(
        client, monkeypatch, path, body, field, word):
    """Six copies of one request arrive while the first is being analyzed.
    Two wait for the CLI and three are refused at once (two already wait:
    the busy wait's cap). When the run ends the two waiting get its answer
    from memory, and the three refused, asking again as the app does, get
    it too. One CLI run in all."""
    cli = _fake_cli(monkeypatch)
    cli.go = threading.Event()
    changed = threading.Condition()
    state = {"waiting": 0}
    replies = []
    real_wait = claude_analyzer._wait_for_cli

    def wait(seconds):
        with changed:
            state["waiting"] += 1
            changed.notify_all()
        return real_wait(seconds)

    monkeypatch.setattr(claude_analyzer, "_wait_for_cli", wait)
    app = client.http.application

    def send():
        reply = app.test_client().post(path, headers=KEY, json=body())
        with changed:
            replies.append(reply)
            changed.notify_all()

    threads = [threading.Thread(target=send) for _ in range(6)]
    threads[0].start()
    try:
        assert cli.entered.wait(5), "the first analysis did not start"
        for thread in threads[1:]:
            thread.start()
        with changed:
            assert changed.wait_for(
                lambda: state["waiting"] == 2 and len(replies) == 3,
                timeout=5), (state, len(replies))
            refused = list(replies)
    finally:
        cli.go.set()
        for thread in threads:
            thread.join(10)
    for reply in refused:
        assert reply.status_code == 503
        assert reply.get_json()["retry"] is True
        assert reply.headers["Retry-After"] == "5"
    answered = [r for r in replies if r.status_code == 200]
    assert len(answered) == 3
    assert {r.get_data() for r in answered} == {answered[0].get_data()}
    for _ in refused:
        again = client.http.post(path, headers=KEY, json=body())
        assert again.status_code == 200
        assert again.get_data() == answered[0].get_data()
    assert len(cli.starts) == 1
    assert claude_analyzer._LOOKUP_STATE["fg_waiting"] == 0
    assert not claude_analyzer._CLI_LOCK.locked()


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_a_memo_line_that_cannot_be_written_still_answers(
        client, monkeypatch, path, body, field, word):
    """The second lookup runs with the CLI's lock held. A logger that
    raises on the hit's line must neither cost the request its answer nor
    keep the lock: the line is lost, the answer goes out, the lock comes
    back. Both lookups: one before the lock, one behind a run."""
    cli = _fake_cli(monkeypatch)
    assert client.http.post(path, headers=KEY, json=body()).status_code == 200
    real_info = claude_analyzer.log.info
    lost = []

    def info(message, *args, **kwargs):
        if str(message).startswith("Answered from memory"):
            lost.append(message)
            raise RuntimeError("the journal cannot take this line")
        return real_info(message, *args, **kwargs)

    monkeypatch.setattr(claude_analyzer.log, "info", info)
    # Before the lock.
    resp = client.http.post(path, headers=KEY, json=body())
    assert resp.status_code == 200 and resp.get_json()[field] == ANSWER
    # With the lock held: the first lookup misses (the stand-in below
    # answers "nothing kept" once), the second finds the answer.
    real_lookup = claude_analyzer._remembered_answer
    calls = []

    def lookup(key, kind):
        calls.append(kind)
        return None if len(calls) == 1 else real_lookup(key, kind)

    monkeypatch.setattr(claude_analyzer, "_remembered_answer", lookup)
    resp = client.http.post(path, headers=KEY, json=body())
    assert resp.status_code == 200 and resp.get_json()[field] == ANSWER
    assert calls == [word, word]
    assert len(lost) == 2
    assert not claude_analyzer._CLI_LOCK.locked()
    assert len(cli.starts) == 1


# ─── A phone that hung up ─────────────────────────────────────────────

def test_a_phone_that_hung_up_mid_run_still_leaves_its_answer(client,
                                                               monkeypatch):
    """Through werkzeug's own threaded server, as the service runs Flask:
    the phone sends its photo and hangs up while the analysis runs (an
    iPhone background scan at its deadline). werkzeug runs the view to its
    end anyway and only finds the connection gone when it writes the
    reply, so the answer is kept. The photo sent again is answered from
    memory, with no second run."""
    from werkzeug.serving import WSGIRequestHandler, make_server

    cli = _fake_cli(monkeypatch)
    cli.go = threading.Event()
    handled = threading.Event()
    dropped = []

    class Handler(WSGIRequestHandler):
        def handle(self):
            try:
                super().handle()
            finally:
                handled.set()

        def connection_dropped(self, error, environ=None):
            # werkzeug's hook for a client that is gone (a no-op there).
            dropped.append(type(error).__name__)

        def log_request(self, *args, **kwargs):
            pass  # no access line in the test output

    server = make_server("127.0.0.1", 0, client.http.application,
                         threaded=True, request_handler=Handler)
    serving = threading.Thread(
        target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
    serving.start()
    try:
        payload = json.dumps(_photo_body()).encode("utf-8")
        head = ("POST /api/analyze_photo HTTP/1.1\r\n"
                "Host: 127.0.0.1\r\n"
                "Content-Type: application/json\r\n"
                "X-API-Key: secret-key\r\n"
                "X-Client-Platform: app\r\n"
                f"Content-Length: {len(payload)}\r\n"
                "Connection: close\r\n\r\n").encode("ascii")
        phone = socket.create_connection(("127.0.0.1", server.port),
                                         timeout=5)
        try:
            phone.sendall(head + payload)
            assert cli.entered.wait(5), "the analysis did not start"
        finally:
            # Hang up at once (a reset, not a polite close), as a phone
            # whose process iOS has suspended.
            phone.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                             struct.pack("ii", 1, 0))
            phone.close()
        cli.go.set()  # the analysis ends after the phone has gone
        assert handled.wait(10), "the server's handler did not end"
    finally:
        cli.go.set()
        server.shutdown()
        server.server_close()
        serving.join(5)
    assert dropped, ("werkzeug delivered the reply: the phone had not hung "
                     "up before the analysis ended")
    assert len(cli.starts) == 1
    assert len(claude_analyzer._ANSWER_MEMO) == 1, "the answer was lost"

    again = client.http.post("/api/analyze_photo", headers=KEY,
                             json=_photo_body())
    assert again.status_code == 200
    assert again.get_json()["analysis"] == ANSWER
    assert len(cli.starts) == 1


# ─── A sign-in from the phone ────────────────────────────────────────
#
# /api/claude_auth/complete gives the CLI a new token while the server
# runs (claude_auth.apply_token_to_env sets it in the environment). It may
# be another account, whose default model is another one when the request
# names none (review 2026-11-28).

def _sign_in(monkeypatch, tmp_path):
    """The step a sign-in from the phone ends with, writing the token to a
    .env of the test's own. The process's own token is put back after the
    test (monkeypatch remembers it)."""
    import claude_auth
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "token-before-sign-in")
    env = tmp_path / ".env"
    env.write_text("CLAUDE_CODE_OAUTH_TOKEN=token-before-sign-in\n")

    def sign_in():
        claude_auth.apply_token_to_env("token-after-sign-in", env_path=env)
        assert os.environ["CLAUDE_CODE_OAUTH_TOKEN"] == "token-after-sign-in"

    return sign_in


@pytest.mark.parametrize("path,body,field,word", ENDPOINTS, ids=ENDPOINT_IDS)
def test_a_sign_in_from_the_phone_forgets_every_answer(
        client, monkeypatch, tmp_path, path, body, field, word):
    """No answer worked out before a sign-in is handed out after it. The
    first answer after it is kept as usual."""
    cli = _fake_cli(monkeypatch)
    sign_in = _sign_in(monkeypatch, tmp_path)
    for _ in range(2):
        assert client.http.post(path, headers=KEY,
                                json=body()).status_code == 200
    assert len(cli.starts) == 1
    sign_in()
    assert len(claude_analyzer._ANSWER_MEMO) == 0
    for _ in range(2):
        assert client.http.post(path, headers=KEY,
                                json=body()).status_code == 200
    assert len(cli.starts) == 2, "an answer from before the sign-in was used"


def test_an_analysis_that_ran_through_a_sign_in_is_not_kept(
        client, monkeypatch, tmp_path):
    """The sign-in comes while a photo is being analyzed with the old
    token. That request still gets its answer, but the answer is not kept:
    its key was made before the sign-in, and no request made after it has
    that key."""
    cli = _fake_cli(monkeypatch)
    cli.go = threading.Event()
    sign_in = _sign_in(monkeypatch, tmp_path)
    app = client.http.application
    replies = {}

    def send():
        replies["first"] = app.test_client().post(
            "/api/analyze_photo", headers=KEY, json=_photo_body())

    first = threading.Thread(target=send)
    first.start()
    try:
        assert cli.entered.wait(5), "the analysis did not start"
        sign_in()
    finally:
        cli.go.set()
        first.join(10)
    assert replies["first"].status_code == 200
    assert replies["first"].get_json()["analysis"] == ANSWER
    again = client.http.post("/api/analyze_photo", headers=KEY,
                             json=_photo_body())
    assert again.status_code == 200
    assert len(cli.starts) == 2, "an answer from before the sign-in was used"


# ─── Telegram, /upload and text requests never use it ────────────────

def test_telegram_and_upload_photos_are_each_a_run_of_their_own(monkeypatch):
    """Telegram photos, /upload photos and /retry_all_failed all reach the
    CLI through analyze_food_photo_with_retries. The same photo twice is
    two runs, and nothing is kept."""
    cli = _fake_cli(monkeypatch)
    for _ in range(2):
        result = telegram_bot.analyze_food_photo_with_retries(None, JPEG)
        assert result["analyzed_by"] == "claude"
        assert result["total_calories"] == ANSWER["total_calories"]
    assert len(cli.starts) == 2
    assert len(claude_analyzer._ANSWER_MEMO) == 0


def _calls_with_memo_scope(path):
    """{(innermost enclosing function, called name)} for every call in
    [path] that passes memo_scope."""
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    found = set()

    def visit(node, function):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            function = node.name
        if isinstance(node, ast.Call) and any(
                k.arg == "memo_scope" for k in node.keywords):
            found.add((function, ast.unparse(node.func)))
        for child in ast.iter_child_nodes(node):
            visit(child, function)

    visit(tree, None)
    return found


def test_only_the_photo_and_leftover_endpoints_turn_the_memo_on():
    """The wiring: memo_scope is passed in exactly two places, the app's
    photo and leftover endpoints. The text endpoint's analyzer has no such
    parameter: the same words sent twice may be meant twice."""
    root = os.path.join(os.path.dirname(__file__), "..")
    assert _calls_with_memo_scope(os.path.join(root, "telegram_bot.py")) == {
        ("api_analyze_photo", "claude_analyzer.analyze_food_photo"),
        ("api_analyze_leftover", "claude_analyzer.analyze_leftover_photo"),
    }
    assert "memo_scope" not in inspect.signature(
        claude_analyzer.analyze_text_prompt).parameters
    for fn in (claude_analyzer.analyze_food_photo,
               claude_analyzer.analyze_leftover_photo):
        assert inspect.signature(fn).parameters["memo_scope"].default is None


def test_a_text_request_sent_twice_is_two_runs(client, monkeypatch):
    cli = _fake_cli(monkeypatch)
    cli.behaviours[:] = [lambda cmd, kw: SimpleNamespace(
        returncode=0, stderr="", stdout=json.dumps({
            "type": "result", "is_error": False,
            "result": json.dumps({"intent": "correction"})}))] * 2
    for _ in range(2):
        resp = client.http.post("/api/text_intent", headers=KEY,
                                json={"prompt": "the rice was half"})
        assert resp.status_code == 200
    assert len(cli.starts) == 2
    assert len(claude_analyzer._ANSWER_MEMO) == 0
