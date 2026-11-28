"""
Claude-first food photo analysis via the Claude Code CLI.

Runs the analysis on the user's Claude subscription (headless `claude -p`
with a CLAUDE_CODE_OAUTH_TOKEN minted by `claude setup-token`) instead of a
metered API key. This module is a best-effort PRIMARY: any failure — CLI
absent, token invalid, usage-window exhausted, timeout, malformed output —
returns None and the caller falls back to Gemini, so the bot never degrades
below today's behavior.

Dispatch modes (CLAUDE_ANALYZER_DISPATCH):
  stream (default)  Single model turn: the image travels on stdin as a
                    base64 content block via `--input-format stream-json`,
                    so no temp file and no Read-tool round trip. Measured on
                    the production VM: ~8.2-8.4s wall vs 16.0s for the
                    two-turn path, num_turns=1, same-quality output. If the
                    attempt fails for CLI-shape reasons (older CLIs without
                    stream-json support exit nonzero here), the analyzer
                    logs once and retries ONCE via the file path below —
                    within the same _CLI_LOCK hold.
  file              Two model turns: the image is written to a temp file and
                    the model Reads it back. Forces the old path only —
                    a rollback knob, never combined with a stream attempt.
                    It applies only to the server's own prompts (Telegram
                    photos): a request whose prompt holds caller text (the
                    app API, allow_file_fallback=False) always runs the
                    no-tools stream dispatch and never the Read path.

Configuration (env / .env):
  CLAUDE_ANALYZER_ENABLED           truthy to enable (default: off)
  CLAUDE_ANALYZER_BIN               CLI binary (default: "claude")
  CLAUDE_ANALYZER_MODEL             optional --model override (claude backend)
  CLAUDE_ANALYZER_TIMEOUT_SECONDS   per-analysis wall clock (default: 120)
  CLAUDE_ANALYZER_EXTRA_FLAGS       optional extra CLI flags (shlex-split)
  CLAUDE_ANALYZER_DISPATCH          'stream' (default) or 'file' (see above)
  CLAUDE_API_BUSY_WAIT_SECONDS      how long an app request waits for a busy
                                    CLI before its 503 (default: 20, 0 = no
                                    wait; see busy_wait_seconds)
  CLAUDE_API_ANSWER_MEMO_SECONDS    how long the answer of an app photo or
                                    leftover analysis is kept in memory for
                                    the same request sent again (default:
                                    600, 0 = off; see answer_memo_seconds)
  CLAUDE_CODE_OAUTH_TOKEN           subscription token (read by the CLI itself)
  GLM_PLAN_KEY                      Zhipu GLM Coding Plan key → 'glm' backend
  DOUBAO_PLAN_KEY                   Volcengine Agent Plan key → 'doubao' backend

Subscription backends (the [backend] parameter):
  The SAME Claude Code CLI can run against two other vendors' subscription
  plans — both officially document Claude Code as a supported tool, so this
  is their sanctioned use, not impersonation (facts verified 2026-07-30):
    glm     Zhipu GLM Coding Plan: ANTHROPIC_BASE_URL=
            https://open.bigmodel.cn/api/anthropic + plan key as the auth
            token. That endpoint is TEXT-ONLY, so photos go through Zhipu's
            OFFICIAL vision MCP server (@z_ai/mcp-server, GLM-4.6V) reading
            a local temp file — needs npx on this machine.
    doubao  Volcengine Ark Agent Plan: ANTHROPIC_BASE_URL=
            https://ark.cn-beijing.volces.com/api/plan + plan key. Direct
            API calls with a plan key are a documented ban risk — the plan
            is valid ONLY through whitelisted tools, and running the real
            Claude Code CLI is exactly that. Image input over this endpoint
            is undocumented: the stream dispatch sends the photo as a
            base64 block and a rejection surfaces as an ordinary failed run
            (→ None → the caller's fallback), never a crash.
  Both backends scrub CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY from the
  child env so a vendor run can never accidentally spend the Anthropic
  subscription or an API key.
"""

import base64
import copy
import hashlib
import json
import logging
import os
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

from config import FOOD_DETECTION_PROMPT
from utils import parse_ai_json, parse_boolish

log = logging.getLogger("claude_analyzer")

class AnalyzerBusy(Exception):
    """Another photo owns the single-flight CLI right now — and still did
    after the short wait an app request gets (busy_wait_seconds), or too
    many requests were waiting for it already.

    Distinct from a None return, which means the run HAPPENED and failed
    (junk reply, blind GLM run) — those are terminal for this photo, and
    the app must not spend three more 120 s CLI runs on them. A timeout
    is neither: see AnalyzerTimeout. The endpoints map busy → retryable
    503, terminal → non-retryable, timeout → "come back later".
    """


class AnalyzerTimeout(Exception):
    """The CLI run hit the wall-clock limit before the model answered.

    Distinct from None (the model ANSWERED, with junk — terminal) and
    from PlanRefused (the plan said no). Nothing about the photo caused
    it — a slow model or a loaded VM did — and the same photo analyzes
    fine an hour later. Until 2026-10-07 this surfaced as the terminal
    "produced no usable result" and the app burned the photo for good
    while its UI promised an automatic retry. Raised ONLY to API callers
    (raise_on_busy=True); the Telegram path keeps its documented
    "None → use Gemini" contract.
    """

    def __init__(self, seconds: int):
        super().__init__(f"the analysis timed out after {seconds} s")
        self.seconds = seconds
        self.reason = f"the analysis timed out after {seconds} s"


# The CLI is a full Node process (hundreds of MB RSS). Single-flight: only
# one run at a time, and a contended caller does NOT queue — it returns None
# immediately so the photo falls through to Gemini instead of waiting out
# another photo's full CLI run (measured ~42-63s cards on album bursts). The
# subprocess timeout bounds how long the one holder keeps the lock.
#
# Two exceptions to "a contended caller does not wait":
#
# 1. A background RESTAURANT LOOKUP (run_lookup_exclusive) never makes a
#    photo, leftover or text request wait or fail. Those callers pre-empt
#    it — the lookup's process group is killed and the caller waits at
#    most PREEMPT_WAIT_SECONDS for the lock (_acquire_cli_for_foreground).
#    The lookup job is requeued by lookup_jobs.
#
# 2. An APP request (raise_on_busy=True: /api/analyze_photo,
#    /api/analyze_leftover, /api/text_intent) has no Gemini to fall
#    through to: refused, the phone can only ask again. It was refused at
#    once until 2026-11-28, and the installed app asks again after 5 s
#    and after 10 s and then lets the photo go until its next scan — so
#    two senders scanning together (two phones, or the open app and its
#    own background scan; 2026-11-27: one upload refused twice in a row)
#    cost each other photos. Now it waits for the analysis ahead of it:
#    up to busy_wait_seconds(), and at most BUSY_WAIT_MAX_WAITERS callers
#    at a time, so request threads (each holds its photo) cannot pile up
#    on a 1 GB server — one more than that is refused at once, as before.
#    A Telegram or /upload photo still never waits for another analysis.
#
# An app photo or leftover request that is the same, in everything that
# can change the answer, as one this server finished analyzing in the
# last answer_memo_seconds() is given that answer and takes no lock at
# all (the answer memo, above analyze_text_prompt).
#
# A lookup takes AND releases _CLI_LOCK only while holding
# _LOOKUP_STATE_LOCK, so a foreground caller that holds the state lock
# sees a stable owner. While a foreground caller waits for the lock
# ("fg_waiting": for a pre-empted lookup to let go, or for the analysis
# ahead of it), no lookup may take the lock: the worker's next queued job
# can never win the (non-FIFO) race against that caller.
_CLI_LOCK = threading.Lock()
PREEMPT_WAIT_SECONDS = 5

# How long an app request waits for a busy CLI: the default and the
# ceiling of CLAUDE_API_BUSY_WAIT_SECONDS (busy_wait_seconds).
#
# Why about 20 s and not a whole run's 120: an iPhone background scan
# abandons its request 22 s after the scan began (iosRunDeadline in the
# app's background_glue.dart). A request that had waited longer than that
# would be analyzed for a phone that has stopped listening — a run of the
# owner's plan spent on an answer nobody reads, with the next photo kept
# waiting behind it. 20 s still outlasts the analysis ahead in the usual
# case (8-15 s on the first server).
#
# The limit bounds that waste; it does not end it. This server cannot see
# a phone hang up (the handler runs to its end either way), and a scan
# that sent its photo late, or waited 15 s and then needs 10 s more, is
# gone before its answer too. That was already so for a request that
# reached a free CLI late in a scan. The phone offers such a photo again.
#
# The ceiling is for a server no iPhone uses; the app itself gives a
# request 5 minutes, which a 60 s wait and a full 120 s run still fit.
BUSY_WAIT_SECONDS_DEFAULT = 20
BUSY_WAIT_SECONDS_MAX = 60
# Foreground callers that may wait for _CLI_LOCK at one time (the
# pre-empting caller of exception 1 counts as one of them).
BUSY_WAIT_MAX_WAITERS = 2
# The Retry-After (seconds) of a busy 503, for app builds to come; it is
# the pause the installed builds already take before their second try.
BUSY_RETRY_AFTER_SECONDS = 5

# Who holds _CLI_LOCK for a lookup, its process and its cancel event
# (for pre-emption), and how many foreground callers wait for the lock.
_LOOKUP_STATE_LOCK = threading.Lock()
_LOOKUP_STATE: Dict[str, object] = {
    "holding": False, "proc": None, "preempted": False, "cancel": None,
    "fg_waiting": 0}


# Values of the two app-request knobs that were not a number and that the
# journal has been told about (_warn_knob_junk), one set for each knob:
# CLAUDE_API_BUSY_WAIT_SECONDS and CLAUDE_API_ANSWER_MEMO_SECONDS. Both
# are read for every app request, and nothing sets them while the server
# runs: one line for the value, not one for each request.
_BUSY_WAIT_JUNK_SEEN: set = set()
_ANSWER_MEMO_JUNK_SEEN: set = set()
_KNOB_JUNK_LOCK = threading.Lock()


def _warn_knob_junk(knob: str, raw: str, seen: set, stays: str) -> None:
    """One WARNING for a value of [knob] that is not a whole number, once
    for each such value ([seen] holds the values named already). [stays]
    says what the server does instead.

    Junk used to read as the default in silence. systemd's EnvironmentFile
    keeps a comment after a value as part of the value, so a line
    `…=0   # off` left the busy wait on and nothing said so (review
    2026-11-28).

    The line shows this knob's own value, cut to 40 characters: enough to
    know the line by, and a limit on what a mangled env file can put in
    the journal. Nothing else from the environment is in it."""
    with _KNOB_JUNK_LOCK:
        if raw in seen:
            return
        seen.add(raw)
    shown = repr(raw[:40]) + ("…" if len(raw) > 40 else "")
    log.warning(
        f"{knob} is not a whole number: {shown}. {stays} "
        "Write the number alone on its line: systemd keeps a comment "
        "after it as part of the value.")


def _warn_busy_wait_junk(raw: str) -> None:
    """_warn_knob_junk for CLAUDE_API_BUSY_WAIT_SECONDS, whose default is
    "wait"."""
    _warn_knob_junk(
        "CLAUDE_API_BUSY_WAIT_SECONDS", raw, _BUSY_WAIT_JUNK_SEEN,
        f"The wait stays at its default, {BUSY_WAIT_SECONDS_DEFAULT} s.")


def busy_wait_seconds() -> int:
    """CLAUDE_API_BUSY_WAIT_SECONDS: how long an app request waits for a
    busy CLI before it is told "busy". 0 = not at all (the answer at once,
    as before 2026-11-28); junk reads as the default, and the journal says
    so (_warn_busy_wait_junk). An empty value is a knob left unset."""
    raw = os.environ.get("CLAUDE_API_BUSY_WAIT_SECONDS",
                         str(BUSY_WAIT_SECONDS_DEFAULT))
    try:
        value = int(raw)
    except ValueError:
        if raw.strip():
            _warn_busy_wait_junk(raw)
        return BUSY_WAIT_SECONDS_DEFAULT
    return min(max(value, 0), BUSY_WAIT_SECONDS_MAX)


def _wait_for_cli(seconds: float) -> bool:
    """Block until _CLI_LOCK is this thread's (True) or [seconds] have
    passed (False). The one place a foreground caller blocks, and a
    function of its own so that a test can stand in for the wait."""
    return _CLI_LOCK.acquire(timeout=seconds)


def _acquire_cli_for_foreground(
        wait_seconds: float = 0,
        note: Optional[Dict[str, float]] = None) -> bool:
    """_CLI_LOCK for a photo/leftover/text request.

    Contended by a lookup: kill the lookup and wait (bounded) for the
    lock it releases — the first such caller only.

    Contended by another FOREGROUND request, or behind the caller that
    pre-empted the lookup: with [wait_seconds] 0 (Telegram, /upload)
    False at once, as always. An app request waits up to [wait_seconds]
    for the lock instead, unless BUSY_WAIT_MAX_WAITERS callers are
    waiting already (False at once).

    Not a queue: threading.Lock promises its waiters no order, and a
    request that arrives in the very instant the lock comes free can take
    it first. The waiter then goes on waiting, inside its limit. A lookup
    never takes it from a waiter (fg_waiting).

    [note], when given, receives what the journal line needs: "waited"
    (seconds, whenever this caller blocked) and "ahead" (how many were
    waiting, when that is why it was turned away).
    """
    if _CLI_LOCK.acquire(blocking=False):
        return True
    acquired = False
    start = time.monotonic()
    with _LOOKUP_STATE_LOCK:
        if _CLI_LOCK.acquire(blocking=False):  # released meanwhile
            return True
        waiting = _LOOKUP_STATE["fg_waiting"]
        preempting = bool(_LOOKUP_STATE["holding"]) and not waiting
        if preempting:
            # Never a shorter wait than before for the caller that pre-empts.
            limit = max(PREEMPT_WAIT_SECONDS, wait_seconds)
            _preempt_locked()
        elif wait_seconds <= 0:
            return False
        elif waiting >= BUSY_WAIT_MAX_WAITERS:
            if note is not None:
                note["ahead"] = waiting
            return False
        else:
            limit = wait_seconds
        # Counted from here to the finally below, with nothing in between:
        # a count that never came down would keep every lookup out, and
        # turn app requests away at the cap, until the next restart.
        _LOOKUP_STATE["fg_waiting"] = waiting + 1
    try:
        if preempting:
            _lookup_log.info(
                "Restaurant lookup pre-empted by a foreground request.")
        acquired = _wait_for_cli(limit)
        return acquired
    finally:
        with _LOOKUP_STATE_LOCK:
            _LOOKUP_STATE["fg_waiting"] -= 1
        if note is not None:
            # A wait that ran out lasted its limit, by definition.
            note["waited"] = time.monotonic() - start if acquired else limit


def _cli_for_request(raise_on_busy: bool, kind: str, declined: str) -> bool:
    """_CLI_LOCK for one photo, leftover or text request — or, when it is
    not to be had, the journal line that says what happens to the request.

    raise_on_busy False (Telegram, /upload): never waits for another
    analysis. False at once, and [declined] names the caller's own way
    out ("falling back to Gemini for this photo.").

    raise_on_busy True (the app's API): waits up to busy_wait_seconds()
    for the analysis ahead of it, then raises AnalyzerBusy — the
    endpoint's 503 {"retry": true}, which the app retries. This path has
    no Gemini fallback, so its line must not promise one (until
    2026-11-28 the photo line did, for app requests too).
    """
    note: Dict[str, float] = {}
    wait = busy_wait_seconds() if raise_on_busy else 0
    if _acquire_cli_for_foreground(wait, note):
        if raise_on_busy and "waited" in note:
            # _CLI_LOCK is this request's already, and the caller's
            # try/finally, which gives it back, begins only after this
            # function returns. Nothing may raise in between: an error
            # from the logger here would leave the CLI "busy" until the
            # next restart. So a line that cannot be written is lost, and
            # the request goes on.
            try:
                log.info(f"Claude CLI busy — app {kind} request waited "
                         f"{note['waited']:.1f} s for it.")
            except Exception:
                pass
        return True
    if not raise_on_busy:
        log.info(f"Claude CLI busy — {declined}")
        return False
    if "waited" in note:
        how = f"after waiting {note['waited']:.0f} s"
    elif "ahead" in note:
        how = f"at once: {note['ahead']:.0f} requests already wait"
    else:
        how = "at once: waiting is off"
    log.info(f"Claude CLI busy — app {kind} request refused {how} "
             "(503, retry: true; the app retries).")
    raise AnalyzerBusy()


def _timeout_seconds() -> int:
    try:
        value = int(os.environ.get("CLAUDE_ANALYZER_TIMEOUT_SECONDS", "120"))
    except ValueError:
        return 120
    return min(max(value, 10), 600)


def _cli_path() -> Optional[str]:
    return shutil.which(os.environ.get("CLAUDE_ANALYZER_BIN", "claude") or "claude")


def is_enabled() -> bool:
    """The CLAUDE_ANALYZER_ENABLED knob alone, ignoring CLI presence."""
    return parse_boolish(os.environ.get("CLAUDE_ANALYZER_ENABLED")) is True


def is_configured() -> bool:
    """Enabled by knob AND the CLI is actually installed.

    The OAuth token is deliberately not required here: the CLI may hold its
    own stored login, and a missing/expired token simply fails the run —
    which the caller already treats as "fall back to Gemini".
    """
    return is_enabled() and _cli_path() is not None


def status_label() -> str:
    """One-phrase analyzer state for /config and /doctor."""
    if not is_enabled():
        return "off"
    if _cli_path() is None:
        return "enabled, CLI missing"
    return "enabled"


def _dispatch_mode() -> str:
    """'file' forces the two-turn temp-file path (the rollback knob);
    anything else — unset, 'stream', or a typo — takes the stream default."""
    raw = (os.environ.get("CLAUDE_ANALYZER_DISPATCH") or "").strip().lower()
    return "file" if raw == "file" else "stream"


# ─── Subscription backends ────────────────────────────────────────────
SUBSCRIPTION_BACKENDS = ("claude", "glm", "doubao")

_BACKEND_BASE_URLS = {
    "glm": "https://open.bigmodel.cn/api/anthropic",
    "doubao": "https://ark.cn-beijing.volces.com/api/plan",
}
_BACKEND_KEY_ENVS = {"glm": "GLM_PLAN_KEY", "doubao": "DOUBAO_PLAN_KEY"}
_BACKEND_LABELS = {
    "claude": "Claude (subscription)",
    "glm": "GLM (coding plan)",
    "doubao": "Doubao (agent plan)",
}


def _backend_key(backend: str) -> Optional[str]:
    env_name = _BACKEND_KEY_ENVS.get(backend)
    if not env_name:
        return None
    key = (os.environ.get(env_name) or "").strip()
    return key or None


def _npx_path() -> Optional[str]:
    return shutil.which("npx")


def backend_available(backend: str, for_photo: bool = False) -> bool:
    """Can [backend] serve a request right now? 'claude' rides the existing
    knobs; the vendor plans need their key — and, for GLM photos only, npx
    (the official vision MCP server is an npm package)."""
    if not is_configured():
        return False
    if backend == "claude":
        return True
    if backend not in _BACKEND_KEY_ENVS:
        return False
    if _backend_key(backend) is None:
        return False
    if backend == "glm" and for_photo and _npx_path() is None:
        return False
    return True


def login_state() -> str:
    """Whether this machine holds a Claude-plan sign-in for the CLI.

    'token' when the setup-token OAuth credential the phone's "Connect
    Claude" flow mints is present in the environment, else 'none'. Surfaced
    on /api/auth_check so a freshly provisioned phone can SEE that the
    server is already signed in instead of implying a re-connect is needed
    (2026-09-28). Presence, not validity: validity is proven by the next
    real analysis, whose auth failure the app reports explicitly.
    """
    return "token" if (os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or "").strip() else "none"


def backend_status() -> Dict[str, str]:
    """Per-backend one-phrase state for /api/auth_check — the phone's
    'Test connection' shows these so a missing server-side plan key is
    diagnosed from the couch, not from ssh."""
    status: Dict[str, str] = {"claude": status_label()}
    for backend in ("glm", "doubao"):
        if not is_enabled():
            status[backend] = "off"
        elif _cli_path() is None:
            status[backend] = "enabled, CLI missing"
        elif _backend_key(backend) is None:
            status[backend] = f"no key ({_BACKEND_KEY_ENVS[backend]})"
        elif backend == "glm" and _npx_path() is None:
            status[backend] = "key set, npx missing (vision MCP needs node)"
        else:
            status[backend] = "ready"
    return status


def _build_prompt(image_path: str, prompt: Optional[str] = None) -> str:
    return (
        f"Read the image file at {image_path} and analyze it.\n\n"
        f"{prompt or FOOD_DETECTION_PROMPT}"
    )


def _extra_flags() -> list:
    """CLAUDE_ANALYZER_EXTRA_FLAGS, shlex-split into argv elements.

    A malformed value (unbalanced quote) degrades to no extra flags — the
    analyzer must keep working rather than fail every photo on a typo.
    """
    raw = (os.environ.get("CLAUDE_ANALYZER_EXTRA_FLAGS") or "").strip()
    if not raw:
        return []
    try:
        return shlex.split(raw)
    except ValueError as e:
        log.warning(f"Ignoring malformed CLAUDE_ANALYZER_EXTRA_FLAGS: {e}")
        return []


# The app-facing per-request choices (2026-08-05). CLAUDE-ONLY, closed
# whitelists: these values become CLI argv, so free text is never accepted
# — the endpoints 400 anything else before a CLI run exists.
CLAUDE_PLAN_MODELS = ("opus", "sonnet", "haiku", "fable")
CLAUDE_PLAN_EFFORTS = ("low", "medium", "high")


def _plan_choice(backend: str, model: Optional[str],
                 effort: Optional[str]) -> Tuple[str, str]:
    """The (model, effort) of a request that a run of [backend] is given:
    a whitelisted value on the claude backend, else "" (the server's
    default). The one rule for the argv (_append_model_and_extra_flags)
    and for the answer memo's key (_answer_memo_key), so a value the run
    ignores can never split the memo."""
    if backend != "claude":
        return "", ""
    return ((model or "").strip() if model in CLAUDE_PLAN_MODELS else "",
            effort if effort in CLAUDE_PLAN_EFFORTS else "")


def _append_model_and_extra_flags(
    cmd: list, backend: str = "claude",
    model: Optional[str] = None, effort: Optional[str] = None,
) -> None:
    """Shared argv tail: optional --model/--effort, then extra flags last.

    The overrides are CLAUDE-ONLY: the vendor plans map Anthropic model
    names to their own models server-side (GLM: sonnet→glm-5.2; Doubao:
    per plan tier), and an Anthropic model id pushed at them is at best
    ignored and at worst a 400 on every photo. [model]/[effort] come from
    the API endpoints PRE-VALIDATED against the whitelists above; the env
    knob remains the owner's default when no request override arrives.
    """
    if backend == "claude":
        chosen, chosen_effort = _plan_choice(backend, model, effort)
        if not chosen:
            chosen = (os.environ.get("CLAUDE_ANALYZER_MODEL") or "").strip()
        if chosen:
            cmd += ["--model", chosen]
        if chosen_effort:
            cmd += ["--effort", chosen_effort]
    cmd += _extra_flags()


def _cli_env(backend: str = "claude") -> Dict[str, str]:
    # The CLI phones home for updates/telemetry on every run; both knobs
    # shave that off (and are harmless no-ops on CLIs that predate them).
    env = dict(os.environ)
    env["DISABLE_AUTOUPDATER"] = "1"
    env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    if backend in _BACKEND_BASE_URLS:
        env["ANTHROPIC_BASE_URL"] = _BACKEND_BASE_URLS[backend]
        env["ANTHROPIC_AUTH_TOKEN"] = _backend_key(backend) or ""
        # Scrub the Anthropic credentials: a vendor-plan run must never be
        # able to fall through to (and spend) the Claude subscription or an
        # API key — and the CLI prefers some of these over AUTH_TOKEN.
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        env.pop("ANTHROPIC_API_KEY", None)
        # Zhipu's own Claude Code setup doc prescribes a long API timeout;
        # harmless for Ark. Never override an operator's explicit value.
        env.setdefault("API_TIMEOUT_MS", "3000000")
    return env


def _stream_stdin(image_bytes: bytes, prompt: Optional[str] = None) -> str:
    """One stream-json user message: the analysis prompt plus the image as a
    base64 content block. Callers pass already-normalized JPEG bytes (the
    single-decode photo pipeline), hence the fixed image/jpeg media type."""
    message = {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Analyze the attached image.\n\n"
                            f"{prompt or FOOD_DETECTION_PROMPT}",
                },
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64.b64encode(image_bytes).decode("ascii"),
                    },
                },
            ],
        },
    }
    return json.dumps(message) + "\n"


def _parse_stream_result(stdout: str) -> Optional[Dict]:
    """The LAST {"type": "result"} line of the stream-json JSONL output —
    the same envelope shape as `--output-format json` (is_error, result,
    duration_ms, duration_api_ms, num_turns). Non-JSON lines and result-less
    events (init/assistant messages, stray warnings) are tolerated noise."""
    envelope = None
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
        except ValueError:
            continue
        if isinstance(candidate, dict) and candidate.get("type") == "result":
            envelope = candidate
    return envelope


def _result_text(envelope) -> Optional[str]:
    """The result string of a non-error envelope; None for any other shape."""
    if not isinstance(envelope, dict) or envelope.get("is_error"):
        return None
    text = envelope.get("result")
    if not isinstance(text, str) or not text.strip():
        return None
    return text


class PlanRefused(Exception):
    """The plan itself refused this run — not a CLI-shape failure.

    Distinct from None (the run happened and answered junk) and from
    AnalyzerBusy (contention). The model is simply not served by this
    subscription right now: a usage window is exhausted, or the chosen
    model needs purchased credits the plan does not include (Fable 5 on
    a Pro plan, verified live 2026-08-06). Retrying NOW — in place OR via
    the file path — reproduces it exactly, so callers must surface the
    REASON to the user instead of a generic 'no usable result'.

    [terminal] separates the two refusals, because only one of them is
    forever (2026-10-07): a model that needs credits stays refused until
    the user switches models, but a closed usage window reopens on its
    own schedule and the photo must survive until then. The API endpoints
    answer "retry": False for the first and "retry": "later" for the
    second; the installed app burned photos on False.
    """

    def __init__(self, reason: str, terminal: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.terminal = terminal


def _plan_refusal(stdout: str) -> Optional[PlanRefused]:
    """The PlanRefused (not raised) a stream output describes, or None.

    The CLI reports these as a terminal result envelope carrying
    is_error with an api_error_status (429), and/or a rate_limit_event
    whose errorCode is credits_required. Its own `result` text is already
    written for a human ("Fable 5 requires usage credits."), so it is
    preferred verbatim over anything we could invent.

    terminal is True only for the credits case — the errorCode says
    credits_required, or the CLI's sentence says credits. A bare 429 or a
    rejected rate_limit_info without that code is the plan's usage
    window: closed now, open later.
    """
    refused = False
    terminal = False
    message = None
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "rate_limit_event":
            info = event.get("rate_limit_info")
            if isinstance(info, dict):
                if info.get("errorCode") == "credits_required":
                    refused = True
                    terminal = True
                elif info.get("status") == "rejected":
                    refused = True
        if event.get("type") == "result" and event.get("is_error"):
            status = event.get("api_error_status")
            text = event.get("result")
            says_credits = isinstance(text, str) and "credit" in text.lower()
            if status == 429 or says_credits:
                refused = True
            if says_credits:
                terminal = True
            if isinstance(text, str) and text.strip():
                message = text.strip()
    if not refused:
        return None
    return PlanRefused(
        message or "this plan cannot serve the selected model right now",
        terminal=terminal)


def _log_cli_exit(proc) -> None:
    text = (proc.stderr or proc.stdout or "").strip()
    # Redact BEFORE truncating: a CLI that echoes a bad argument back into
    # stderr (e.g. "MCP config file not found: {...Z_AI_API_KEY...}") must
    # not put a plan key into the server log — and truncating first could
    # leave a recognizable key fragment straddling the cut.
    for backend in _BACKEND_KEY_ENVS:
        key = _backend_key(backend)
        if key:
            text = text.replace(key, "[redacted-plan-key]")
    snippet = text[:300]
    if "limit" in snippet.lower():
        log.warning(f"Claude CLI usage window likely exhausted: {snippet}")
    else:
        log.warning(f"Claude CLI exited {proc.returncode}: {snippet}")


def _finish_analysis(
    envelope: Dict, result_text: str, start: float,
    backend: str = "claude",
    require_is_food: bool = True,
) -> Optional[Dict]:
    """is_food-contract validation + success instrumentation, shared by all
    dispatch paths. None here means the MODEL answered junk — callers must
    treat it as terminal and never retry-spend on a model that answered.

    [require_is_food] False is the LEFTOVER estimation contract
    (2026-08-05): those replies are {same_meal, leftover_fraction, items}
    — still a dict, but the food gate does not apply; the app's pure
    apply layer owns every numeric clamp."""
    try:
        analysis = parse_ai_json(result_text)
    except (json.JSONDecodeError, ValueError) as e:
        # Keep the evidence: an empty reply, a rate-limit sentence and a
        # truncated object all read as "Expecting value" — the snippet is
        # what tells them apart next time (2026-09-29, 1 of 46 photos).
        snippet = repr((result_text or "")[:200])
        log.warning(f"Could not parse Claude analysis JSON: {e} "
                    f"(len={len(result_text or '')}, head={snippet})")
        return None
    if not isinstance(analysis, dict):
        log.warning("Claude analysis JSON was not an object.")
        return None
    if require_is_food and "is_food" not in analysis:
        log.warning("Claude analysis JSON missing the is_food contract.")
        return None
    # The CLI has no JSON mode, so is_food may arrive as a quoted
    # "false" — truthy downstream. Coerce to a real bool or reject.
    if require_is_food and not isinstance(analysis["is_food"], bool):
        coerced = parse_boolish(analysis["is_food"])
        if coerced is None:
            log.warning("Claude analysis is_food was not boolean-like.")
            return None
        analysis["is_food"] = coerced
    # Envelope timings split CLI overhead from API time, and num_turns
    # proves which dispatch actually answered (1 = single-turn stream) —
    # the evidence trail for tuning without touching the model choice.
    wall = time.time() - start
    label = _BACKEND_LABELS.get(backend, backend)
    log.info(
        f"✅ Photo analyzed by {label} in {wall:.1f}s "
        f"(cli={envelope.get('duration_ms')}ms "
        f"api={envelope.get('duration_api_ms')}ms "
        f"turns={envelope.get('num_turns')})."
    )
    return analysis


def _attempt_stream(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None, backend: str = "claude",
    require_is_food: bool = True,
    model: Optional[str] = None, effort: Optional[str] = None,
) -> Tuple[Optional[Dict], bool]:
    """Single-turn dispatch: image on stdin, no temp file, no tool turns.

    Returns (analysis, retry_via_file). retry_via_file is True only for
    CLI-shape failures — nonzero exit, no result line, unusable envelope —
    the cases an older CLI without stream-json support produces. A model
    that answered junk is terminal (None, False): retrying would
    double-spend the subscription for the same photo. A timeout raises
    AnalyzerTimeout — never a file-path retry either (it would double the
    wall clock for one photo), but the photo is fine to try again LATER.
    """
    cmd = [
        cli, "-p",
        # stdin carries the image; --input-format stream-json ERRORS unless
        # the output format matches, and -p only streams with --verbose.
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--tools", "",  # no tools: the answer must land in turn one
    ]
    _append_model_and_extra_flags(cmd, backend, model=model, effort=effort)
    try:
        proc = subprocess.run(
            cmd,
            input=_stream_stdin(image_bytes, prompt),
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            env=env,
        )
        if proc.returncode != 0:
            # A PLAN refusal exits nonzero too, but it is not a CLI-shape
            # failure: the file fallback would reproduce it verbatim and
            # the user needs the reason, not a retry (Fable-on-Pro,
            # 2026-08-06).
            refusal = _plan_refusal(proc.stdout)
            if refusal:
                log.warning(
                    f"Claude plan refused the run "
                    f"({'terminal' if refusal.terminal else 'usage window'})"
                    f": {refusal.reason}")
                raise refusal
            _log_cli_exit(proc)
            return None, True
        envelope = _parse_stream_result(proc.stdout)
        if envelope is None:
            log.warning("Claude CLI stream output had no result line.")
            return None, True
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI stream result envelope was unusable.")
            return None, True
        return _finish_analysis(envelope, text, start, backend,
                                require_is_food=require_is_food), False
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI timed out after {_timeout_seconds()}s.")
        # Raised from inside the handler, so the catch-all below does not
        # see it (sibling clauses never catch each other's raises).
        raise AnalyzerTimeout(_timeout_seconds())
    except PlanRefused:
        # Must reach the caller: the catch-all below would turn an
        # actionable "this plan cannot serve that model" into a silent
        # None, which is exactly the failure this class exists to end.
        raise
    except Exception as e:
        log.warning(f"Claude analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None, False


def _zai_mcp_config(key: str) -> str:
    """Inline --mcp-config JSON for Zhipu's OFFICIAL vision MCP server
    (docs.bigmodel.cn coding-plan vision-mcp doc): the coding-plan key IS
    the intended credential, Z_AI_MODE=ZHIPU selects the mainland platform."""
    return json.dumps({
        "mcpServers": {
            "zai": {
                "command": "npx",
                "args": ["-y", "@z_ai/mcp-server"],
                "env": {"Z_AI_API_KEY": key, "Z_AI_MODE": "ZHIPU"},
            }
        }
    })


def _attempt_glm_vision(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None,
    require_is_food: bool = True,
) -> Optional[Dict]:
    """GLM-backend photo dispatch: temp file + the official zai vision MCP.

    The GLM coding-plan Anthropic endpoint is TEXT-ONLY — an image content
    block never reaches a vision model there. Zhipu's sanctioned photo path
    for plan users is their first-party vision MCP server (GLM-4.6V) reading
    a LOCAL file, so this dispatch mirrors _attempt_file's temp-file shape
    but allows ONLY the zai MCP tools — never Read. A steered prompt could
    at worst point the vision tool at another IMAGE on this machine; it
    cannot read .env or any text secret, which is the exfiltration class the
    allow_file_fallback rule exists to stop.
    """
    key = _backend_key("glm")
    if key is None:
        return None
    if _npx_path() is None:
        log.warning("GLM vision needs npx (node) for @z_ai/mcp-server — "
                    "not installed on this machine.")
        return None
    tmp_path = None
    cfg_path = None
    work_dir = None
    try:
        # A dedicated EMPTY working directory: the image and the config
        # used to share /tmp, so the run's cwd contained the plan-key file.
        work_dir = tempfile.mkdtemp(prefix="ct_glm_run_")
        with tempfile.NamedTemporaryFile(
            prefix="ct_glm_", suffix=".jpg", delete=False, dir=work_dir
        ) as tmp:
            tmp_path = tmp.name
            tmp.write(image_bytes)
        # The mcp-config goes through a 0600 TEMP FILE, never inline argv:
        # inline JSON put the plan key into /proc/<pid>/cmdline for the
        # whole run, and a CLI that echoes a rejected argument into stderr
        # would hand it to _log_cli_exit (review 2026-07-30).
        # The config lives OUTSIDE work_dir on purpose (see above).
        with tempfile.NamedTemporaryFile(
            prefix="ct_glm_cfg_", suffix=".json", mode="w", delete=False
        ) as cfg:
            cfg_path = cfg.name
            cfg.write(_zai_mcp_config(key))

        cmd = [
            cli, "-p",
            (f"Use the zai vision tool to analyze the image file at "
             f"{tmp_path}, then answer.\n\n"
             f"{prompt or FOOD_DETECTION_PROMPT}"),
            "--output-format", "json",
            "--mcp-config", cfg_path,
            "--allowedTools", "mcp__zai",
            # --allowedTools is an AUTO-APPROVE list, not a disable list:
            # the built-in read-only tools stay available to a prompt that
            # carries caller-influenced text (the app's dietary profile).
            # Name them explicitly forbidden, and run in a scratch cwd —
            # the previous cwd held the temp MCP CONFIG with the plan key.
            "--disallowedTools", "Read,Glob,Grep,LS,Bash,Write,Edit,WebFetch",
            "--strict-mcp-config",
        ]
        _append_model_and_extra_flags(cmd, "glm")
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            cwd=work_dir,
            env=env,
        )
        if proc.returncode != 0:
            _log_cli_exit(proc)
            return None
        envelope = json.loads(proc.stdout)
        text = _result_text(envelope)
        if text is None:
            log.warning("GLM CLI returned an unusable result envelope.")
            return None
        # PROVE the vision tool actually ran. If the MCP server fails
        # after launch (npm registry unreachable, startup crash) the CLI
        # continues WITHOUT the tool and the model answers about an image
        # it never saw — and the prompt's "unclear → not food" rule makes
        # that a contract-valid wrong verdict. A real tool round-trip is
        # ≥2 turns; a single-turn envelope here is a blind run.
        turns = envelope.get("num_turns")
        if not isinstance(turns, int) or turns < 2:
            log.warning(
                f"GLM vision run had no tool round-trip (num_turns={turns})"
                " — the zai MCP server likely failed to start; discarding "
                "the blind answer.")
            return None
        return _finish_analysis(envelope, text, start, "glm",
                                require_is_food=require_is_food)
    except subprocess.TimeoutExpired:
        log.warning(f"GLM CLI timed out after {_timeout_seconds()}s.")
        raise AnalyzerTimeout(_timeout_seconds())
    except (json.JSONDecodeError, ValueError) as e:
        log.warning(f"Could not parse GLM CLI output: {e}")
        return None
    except Exception as e:
        log.warning(f"GLM analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None
    finally:
        for p in (tmp_path, cfg_path):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        if work_dir:
            try:
                os.rmdir(work_dir)
            except OSError:
                pass


def _attempt_file(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None,
    model: Optional[str] = None, effort: Optional[str] = None,
) -> Optional[Dict]:
    """Two-turn dispatch: temp image file + a Read-tool prompt. The
    compatibility fallback for CLIs without stream-json support, and the
    forced path under CLAUDE_ANALYZER_DISPATCH=file."""
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix="ct_claude_", suffix=".jpg", delete=False
        ) as tmp:
            # Record the path before writing so a failed write (e.g. ENOSPC)
            # still gets the file cleaned up by the finally block.
            tmp_path = tmp.name
            tmp.write(image_bytes)

        cmd = [
            cli, "-p", _build_prompt(tmp_path, prompt),
            "--output-format", "json",
            "--allowedTools", "Read",
        ]
        _append_model_and_extra_flags(cmd, model=model, effort=effort)
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            cwd=str(Path(tmp_path).parent),
            env=env,
        )
        if proc.returncode != 0:
            _log_cli_exit(proc)
            return None

        # `claude -p --output-format json` wraps the reply in a result envelope.
        envelope = json.loads(proc.stdout)
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI returned an unusable result envelope.")
            return None
        return _finish_analysis(envelope, text, start)
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI timed out after {_timeout_seconds()}s.")
        raise AnalyzerTimeout(_timeout_seconds())
    except (json.JSONDecodeError, ValueError) as e:
        log.warning(f"Could not parse Claude CLI output: {e}")
        return None
    except Exception as e:
        log.warning(f"Claude analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


# ─── The answer memo: an app photo sent again (2026-11-28) ────────────
#
# Why. An iPhone background scan gives up on its request 22 s after the
# scan began (iosRunDeadline in the app's background_glue.dart), and the
# open app's scan stops when its user leaves it. The server cannot see a
# phone hang up: werkzeug runs the view to its end and only then finds
# the connection gone. So the analysis was finished and its answer thrown
# away, and a phone that sent the same photo again soon paid for a second
# full run on the owner's plan: the open app's scan when its user came
# back, the app's own retry seconds later, a copy that waited behind its
# first. One background scan to the next is not soon: the app asks iOS
# for the next one no sooner than 30 minutes after one begins
# (AppDelegate.swift's frequency, which workmanager_apple re-submits at
# the start of each run), past the default window, so that send is a run
# of its own.
#
# What. The answer of each app photo or leftover analysis that succeeded
# is kept in memory for answer_memo_seconds() (default 600), at most
# ANSWER_MEMO_MAX_ENTRIES of them, the oldest dropped first. A request
# that is the same in everything that goes into the run gets that answer
# as it is (the endpoint's usual 200 body) and no CLI run. It is looked up
# twice: before the request waits for the CLI (a hit takes no lock and is
# no waiter), and again once the request holds the lock (a duplicate that
# waited behind its own first run does not start a second one).
#
# The key is a SHA-256 over what goes into the run and over nothing else:
# the kind of analysis, the endpoint and which of the two upload keys
# authenticated the request (memo_scope), the backend, the model and
# effort the run is given (_plan_choice), whether the Read-tool path is
# allowed, the prompt as composed (the profile, the recent meals and the
# reply language are all in it) and the image bytes as the analyzer gets
# them. What a caller sends and the server ignores (an unknown field, a
# blank profile, the client header) is not in it. The server's own
# settings are not in it. They change with a restart, which empties the
# memo; the plan's token also with a sign-in from the phone
# (claude_auth.apply_token_to_env), which empties it too
# (clear_answer_memo), since the new token may be another account with
# another default model. A key also holds _ANSWER_MEMO_EPOCH, which
# clear_answer_memo moves on: an analysis still running with the old
# token stores its answer under a key that no later request makes.
#
# The memo keeps only the hash and the answer: never the photo, never on
# disk, never in a log. The journal's line for a hit says how old the
# answer is, nothing more. Telegram and /upload photos and text requests
# pass no memo_scope and never use it (a person may type the same words
# twice on purpose).
ANSWER_MEMO_SECONDS_DEFAULT = 600
ANSWER_MEMO_SECONDS_MAX = 3600
# One analysis takes 8-15 s, so 64 answers are 8 to 16 minutes of
# analyses back to back: about the default window. Each is a small JSON
# object.
ANSWER_MEMO_MAX_ENTRIES = 64
_ANSWER_MEMO_KEY_VERSION = "chopstats answer memo 1"

# key (SHA-256 digest) -> (_memo_clock() when stored, the answer)
_ANSWER_MEMO: "OrderedDict[bytes, Tuple[float, Dict]]" = OrderedDict()
_ANSWER_MEMO_LOCK = threading.Lock()
# A part of every key; clear_answer_memo moves it on.
_ANSWER_MEMO_EPOCH = 0


def _memo_clock() -> float:
    """The memo's clock, in seconds (monotonic). A function of its own so
    that a test can move time on without waiting for it."""
    return time.monotonic()


def answer_memo_seconds() -> int:
    """CLAUDE_API_ANSWER_MEMO_SECONDS: how long the answer of an app photo
    or leftover analysis is kept for the same request sent again (default
    600, clamp 0..3600). 0 = off: nothing is kept and nothing is looked
    up. Junk reads as the default, and the journal says so once
    (_warn_knob_junk). An empty value is a knob left unset."""
    raw = os.environ.get("CLAUDE_API_ANSWER_MEMO_SECONDS",
                         str(ANSWER_MEMO_SECONDS_DEFAULT))
    try:
        value = int(raw)
    except ValueError:
        if raw.strip():
            _warn_knob_junk(
                "CLAUDE_API_ANSWER_MEMO_SECONDS", raw, _ANSWER_MEMO_JUNK_SEEN,
                "Answers are still kept for its default, "
                f"{ANSWER_MEMO_SECONDS_DEFAULT} s.")
        return ANSWER_MEMO_SECONDS_DEFAULT
    return min(max(value, 0), ANSWER_MEMO_SECONDS_MAX)


def _answer_memo_key(kind: str, scope: Optional[Tuple[str, ...]],
                     image_bytes: bytes, prompt: str, backend: str,
                     model: Optional[str], effort: Optional[str],
                     read_fallback: bool) -> Optional[bytes]:
    """The memo key of one run (the section comment says what is in it),
    or None when the caller passed no [scope]: then there is no memo for
    the call."""
    if scope is None:
        return None
    chosen_model, chosen_effort = _plan_choice(backend, model, effort)
    digest = hashlib.sha256()

    def part(value) -> None:
        # Each part with its length in front, so that two different
        # requests can never run together into the same bytes.
        # surrogatepass: caller text can hold a lone surrogate (JSON
        # carries one as an escape), which strict UTF-8 refuses to encode.
        # This encodes every str, and two different ones never alike.
        data = value if isinstance(value, bytes) else str(value).encode(
            "utf-8", "surrogatepass")
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)

    part(_ANSWER_MEMO_KEY_VERSION)
    part(_ANSWER_MEMO_EPOCH)
    part(kind)
    part(len(scope))
    for item in scope:
        part(item)
    part(backend)
    part(chosen_model)
    part(chosen_effort)
    part("read fallback" if read_fallback else "no read fallback")
    part(prompt)
    part(image_bytes)
    return digest.digest()


def _remembered_answer(key: Optional[bytes], kind: str) -> Optional[Dict]:
    """The answer kept under [key] if it is no older than
    answer_memo_seconds(), as a copy, with one journal line that says how
    old it is; else None. An entry past the limit is dropped here."""
    if key is None:
        return None
    limit = answer_memo_seconds()
    if limit <= 0:
        return None
    with _ANSWER_MEMO_LOCK:
        entry = _ANSWER_MEMO.get(key)
        if entry is None:
            return None
        stored_at, kept = entry
        # The clock is read with the lock held. Read before it, a store
        # that took the lock first looked younger than "now", and its
        # answer was dropped as if it came from the future (review
        # 2026-11-28).
        age = _memo_clock() - stored_at
        if age < 0 or age > limit:
            del _ANSWER_MEMO[key]
            return None
        answer = copy.deepcopy(kept)
    # A second lookup runs with _CLI_LOCK held, and the caller's finally
    # gives it back; still, an answer in hand is not lost to a logger.
    try:
        log.info(f"Answered from memory — app {kind} request: the answer is "
                 f"{age:.0f} s old, and the CLI did not run.")
    except Exception:
        pass
    return answer


def _remember_answer(key: Optional[bytes], answer) -> None:
    """Keep a copy of [answer] under [key]: a successful analysis only, a
    non-empty dict (a busy, refused or timed-out request raised before
    this, and an empty one is None). Called as the run returns, before the
    endpoint answers, so it happens also when the phone has gone. The
    oldest entries go first: those past the limit, then any past
    ANSWER_MEMO_MAX_ENTRIES."""
    if key is None or not isinstance(answer, dict) or not answer:
        return
    limit = answer_memo_seconds()
    if limit <= 0:
        return
    try:
        kept = copy.deepcopy(answer)
    except Exception as e:  # pragma: no cover - parsed JSON always copies
        # The request keeps its answer; the memo does without this one.
        log.warning(f"Answer memo: an answer could not be kept "
                    f"({type(e).__name__}).")
        return
    with _ANSWER_MEMO_LOCK:
        # With the lock held, as in _remembered_answer: the memo is then
        # oldest first in time as well as in order, and the pruning below
        # can stop at the first answer still in time.
        now = _memo_clock()
        _ANSWER_MEMO.pop(key, None)
        _ANSWER_MEMO[key] = (now, kept)
        while _ANSWER_MEMO:
            oldest, (stored_at, _) = next(iter(_ANSWER_MEMO.items()))
            if (len(_ANSWER_MEMO) > ANSWER_MEMO_MAX_ENTRIES
                    or now - stored_at > limit):
                del _ANSWER_MEMO[oldest]
            else:
                break


def clear_answer_memo() -> None:
    """Forget every kept answer, and every answer still being worked out:
    the epoch moves on, so a run that ends after this stores its answer
    under a key that no later request makes. A sign-in from the phone
    calls this (claude_auth.apply_token_to_env), and so do the tests; a
    restart does the same."""
    global _ANSWER_MEMO_EPOCH
    with _ANSWER_MEMO_LOCK:
        _ANSWER_MEMO.clear()
        _ANSWER_MEMO_EPOCH += 1


def analyze_text_prompt(prompt: str, backend: str = "claude",
                        model: Optional[str] = None,
                        effort: Optional[str] = None,
                        raise_on_busy: bool = False) -> Optional[Dict]:
    """Run an arbitrary JSON-answering prompt through the CLI (subscription).

    Used by the app-facing /api/text_intent endpoint so the phone's NL
    corrections cost no API money either. Same discipline as the photo path:
    single turn, no tools, serialized by _CLI_LOCK, and a contended CLI
    returns None (caller decides) rather than queueing behind a 120 s
    photo run — or, for the endpoint (raise_on_busy), waits its short
    turn and then raises AnalyzerBusy (_cli_for_request). Text works on
    ALL three backends: the vendor plans' Anthropic endpoints are
    text-native.
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend):
        return None
    cli = _cli_path()
    if cli is None or not (prompt or "").strip():
        return None
    if not _cli_for_request(raise_on_busy, "text",
                            "text intent declined."):
        return None
    start = time.time()
    try:
        cmd = [cli, "-p", "--output-format", "json", "--tools", ""]
        _append_model_and_extra_flags(cmd, backend, model=model,
                                      effort=effort)
        proc = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            env=_cli_env(backend),
        )
        if proc.returncode != 0:
            # The plan's own refusal (a closed usage window, or a model
            # that needs credits) is said once, in the CLI's words, like
            # the photo path does: a generic "no usable result" hid the
            # reset time (review 1.7.0).
            refusal = _plan_refusal(proc.stdout)
            if refusal:
                log.warning(
                    f"Claude plan refused the text intent "
                    f"({'terminal' if refusal.terminal else 'usage window'})"
                    f": {refusal.reason}")
                if raise_on_busy:
                    raise refusal
                return None
            _log_cli_exit(proc)
            return None
        try:
            envelope = json.loads(proc.stdout or "{}")
        except ValueError:
            log.warning("Claude CLI text output was not JSON.")
            return None
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI text envelope was unusable.")
            return None
        parsed = parse_ai_json(text)
        if not isinstance(parsed, (dict, list)):
            log.warning("Claude text reply was not a JSON object/array.")
            return None
        log.info(
            "Claude text intent ok in %.1fs (turns=%s)",
            time.time() - start,
            envelope.get("num_turns"),
        )
        return {"result": parsed}
    except PlanRefused:
        raise
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI text intent timed out after {_timeout_seconds()}s.")
        if raise_on_busy:
            raise AnalyzerTimeout(_timeout_seconds())
        return None
    except Exception as e:
        log.warning(f"Claude text intent failed: {type(e).__name__}: {e}")
        return None
    finally:
        _CLI_LOCK.release()


def analyze_leftover_photo(
    image_bytes: bytes,
    prompt: str,
    backend: str = "claude",
    raise_on_busy: bool = False,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    memo_scope: Optional[Tuple[str, ...]] = None,
) -> Optional[Dict]:
    """Estimate leftover fractions for a previously analyzed meal.

    [prompt] is ALWAYS composed server-side (the leftover template plus a
    re-sanitized compact original analysis) — and this path NEVER takes
    the Read-tool file fallback: the embedded original analysis came over
    the network, so the exfiltration rule for analyze_food_photo applies
    with no exceptions. The reply skips the is_food gate (leftover
    contract); every numeric clamp lives in the app's pure apply layer.

    [memo_scope] as for analyze_food_photo: the app's endpoint passes it,
    and the same leftover request sent again within answer_memo_seconds()
    gets the answer already worked out.
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend, for_photo=True):
        return None
    cli = _cli_path()
    if cli is None or not image_bytes or not (prompt or "").strip():
        return None
    memo_key = _answer_memo_key("leftover", memo_scope, image_bytes, prompt,
                                backend, model, effort, read_fallback=False)
    remembered = _remembered_answer(memo_key, "leftover")
    if remembered is not None:
        return remembered  # no lock taken, no waiter counted
    if not _cli_for_request(raise_on_busy, "leftover",
                            "leftover estimation declined."):
        return None
    try:
        # Again with the lock held: the run this request waited behind
        # may have been its own first copy.
        remembered = _remembered_answer(memo_key, "leftover")
        if remembered is not None:
            return remembered
        start = time.time()
        env = _cli_env(backend)
        if backend == "glm":
            analysis = _attempt_glm_vision(cli, image_bytes, env, start,
                                           prompt, require_is_food=False)
        else:
            try:
                analysis, _retry = _attempt_stream(
                    cli, image_bytes, env, start, prompt, backend,
                    require_is_food=False, model=model, effort=effort)
            except PlanRefused:
                if raise_on_busy:
                    raise
                return None
        _remember_answer(memo_key, analysis)
        return analysis
    except AnalyzerTimeout:
        # Same opt-in as PlanRefused: only the API endpoints want the
        # distinct signal; every other caller keeps None.
        if raise_on_busy:
            raise
        return None
    finally:
        _CLI_LOCK.release()


def _food_photo_run(
    cli: str, image_bytes: bytes, prompt: Optional[str],
    allow_file_fallback: bool, backend: str, raise_on_busy: bool,
    model: Optional[str], effort: Optional[str],
) -> Optional[Dict]:
    """One photo run, with _CLI_LOCK held by analyze_food_photo (which
    also turns AnalyzerTimeout into None for callers without
    raise_on_busy): the GLM vision path, the Doubao stream, or the stream
    with its file fallback."""
    start = time.time()
    env = _cli_env(backend)
    if backend == "glm":
        # Text-only Anthropic endpoint: the stream dispatch cannot
        # carry the image; the vision MCP path is the ONLY photo path.
        return _attempt_glm_vision(cli, image_bytes, env, start, prompt)
    if backend == "doubao":
        try:
            analysis, _ = _attempt_stream(
                cli, image_bytes, env, start, prompt, backend)
        except PlanRefused:
            if raise_on_busy:
                raise
            return None
        return analysis
    # A caller-influenced prompt (allow_file_fallback=False) always takes
    # the tools-off stream dispatch, even under the 'file' rollback knob:
    # the Read-enabled path must never see network text.
    if _dispatch_mode() == "stream" or not allow_file_fallback:
        try:
            analysis, retry_via_file = _attempt_stream(
                cli, image_bytes, env, start, prompt,
                model=model, effort=effort)
        except PlanRefused:
            # Only API callers want the reason; the Telegram path keeps
            # its documented "None -> fall back to Gemini" contract.
            if raise_on_busy:
                raise
            return None
        if not retry_via_file:
            return analysis
        if not allow_file_fallback:
            # Caller-influenced prompt: refuse the Read-enabled path.
            log.warning(
                "Claude stream dispatch failed for an API-originated "
                "request — NOT falling back to the Read-tool path."
            )
            return None
        log.warning(
            "Claude stream-json dispatch failed — retrying once via the "
            "two-turn Read-file path."
        )
    return _attempt_file(cli, image_bytes, env, start, prompt,
                         model=model, effort=effort)


def analyze_food_photo(
    image_bytes: bytes,
    prompt: Optional[str] = None,
    allow_file_fallback: bool = True,
    backend: str = "claude",
    raise_on_busy: bool = False,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    memo_scope: Optional[Tuple[str, ...]] = None,
) -> Optional[Dict]:
    """Analyze a food photo via the Claude Code CLI; None means 'use Gemini'.

    [prompt] overrides the built-in FOOD_DETECTION_PROMPT (the API endpoint
    composes one from the app's dietary profile).

    [memo_scope] turns the answer memo on for this call (the section above
    analyze_text_prompt): the endpoint and which upload key authenticated
    the request, the caller's part of the memo key. The same request sent
    again within answer_memo_seconds() then gets the answer already worked
    out, without a run. Only the app's endpoints pass it; None (Telegram,
    /upload) keeps every call a run of its own.

    [allow_file_fallback] MUST be False whenever any part of the prompt came
    from a network caller. The stream dispatch runs with `--tools ""`, but
    the file fallback necessarily enables the Read tool to load the temp
    image — and a caller who can steer that prompt could read arbitrary
    files (e.g. the .env holding the subscription token) and have the
    content returned inside the analysis JSON. Reaching the fallback does
    not even need the rollback knob: a prompt that produces no output makes
    the stream attempt look like a CLI-shape failure.

    [backend] selects whose subscription pays: 'claude' (default, the
    existing path), 'glm' (coding plan; photos via the official vision MCP),
    or 'doubao' (agent plan; stream dispatch only — its Read-file fallback
    is refused unconditionally since image-block support there is already
    the experiment, and a Read-enabled retry adds the exfiltration surface
    on top of an unknown).
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend, for_photo=True):
        return None
    cli = _cli_path()
    if cli is None or not image_bytes:
        return None

    memo_key = _answer_memo_key(
        "photo", memo_scope, image_bytes, prompt or FOOD_DETECTION_PROMPT,
        backend, model, effort, read_fallback=allow_file_fallback)
    remembered = _remembered_answer(memo_key, "photo")
    if remembered is not None:
        return remembered  # no lock taken, no waiter counted

    # Contended-CLI bypass: another photo already owns the (up to 120s) CLI
    # run. Don't queue behind it — Gemini answers this photo in seconds.
    # Default False keeps the TELEGRAM contract ("None → use Gemini")
    # byte-identical; only the API endpoints opt in, because only they
    # need to tell the app "retry in seconds" from "do not retry" — and
    # only their requests, which have no Gemini, wait a short turn for
    # the CLI before they are told so (_cli_for_request).
    if not _cli_for_request(raise_on_busy, "photo",
                            "falling back to Gemini for this photo."):
        return None

    # One photo = one CLI occupancy: the lock is held across BOTH attempts
    # of the stream→file fallback chain, so a burst can never stack the
    # memory-heavy CLI even mid-fallback.
    try:
        # Again with the lock held: the run this request waited behind
        # may have been its own first copy.
        remembered = _remembered_answer(memo_key, "photo")
        if remembered is not None:
            return remembered
        analysis = _food_photo_run(cli, image_bytes, prompt,
                                   allow_file_fallback, backend,
                                   raise_on_busy, model, effort)
        _remember_answer(memo_key, analysis)
        return analysis
    except AnalyzerTimeout:
        # Every dispatch (stream, file, GLM vision) raises this on the
        # wall-clock limit. Only API callers want it as a signal — the
        # Telegram path keeps "None -> fall back to Gemini" — and no
        # dispatch is retried after it: the lock was held for the full
        # limit already.
        if raise_on_busy:
            raise
        return None
    finally:
        _CLI_LOCK.release()


# ─── Restaurant lookup (R3a): WebSearch-only runner, streaming init guard ──
#
# The ONLY CLI path that gets a network tool, so every part of it is
# pinned here rather than shared with the photo/text paths:
#   * argv: build_lookup_argv — one builder, never CLAUDE_ANALYZER_EXTRA_FLAGS
#     or a caller-chosen flag; the prompt goes in on stdin;
#   * env: exactly LOOKUP_ENV_KEYS plus two fixed knobs — no upload key,
#     plan key or API key reaches a process that reads web pages;
#   * the FIRST stdout line must be the system/init event and match
#     LOOKUP_INIT_EXPECT, or the process group is SIGKILLed before another
#     line is read. Verified on 2026-10-23 against the installed
#     claude 2.1.233 with this exact argv (offline: fake token, API base
#     on a closed localhost port): tools == [StructuredOutput, WebSearch]
#     (--json-schema adds StructuredOutput), mcp_servers == [],
#     plugins == [], permissionMode dontAsk, memory_paths absent under
#     --safe-mode (present without it), apiKeySource "none" with
#     CLAUDE_CODE_OAUTH_TOKEN set, init 1.2 s after spawn;
#   * a tool_use for any other tool later in the stream is also a kill;
#   * cited URLs come only from the structured WebSearch link list, never
#     from model-written text;
#   * its own logging: status, verdict, duration and counts. Never the
#     prompt, queries, URLs or output — those hold restaurant and dish
#     names (_finish_analysis / _log_cli_exit are never called here).

LOOKUP_DISALLOWED_TOOLS = ("Bash,Read,Write,Edit,Glob,Grep,LS,WebFetch,"
                           "NotebookEdit,Task,mcp__*")
LOOKUP_INIT_EXPECT = {
    "tools": frozenset({"WebSearch", "StructuredOutput"}),
    "mcp_servers": [],
    "plugins": [],
    "permissionMode": "dontAsk",
    "absent": ("memory_paths",),
}
LOOKUP_KEY_SOURCES_DEFAULT = ("none",)
LOOKUP_ENV_KEYS = ("PATH", "HOME", "LANG", "CLAUDE_CODE_OAUTH_TOKEN")
LOOKUP_MODEL_DEFAULT = "sonnet"
LOOKUP_TIMEOUT_SECONDS_DEFAULT = 180  # for CLAUDE_LOOKUP_TIMEOUT_SECONDS
LOOKUP_INIT_DEADLINE_SECONDS = 10  # default for CLAUDE_LOOKUP_INIT_SECONDS
LOOKUP_READ_SLICE_SECONDS = 0.25  # how often a blocked read checks cancel
LOOKUP_EXIT_GRACE_SECONDS = 5
LOOKUP_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
LOOKUP_MAX_LINE_BYTES = 2 * 1024 * 1024
LOOKUP_EVIDENCE_TEXT_CAP = 4000
LOOKUP_MAX_URLS = 20
LOOKUP_URL_CAP = 500

_lookup_log = logging.getLogger("claude_analyzer.lookup")
_LOOKUP_MODEL_RE = re.compile(r"^[A-Za-z0-9._\[\]-]{1,64}$")
_LOOKUP_CODE_RE = re.compile(r"^[a-z_]{1,40}$")
_LINKS_PREFIX = "Links: "


def lookup_model() -> str:
    """CLAUDE_LOOKUP_MODEL (default 'sonnet'); anything that is not a
    plain model name/alias falls back to the default — it becomes argv.
    'haiku' uses less plan usage but was wrong on build-your-own items
    in the first live runs (2026-11-05: sonnet 4 of 4 lookups correct,
    haiku 2 of 4)."""
    raw = (os.environ.get("CLAUDE_LOOKUP_MODEL") or "").strip()
    return raw if raw and _LOOKUP_MODEL_RE.match(raw) else LOOKUP_MODEL_DEFAULT


def lookup_timeout_seconds() -> int:
    """CLAUDE_LOOKUP_TIMEOUT_SECONDS: the wall clock one lookup may take
    (default 180, clamp 20..300). A lookup took about 25-135 s in the
    first live runs (2026-11-05)."""
    try:
        value = int(os.environ.get("CLAUDE_LOOKUP_TIMEOUT_SECONDS",
                                   str(LOOKUP_TIMEOUT_SECONDS_DEFAULT)))
    except ValueError:
        return LOOKUP_TIMEOUT_SECONDS_DEFAULT
    return min(max(value, 20), 300)


def lookup_init_deadline_seconds() -> float:
    """CLAUDE_LOOKUP_INIT_SECONDS: how long the CLI may take to print its
    init event (default 10, clamp 5..30) — a cold Node start on a small
    VM can be slow; the smoke script prints the measured latency."""
    raw = os.environ.get("CLAUDE_LOOKUP_INIT_SECONDS")
    if raw is None or not raw.strip():
        return LOOKUP_INIT_DEADLINE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        return LOOKUP_INIT_DEADLINE_SECONDS
    return min(max(value, 5), 30)


def lookup_key_sources() -> frozenset:
    """apiKeySource values the init guard accepts. Default {'none'} — what
    2.1.233 reports for an OAuth token; CLAUDE_LOOKUP_KEY_SOURCE
    (comma-separated) overrides it once the VM smoke shows its value."""
    raw = os.environ.get("CLAUDE_LOOKUP_KEY_SOURCE")
    parts = [p.strip() for p in (raw or "").split(",") if p.strip()]
    return frozenset(parts or LOOKUP_KEY_SOURCES_DEFAULT)


def build_lookup_argv(cli: str, schema_json: str, model: str) -> List[str]:
    """The lookup argv — the single builder, pinned by tests."""
    return [
        cli, "-p",
        "--safe-mode",
        "--output-format", "stream-json",
        "--verbose",
        "--tools", "WebSearch",
        "--allowedTools", "WebSearch",
        "--disallowedTools", LOOKUP_DISALLOWED_TOOLS,
        "--permission-mode", "dontAsk",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--json-schema", schema_json,
        "--model", model,
    ]


def lookup_env() -> Dict[str, str]:
    """The lookup child's ENTIRE environment: an allowlist, not a scrub."""
    env = {k: os.environ[k] for k in LOOKUP_ENV_KEYS if os.environ.get(k)}
    env.setdefault("LANG", "C.UTF-8")
    env["DISABLE_AUTOUPDATER"] = "1"
    env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    return env


def lookup_init_verdict(event, key_sources=None) -> Optional[str]:
    """None when the init event matches LOOKUP_INIT_EXPECT, else the name
    of the first field that does not (missing counts as different)."""
    if not isinstance(event, dict) or event.get("type") != "system" \
            or event.get("subtype") != "init":
        return "not_init"
    tools = event.get("tools")
    expected = LOOKUP_INIT_EXPECT["tools"]
    if not isinstance(tools, list) or len(tools) != len(expected) \
            or not all(isinstance(t, str) for t in tools) \
            or set(tools) != expected:
        return "tools"
    for key in ("mcp_servers", "plugins", "permissionMode"):
        if key not in event or event[key] != LOOKUP_INIT_EXPECT[key]:
            return key
    for key in LOOKUP_INIT_EXPECT["absent"]:
        if key in event:
            return key
    source = event.get("apiKeySource")
    sources = lookup_key_sources() if key_sources is None else key_sources
    if not isinstance(source, str) or source not in sources:
        return "apiKeySource"
    return None


def _init_summary(event) -> Dict:
    """The non-secret init facts the smoke script prints."""
    if not isinstance(event, dict):
        return {}
    tools = event.get("tools")
    source = event.get("apiKeySource")
    version = event.get("claude_code_version")
    mode = event.get("permissionMode")
    return {
        "tools": (sorted(t for t in tools if isinstance(t, str))
                  if isinstance(tools, list) else None),
        "apiKeySource": source[:40] if isinstance(source, str) else None,
        "claude_code_version": version[:20] if isinstance(version, str) else None,
        "permissionMode": mode[:20] if isinstance(mode, str) else None,
        "mcp_servers": (len(event["mcp_servers"])
                        if isinstance(event.get("mcp_servers"), list) else None),
        "plugins": (len(event["plugins"])
                    if isinstance(event.get("plugins"), list) else None),
        "memory_paths": "memory_paths" in event,
    }


@dataclass
class LookupRun:
    """One lookup CLI run. status: ok | init_ok (stop_after_init) |
    guard_fail | timeout | preempted | cli_error | bad_output |
    plan_refused | unavailable | refused. verdict refines it with a fixed
    code (guard_fail:<field>, no_result, …) — never caller or model text."""
    status: str
    verdict: str = ""
    result: Optional[Dict] = None
    cited_urls: List[str] = field(default_factory=list)
    evidence: List[Dict] = field(default_factory=list)
    searches: int = 0
    duration_s: float = 0.0
    init_s: float = 0.0
    lines_read: int = 0
    started: bool = False
    init: Dict = field(default_factory=dict)


class _ReadTimeout(Exception):
    pass


class _OutputOverflow(Exception):
    pass


class _Cancelled(Exception):
    pass


class _LineReader:
    """Line-at-a-time reads from a pipe with a deadline (a selector +
    os.read), so the caller decides about EACH line before the next is
    parsed, and a silent or flooding child can never hold the CLI lock
    past the limit. A set [cancel] event ends a blocked read within
    LOOKUP_READ_SLICE_SECONDS — a pre-emption never waits for pipe EOF,
    which a descendant that left the process group could hold open."""

    def __init__(self, fd: int, cancel: Optional[threading.Event] = None):
        self._fd = fd
        self._cancel = cancel
        self._buf = b""
        self._eof = False
        self._total = 0
        # selectors, not select.select: no FD_SETSIZE limit in a
        # long-running process with many sockets.
        self._selector = selectors.DefaultSelector()
        self._selector.register(fd, selectors.EVENT_READ)

    def close(self) -> None:
        try:
            self._selector.close()
        except (OSError, ValueError):  # pragma: no cover - best effort
            pass

    def readline(self, deadline: float) -> bytes:
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl + 1], self._buf[nl + 1:]
                return line
            if self._eof:
                line, self._buf = self._buf, b""
                return line
            if len(self._buf) > LOOKUP_MAX_LINE_BYTES:
                raise _OutputOverflow()
            if self._cancel is not None and self._cancel.is_set():
                raise _Cancelled()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _ReadTimeout()
            if self._cancel is not None:
                remaining = min(remaining, LOOKUP_READ_SLICE_SECONDS)
            if not self._selector.select(remaining):
                continue  # re-checks cancel and the deadline
            chunk = os.read(self._fd, 65536)
            if not chunk:
                self._eof = True
                continue
            self._total += len(chunk)
            if self._total > LOOKUP_MAX_OUTPUT_BYTES:
                raise _OutputOverflow()
            self._buf += chunk


def _signal_group(proc) -> None:
    """SIGKILL the lookup's whole process group (it runs in its own
    session). Only while the leader is unreaped, so the group id cannot
    have been recycled. Never waits."""
    if proc is not None and proc.returncode is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass


def _safe_lookup_url(value) -> Optional[str]:
    if not isinstance(value, str) or len(value) > LOOKUP_URL_CAP:
        return None
    if not re.match(r"^https?://[^\s/?#]+", value):
        return None
    if any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return None
    return value


def _tool_result_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b["text"] for b in content
            if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _links_from_structured(tool_use_result) -> Optional[Tuple[list, str]]:
    """(urls, text) from the WebSearch tool's structured result
    {query, results: [{tool_use_id, content: [{title, url}]} | str],
    durationSeconds}; None when it is not that shape. Only the link
    objects' url fields count — strings are the search's prose."""
    if not isinstance(tool_use_result, dict):
        return None
    results = tool_use_result.get("results")
    if not isinstance(results, list):
        return None
    urls, texts = [], []
    for entry in results:
        if isinstance(entry, str):
            texts.append(entry)
        elif isinstance(entry, dict) and isinstance(entry.get("content"), list):
            urls.extend(link.get("url") for link in entry["content"]
                        if isinstance(link, dict))
    return urls, "\n".join(texts)


def _links_from_text(text: str) -> Tuple[list, str]:
    """(urls, prose) from a WebSearch tool_result's text: each line that
    STARTS with 'Links: ' followed by a JSON array of {title, url} objects
    and nothing else is parsed with json (raw_decode), never a URL regex;
    an array of any other shape is just prose. The header line (the
    search query) and the CLI's REMINDER line are not evidence."""
    decoder = json.JSONDecoder()
    urls, prose = [], []
    for line in text.splitlines():
        if line.startswith(_LINKS_PREFIX):
            try:
                arr, end = decoder.raw_decode(line, len(_LINKS_PREFIX))
            except ValueError:
                arr, end = None, 0
            if isinstance(arr, list) and arr and not line[end:].strip() \
                    and all(isinstance(e, dict) and set(e) <= {"title", "url"}
                            for e in arr):
                urls.extend(e.get("url") for e in arr)
                continue
        if line.startswith("Web search results for query:") \
                or line.startswith("REMINDER:"):
            continue
        prose.append(line)
    return urls, "\n".join(prose)


def _collect_search_results(event: Dict, ws_ids: set, searches: list) -> None:
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    blocks = [b for b in content
              if isinstance(b, dict) and b.get("type") == "tool_result"
              and isinstance(b.get("tool_use_id"), str)
              and b["tool_use_id"] in ws_ids]
    # The event-level tool_use_result belongs to the event's tool result;
    # it is only unambiguous when there is exactly one.
    structured = (_links_from_structured(event.get("tool_use_result"))
                  if len(blocks) == 1 else None)
    for block in blocks:
        if block.get("is_error"):
            continue
        if structured is not None:
            urls, text = structured
        else:
            urls, text = _links_from_text(
                _tool_result_text(block.get("content")))
        clean: List[str] = []
        for url in urls:
            url = _safe_lookup_url(url)
            if url and url not in clean:
                clean.append(url)
        searches.append({"urls": clean,
                         "text": text.strip()[:LOOKUP_EVIDENCE_TEXT_CAP]})


# Tool calls a lookup may make, per content-block type. Any other block
# whose type ends in "tool_use" (server_tool_use web_fetch or
# code_execution, mcp_tool_use, a type a future CLI adds) is a kill.
_LOOKUP_TOOL_USES = {
    "tool_use": frozenset({"WebSearch", "StructuredOutput"}),
    # The API's own search tool, the one WebSearch wraps.
    "server_tool_use": frozenset({"web_search"}),
}


def _unexpected_tool_use(event: Dict, ws_ids: set) -> bool:
    """Record WebSearch tool_use ids; True for any tool outside the
    expected set (the init guard's promise, re-checked per call)."""
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return False
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if not isinstance(kind, str) or not kind.endswith("tool_use"):
            continue
        name = block.get("name")
        if name not in _LOOKUP_TOOL_USES.get(kind, ()):
            return True
        if kind == "tool_use" and name == "WebSearch" \
                and isinstance(block.get("id"), str):
            ws_ids.add(block["id"])
    return False


def _finish_lookup(run: LookupRun, envelope: Dict, refused: bool) -> None:
    if envelope.get("is_error"):
        text = envelope.get("result")
        if refused or envelope.get("api_error_status") == 429 or (
                isinstance(text, str) and "credit" in text.lower()):
            run.status = run.verdict = "plan_refused"
        else:
            subtype = envelope.get("subtype")
            run.status = "cli_error"
            run.verdict = (subtype if isinstance(subtype, str)
                           and _LOOKUP_CODE_RE.match(subtype) else "is_error")
        return
    result = envelope.get("structured_output")
    if not isinstance(result, dict):
        result = None
        text = envelope.get("result")
        if isinstance(text, str) and text.strip():
            try:
                parsed = parse_ai_json(text)
            except (ValueError, RecursionError):
                parsed = None
            result = parsed if isinstance(parsed, dict) else None
    if result is None:
        run.status = run.verdict = "bad_output"
        return
    run.result = result
    run.status = run.verdict = "ok"


def _read_lookup_stream(proc, run: LookupRun, start: float,
                        on_line, stop_after_init: bool,
                        cancel: Optional[threading.Event] = None) -> None:
    reader = _LineReader(proc.stdout.fileno(), cancel)
    deadline = start + lookup_timeout_seconds()
    ws_ids: set = set()
    searches: list = []
    envelope = None
    refused = False
    try:
        line = reader.readline(
            min(deadline, start + lookup_init_deadline_seconds()))
        if not line:
            run.status, run.verdict = "cli_error", "no_init"
            return
        run.lines_read = 1
        run.init_s = round(time.monotonic() - start, 2)
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            event = None
        verdict = lookup_init_verdict(event)
        if verdict is not None:
            _signal_group(proc)  # before ANY further line is read
            run.status, run.verdict = "guard_fail", f"guard_fail:{verdict}"
            run.init = _init_summary(event)
            return
        run.init = _init_summary(event)
        if on_line is not None:
            on_line(line.decode("utf-8", "replace"))
        if stop_after_init:
            _signal_group(proc)
            run.status = run.verdict = "init_ok"
            return
        while True:
            line = reader.readline(deadline)
            if not line:
                break
            run.lines_read += 1
            if on_line is not None:
                on_line(line.decode("utf-8", "replace"))
            try:
                event = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(event, dict):
                continue
            kind = event.get("type")
            if kind == "assistant":
                if _unexpected_tool_use(event, ws_ids):
                    _signal_group(proc)
                    run.status, run.verdict = "guard_fail", "guard_fail:tool_use"
                    return
            elif kind == "user":
                _collect_search_results(event, ws_ids, searches)
            elif kind == "rate_limit_event":
                info = event.get("rate_limit_info")
                if isinstance(info, dict) and (
                        info.get("status") == "rejected"
                        or info.get("errorCode") == "credits_required"):
                    refused = True
            elif kind == "result":
                envelope = event
                break
    except _ReadTimeout:
        _signal_group(proc)
        if run.lines_read == 0:
            run.status, run.verdict = "guard_fail", "guard_fail:init_timeout"
        else:
            run.status, run.verdict = "timeout", "timeout"
        return
    except _OutputOverflow:
        _signal_group(proc)
        run.status, run.verdict = "cli_error", "output_too_large"
        return
    except _Cancelled:
        # Pre-empted: the group is already dead or dying; do not wait
        # for EOF (an escaped descendant could hold the pipe open).
        _signal_group(proc)
        run.status = run.verdict = "preempted"
        return
    except (OSError, ValueError):
        _signal_group(proc)
        run.status, run.verdict = "cli_error", "read_error"
        return
    finally:
        reader.close()
        run.searches = len(ws_ids)
        cited: List[str] = []
        for search in searches:
            for url in search["urls"]:
                if url not in cited and len(cited) < LOOKUP_MAX_URLS:
                    cited.append(url)
        run.cited_urls = cited
        run.evidence = searches
    _signal_group(proc)  # the answer is in; nothing else is needed
    if envelope is None:
        run.status, run.verdict = "cli_error", "no_result"
        return
    _finish_lookup(run, envelope, refused)


def lookup_restaurant(
    prompt_text: str,
    schema_json: str,
    model: Optional[str] = None,
    on_proc: Optional[Callable] = None,
    on_line: Optional[Callable[[str], None]] = None,
    stop_after_init: bool = False,
    cancel: Optional[threading.Event] = None,
) -> LookupRun:
    """Run ONE restaurant lookup through the CLI (Claude backend only).

    [prompt_text] is composed server-side (lookup_contract.compose_prompt)
    and goes in on stdin. [on_proc] is called with the Popen right after
    spawn (False → kill at once: pre-empted before it began) and with None
    right before the child is reaped. [on_line] sees each raw line the
    runner processed (the smoke script's fixture recorder).
    [stop_after_init] kills the run right after a PASSING init guard —
    the smoke script's zero-usage check of the guard on the VM.
    [cancel] set (pre-emption) ends the run as 'preempted' at once: no
    spawn if it is already set, and a blocked read stops within
    LOOKUP_READ_SLICE_SECONDS instead of waiting for pipe EOF.

    Never raises for run failures; the LookupRun says what happened.
    Does NOT take _CLI_LOCK — run_lookup_exclusive does.
    """
    start = time.monotonic()
    run = LookupRun(status="unavailable", verdict="cli_missing")
    cli = _cli_path()
    if not is_configured() or cli is None:
        _log_lookup(run)
        return run
    if not (prompt_text or "").strip():
        run.verdict = "empty_prompt"
        _log_lookup(run)
        return run
    if cancel is not None and cancel.is_set():
        run.status = run.verdict = "preempted"
        _log_lookup(run)
        return run
    work_dir = tempfile.mkdtemp(prefix="ct_lookup_")
    proc = None
    try:
        try:
            proc = subprocess.Popen(
                build_lookup_argv(cli, schema_json, model or lookup_model()),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=work_dir,
                env=lookup_env(),
                start_new_session=True,
            )
        except OSError:
            run.status, run.verdict = "cli_error", "spawn_failed"
            return run
        run.started = True
        if on_proc is not None and on_proc(proc) is False:
            _signal_group(proc)
            run.status = run.verdict = "preempted"
            return run
        try:
            proc.stdin.write(prompt_text.encode("utf-8"))
            proc.stdin.close()
        except OSError:
            pass  # the child died early; the reader sees its exit
        _read_lookup_stream(proc, run, start, on_line, stop_after_init,
                            cancel)
        return run
    finally:
        if proc is not None:
            if on_proc is not None:
                on_proc(None)
            _signal_group(proc)
            try:
                proc.wait(timeout=LOOKUP_EXIT_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
            for pipe in (proc.stdin, proc.stdout):
                try:
                    pipe.close()
                except (OSError, AttributeError):
                    pass
        shutil.rmtree(work_dir, ignore_errors=True)
        run.duration_s = round(time.monotonic() - start, 2)
        if run.status != "unavailable":
            _log_lookup(run)


def _log_lookup(run: LookupRun) -> None:
    level = logging.WARNING if run.status in (
        "guard_fail", "cli_error", "bad_output") else logging.INFO
    _lookup_log.log(
        level, "Restaurant lookup %s (%s) in %.1fs; searches=%d lines=%d",
        run.status, run.verdict, run.duration_s, run.searches, run.lines_read)


def _register_lookup_proc(proc) -> bool:
    with _LOOKUP_STATE_LOCK:
        _LOOKUP_STATE["proc"] = proc
        return not (proc is not None and _LOOKUP_STATE["preempted"])


def _preempt_locked() -> None:
    """Mark the holding lookup pre-empted, wake its reader and kill its
    process group. Call with _LOOKUP_STATE_LOCK held."""
    _LOOKUP_STATE["preempted"] = True
    cancel = _LOOKUP_STATE["cancel"]
    if cancel is not None:
        cancel.set()
    _signal_group(_LOOKUP_STATE["proc"])


def preempt_lookup() -> bool:
    """Kill a lookup that holds the CLI so a foreground request can run.
    True when a lookup held it. (Foreground callers go through
    _acquire_cli_for_foreground, which also keeps the next lookup from
    taking the lock while they wait.)"""
    with _LOOKUP_STATE_LOCK:
        if not _LOOKUP_STATE["holding"]:
            return False
        _preempt_locked()
    _lookup_log.info("Restaurant lookup pre-empted by a foreground request.")
    return True


def run_lookup_exclusive(
    prompt_text: str,
    schema_json: str,
    model: Optional[str] = None,
    on_start: Optional[Callable[[], bool]] = None,
) -> Optional[LookupRun]:
    """lookup_restaurant under _CLI_LOCK, pre-emptible by any photo,
    leftover or text request. None = the CLI is busy right now, or a
    foreground request is waiting for it (the job worker polls again).
    [on_start] runs once the lock is held and before the CLI starts;
    False aborts with status 'refused' (the daily cap)."""
    with _LOOKUP_STATE_LOCK:
        if _LOOKUP_STATE["fg_waiting"] or not _CLI_LOCK.acquire(blocking=False):
            return None
        cancel = threading.Event()
        _LOOKUP_STATE.update(holding=True, proc=None, preempted=False,
                             cancel=cancel)
    try:
        if on_start is not None and not on_start():
            return LookupRun(status="refused", verdict="refused")
        run = lookup_restaurant(prompt_text, schema_json, model,
                                on_proc=_register_lookup_proc, cancel=cancel)
        with _LOOKUP_STATE_LOCK:
            preempted = bool(_LOOKUP_STATE["preempted"])
        if preempted and run.status != "ok":
            run.status = run.verdict = "preempted"
        return run
    finally:
        with _LOOKUP_STATE_LOCK:
            _LOOKUP_STATE.update(holding=False, proc=None, preempted=False,
                                 cancel=None)
            _CLI_LOCK.release()
