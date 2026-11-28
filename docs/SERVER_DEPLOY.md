# Deploying the server (checklist)

The server on your VM only changes when you deploy it. This page is the
procedure that matches [SERVER.md](SERVER.md): `git archive` tarball,
systemd `caloriebot.service`. Placeholders `$VM`, `$ZONE`, `$PROJECT`
come from your private notes. Never paste the VM address, the upload key
or the OAuth token into a terminal transcript or a chat.

"The first rollout" on this page is the deploy of 2026-11-05: commit
f800801 on a Google Cloud e2-micro VM (Ubuntu 22.04, Python 3.10.12,
1 GB of memory, no swap). "The second rollout" is the deploy of
2026-11-28 on the same VM: commit 136d8f7e, `main` with #114 merged,
which replaced f800801. The numbers quoted from either are what that
one run showed, not promises.

## HTTPS is the deploy path

The app sends nothing to a plain `http://` server address — no photo,
no meal text, no upload key (owner decision, 2026-11-13; see
[SERVER_TLS.md](SERVER_TLS.md)). So every server the app talks to runs
Caddy in front of Flask with a certificate:

- **A new server:** deploy as below, then
  [SERVER_TLS.md](SERVER_TLS.md) sections 1–4 before any phone is set
  up, and give the phone `https://$HOST` (section 5), or a setup link
  whose `server=` is `https://$HOST`. A setup link with `http://` is
  refused by the app.
- **A server live on `http://` today:** do SERVER_TLS.md sections 1–4
  before the phones update, then switch each phone to `https://$HOST`
  ("Coming from an `http://` address" there). An updated phone that
  still has the `http://` address shows **Needs https://** in Settings
  and sends nothing until it is changed.

The smoke tests on this page call Flask as `http://127.0.0.1:5000` on
the VM itself: that is the VM talking to itself, never the address a
phone uses.

## What is on the VM, and what is waiting (as of 2026-11-28)

On the VM since the second rollout (2026-11-28): 136d8f7e, `main` with
#114 merged. `DEPLOYED_SHA` on the VM names it. It replaced f800801,
which had run since the first rollout, and keeps everything that one
brought: the meal-context fields in photo replies, the two lookup
endpoints, and `features` in `/api/auth_check`.

The lookups are on. The VM's `.env` sets `TELEGRAM_POLLING=0`,
`CLAUDE_LOOKUP_ENABLED=1`, `CLAUDE_LOOKUP_MODEL=sonnet` and
`CLAUDE_LOOKUP_TIMEOUT_SECONDS=180`, and none of
`CLAUDE_ANALYZER_TIMEOUT_SECONDS`, `CLAUDE_ANALYZER_DISPATCH` or
`CLAUDE_API_BUSY_WAIT_SECONDS`. So smoke C shows
`'restaurant_lookup': True` and smoke E answers `400` there. New for
the phone:

| Commit | What changes for the phone |
|---|---|
| #114 | A photo, leftover photo or text request that arrives while another analysis runs waits up to 20 s for the CLI and is analyzed when it comes free, instead of getting `503` at once. See [Two app requests at once](#two-app-requests-at-once-the-busy-wait). The busy `503` keeps its body and also carries `Retry-After: 5`. |
| f8d0960 | A text request during a closed usage window gets the plan's own sentence, which says when it opens again, and `retry: "later"`. It used to get "the analysis ran but produced no usable result" and `retry: false`, which hid the reset time. A model that needs credits gets the CLI's words and `retry: false`. |
| 752cc03, e60a08e, 4bb40fd | Connect Claude works to the end: the sign-in link arrives whole (it was cut after 80 characters), the pasted code is submitted, and the newest tap wins. An older start that is still running answers `502 start_failed`. |
| 7011916 | A lookup whose CLI is slow to start ends as `failed` with `timeout`, which the app tries again. It used to end as `guard_fail`, and the app stopped looking up that meal. |
| 3060b31, 571bcd7 | A JSON body that is not an object gets a logged `400 bad_request_shape`, never a `500`. `/ping` takes a time zone that is a string or nothing, and `/reconcile` a list of strings: what the Termux watcher sends (the app calls neither). |

New on the server only:

| Commit | What changes |
|---|---|
| #114 | One new knob, `CLAUDE_API_BUSY_WAIT_SECONDS` (unset: 20 s; the VM leaves it unset). The journal has a `Claude CLI busy` line for each request that found another analysis on the CLI. |
| 3758ff7 | The default lookup limit is 180 s instead of 75 s. The `CLAUDE_LOOKUP_TIMEOUT_SECONDS=180` that the first rollout put in `.env` now says the same as the default; it can stay. |
| c66b60b, c571116 | With `TELEGRAM_POLLING=0`, as on the VM, a stop or restart is recorded as a clean shutdown, so deploys no longer count toward the crash-loop alert, and an abandoned Connect Claude session is ended after its 10 minutes. |
| 277d333, 4968afb | When `logs/service_health.json` cannot be written, no lookup starts: the daily cap fails closed. A finished lookup's request and answer leave memory after 24 hours, also when no later lookup comes. |
| de00f3d | `CLAUDE_ANALYZER_DISPATCH=file` applies only to Telegram and `/upload` photos. App requests always run the no-tools stream dispatch. |
| 0c70a46, 0d14e04, b6571cb, 3d9ea2e | The server's copy of the US chain table is the one the current apps carry. No chain key or name changed, so the server accepts the same lookups as before. |

A Connect Claude that completes writes the new token into `.env`, so
the file must stay writable by the service's user (`ubuntu`, mode
`600`). Otherwise the new token works only until the next restart, and
the journal says so.

Waiting: nothing. The VM runs the server code that `main` has. A server
commit merged after #114 waits until the next deploy; one in an open
pull request is not waiting yet.

No new pip packages, no new required env vars, no database migration.
For app builds that are already installed nothing is taken away: the
busy reply keeps its body, and the other changes fix replies that were
wrong (a `500`, a cut sign-in link, a text request that hid the reset
time).

## Before you start

- `pillow_heif` must import in the VM venv (step 2). Without it the server
  still starts, but HEIC uploads from old iOS builds get `bad_image_format`.
- HEIC decoding is memory-hungry on a 1 GB VM (a 48 MP photo can take
  150–300 MB for a moment). Current app builds send small JPEGs, so only
  old iOS builds trigger it.
- Memory is the tight resource on a 1 GB VM without swap. In the first
  rollout the VM had about 380–540 MB available, and the service
  together with one CLI run peaked at about 555 MB. So never start a
  second CLI run next to the service's; the one exception is the
  one-second init check in step 2 of the lookup order below.
- Importing `telegram_bot` opens `~/CalorieTracker/meals.db`. Every
  preflight/smoke import below sets `HOME` to a throwaway folder so the live
  database is never touched by the new code before the restart.

## On the Mac

The blocks below carry `#` comment lines. The Mac's Terminal (zsh) does
not skip them until you tell it to: run `setopt interactivecomments`
once in that Terminal window first, or each comment prints
`command not found: #`.

```bash
cd ~/CalorieTracker && git fetch origin
# one exact commit: the one origin/main points to now
REF=$(git rev-parse origin/main)
SHA=$(git rev-parse --short "$REF")
# that commit must have the lookup routes and the busy wait: this prints routes ok and busy-wait ok, or STOP
git grep -q API_BIND_HOST "$REF" -- telegram_bot.py && echo "routes ok" || echo "STOP: $SHA has no lookup routes"
git grep -q CLAUDE_API_BUSY_WAIT_SECONDS "$REF" -- claude_analyzer.py && echo "busy-wait ok" || echo "STOP: $SHA has no busy wait"
# the gate: the jobs CI ran on exactly this commit
gh run view "$(gh run list --commit "$REF" --workflow Tests --limit 1 \
  --json databaseId --jq '.[0].databaseId')" --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
```

Go on only if that printed `routes ok`, `busy-wait ok` and
`test (3.10): success` (see "Which commit" and "The gate is CI on
Python 3.10" below). Then, in the same terminal:

```bash
# second opinion: the tests of that commit itself, unpacked into a temporary folder
T=$(mktemp -d); git archive "$REF" | tar -x -C "$T"
(cd "$T" && PYTHONDONTWRITEBYTECODE=1 python3.12 -m pytest -q -p no:cacheprovider); rm -rf "$T"
OUT="$TMPDIR/ct_deploy_$SHA.tgz"
git archive --format=tar.gz -o "$OUT" "$REF"
ls -l "$OUT"     # about 36 MB
gcloud compute scp "$OUT" "$VM":/tmp/ct_deploy.tgz --zone "$ZONE" --project "$PROJECT"
echo "$SHA"
gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT"
```

**Which commit.** `REF` is one exact commit, so the test result you read,
the tarball and `DEPLOYED_SHA` all name the same code. It is
`origin/main`: pull request #19, the restaurant-assist work, was merged
into `main` on 2026-11-10 (UTC), and every server change since then has
been merged there too. Do not deploy its old branch,
`origin/feat/glasses-restaurant-assist` (the first rollout deployed
f800801, its head at the time). That branch stopped at 7b06fbc9 on
2026-11-09. It passes `routes ok` and its CI is green, but it has no
busy wait and none of the changes listed above except 3758ff7: the
`busy-wait ok` line is the check that stops it. `routes ok` looks for
`API_BIND_HOST`, which arrived with the lookup routes, in that commit's
`telegram_bot.py`, and stops a commit from before them; `busy-wait ok`
looks for `CLAUDE_API_BUSY_WAIT_SECONDS`, which arrived with the busy
wait (#114), in its `claude_analyzer.py`.

When a review read one commit and another one is deployed (the head of
a pull request, and then its squash merge on `main`), check that their
server code is the same: the `git diff` line must print nothing. The
second rollout compared b3681a7c, the reviewed head of #114, with
136d8f7e:

```bash
REVIEWED=b3681a7c    # the commit the review read
git diff --stat "$REVIEWED" "$REF" -- '*.py' shared requirements.txt .env.example ':!tests' ':!scripts' ':!app'
```

**The gate is CI on Python 3.10.** The VM runs Python 3.10 and the Mac
runs the tests on 3.12, so the result that counts is the `test (3.10)`
job of the Tests workflow on that commit: the `gh` line must print
`test (3.10): success` (the commit's page on GitHub shows the same
checks). If it prints an error instead, CI has not run on that commit
yet: every push to `main` starts it, so wait and run the line again. A
job that is still running prints nothing after its colon. The same job
runs `scripts/check_public_safety.sh` on that commit, so the safety
check needs no run of its own here.

**The second opinion** is the local `pytest`, and it tests the commit
itself: `git archive` unpacks it into a temporary folder, the tests run
there, and the folder is deleted. Not your working tree: the checkout in
`~/CalorieTracker` may sit on another branch or hold changes that are
not committed, and `git archive` ships the commit, not the working
tree.

**The tarball** is about 36 MB now, up from about 6 MB in the first
rollout: mostly the App Store screenshots in `app/ios` and the README's
images in `docs/readme`. Nothing on the VM runs them, but the upload
takes longer and every copy on the VM is that much bigger: the staged
tree, the live tree and each backup.

## On the VM

Run these steps as one script, not line by line: `set -eu` and the
explicit gates stop it before the live directory is touched. Save the
block as `/tmp/deploy_vm.sh` on the VM and run
`bash /tmp/deploy_vm.sh <SHA from the Mac>` (with `bash`: step 3 needs
it).

```bash
set -eu
SHA="$1"
APP=/home/ubuntu/CalorieTracker; PY=$APP/venv/bin/python; TS=$(date +%Y%m%d%H%M%S)
test -s /tmp/ct_deploy.tgz
# 0. pre-checks: each prints its result, none prints a secret
#    free disk, or stop: the staged tree, the extracted tree and two backups need room
df -h /tmp /home/ubuntu | awk 'NR>1 {print $6, $4, "free"}'
FREE_KB=$(df -Pk /home/ubuntu | awk 'NR==2 {print $4}')
[ "$FREE_KB" -gt 512000 ] || { echo "STOP: under 500 MB free on /home"; exit 6; }
#    owners: every path the tarball writes must belong to ubuntu, who extracts it;
#    other files that do not are listed and left alone
sudo tar -tzf /tmp/ct_deploy.tgz | sed 's#^\./##; s#/$##' | sed "s#^#$APP/#" | sort -u > /tmp/ct_list
sudo find $APP -path $APP/venv -prune -o ! -user ubuntu -print | sort -u > /tmp/ct_notub
NOTUB=$(comm -12 /tmp/ct_list /tmp/ct_notub | head -5)
OTHER=$(comm -13 /tmp/ct_list /tmp/ct_notub | head -5)
rm -f /tmp/ct_list /tmp/ct_notub
[ -z "$OTHER" ] || { echo "not owned by ubuntu, and the tarball does not write them (left alone):"; echo "$OTHER"; }
[ -z "$NOTUB" ] || { echo "STOP: paths the tarball writes are not owned by ubuntu:"; echo "$NOTUB"; exit 6; }
echo "owners ok for every path the tarball writes"
#    the health ledger: the service must be able to write it, or no lookup starts
sudo -u ubuntu sh -c 'L=/home/ubuntu/CalorieTracker/logs; test -w $L && test -w $L/service_health.json && { test ! -e $L/service_health.json.lock || test -w $L/service_health.json.lock; }' \
  && echo "ledger writable" || { echo "STOP: ledger not writable"; exit 6; }
#    the knobs this deploy reads, as .env sets them: those lines only (the file holds the keys)
sudo grep -E '^(CLAUDE_ANALYZER_TIMEOUT_SECONDS|CLAUDE_ANALYZER_DISPATCH|CLAUDE_API_BUSY_WAIT_SECONDS|TELEGRAM_POLLING|CLAUDE_LOOKUP_ENABLED|CLAUDE_LOOKUP_MODEL|CLAUDE_LOOKUP_TIMEOUT_SECONDS)=' $APP/.env \
  || echo "none of those knobs set"
#    a time limit in Caddy would cut a slow reply: expect 0
echo "Caddy timeout directives: $(sudo grep -ciE 'timeout' /etc/caddy/Caddyfile || true)"
#    the commit that runs now, which a code rollback goes back to
echo "DEPLOYED_SHA before: $(sudo cat $APP/DEPLOYED_SHA 2>/dev/null || echo none)"
# 1. stage the new tree outside the live directory
sudo -u ubuntu rm -rf /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu mkdir -p /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C /tmp/ct_new
# 2. dependency gate: must print versions, not an ImportError, and
#    requirements.txt must be the one already installed
sudo -u ubuntu $PY -c 'import sys,PIL,pillow_heif; print(sys.version.split()[0], "Pillow", PIL.__version__, "pillow_heif", pillow_heif.__version__)'
sudo diff -q /tmp/ct_new/requirements.txt $APP/requirements.txt \
  || { echo "requirements.txt changed: stop and review"; exit 3; }
# 3. import gate for the NEW code, throwaway HOME: telegram_bot, and daily_report,
#    which the 23:30 report runs and telegram_bot imports only for /report.
#    The output is captured and searched for the "import ok" line: piping this
#    command into tail would hide a failed import behind tail's own exit status.
GATE=$( (cd /tmp/ct_new && sudo -u ubuntu env HOME=/tmp/ct_preflight_home $PY -c 'import telegram_bot, daily_report; print("import ok")') 2>&1 ) \
  || { echo "IMPORT GATE FAILED"; printf '%s\n' "$GATE" | tail -6; exit 4; }
printf '%s\n' "$GATE" | grep -q '^import ok$' || { echo "IMPORT GATE: no ok line"; exit 4; }
#    root .py files that only the live tree has: tar never deletes them. They are
#    listed and left alone, unless one has the name of a standard module
LEFT=$(comm -23 <(sudo -u ubuntu bash -c "cd $APP && ls *.py" | sort) <(sudo -u ubuntu bash -c "cd /tmp/ct_new && ls *.py" | sort))
echo "root .py files only in the live tree: ${LEFT:-none}"
for F in $LEFT; do
  if sudo -u ubuntu $PY -c 'import sys; sys.exit(sys.argv[1] not in sys.stdlib_module_names)' "${F%.py}"; then
    echo "STOP: $F has the name of a standard module, which the service would import in its place"; exit 4
  fi
done
# 4. backups: code-only (for rollback) and full (disaster only; contains .env)
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_code_predeploy_$TS.tgz -C $APP \
  --exclude=./venv --exclude=./logs --exclude=./reports --exclude='./meals.db*' \
  --exclude=./.env --exclude=./dietary_profile.txt --exclude='*/__pycache__' .
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_backup_predeploy_$TS.tgz -C /home/ubuntu \
  --exclude=CalorieTracker/venv --exclude=CalorieTracker/logs CalorieTracker
sudo chmod 600 /home/ubuntu/calorietracker_*predeploy_$TS.tgz
# 5. quiet check: no /api/ request and no analysis line in the last 90 s, or stop
RECENT=$(sudo journalctl -u caloriebot --since '-90s' --no-pager | grep -c -E 'POST /api/|analy' || true)
[ "$RECENT" = "0" ] || { echo "NOT QUIET ($RECENT lines in the last 90 s): try again in a few minutes"; exit 5; }
#    and the service's main process has no child process: every CLI run is one
MPID=$(systemctl show caloriebot -p MainPID --value)
[ -z "$(pgrep -P "$MPID" || true)" ] || { echo "NOT QUIET: a CLI run is in progress: try again in a few minutes"; exit 5; }
#    then extract, record the SHA, restart
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C $APP
echo "$SHA" | sudo -u ubuntu tee $APP/DEPLOYED_SHA >/dev/null
sudo systemctl restart caloriebot
sleep 6
sudo systemctl is-active caloriebot
sudo systemctl show caloriebot -p NRestarts -p ActiveEnterTimestamp -p Type -p WatchdogUSec
```

Then run the smoke test below and clean up:
`sudo rm -rf /tmp/ct_new /tmp/ct_preflight_home /tmp/ct_deploy.tgz /tmp/deploy_vm.sh`.

Do not run `pip install -r requirements.txt` unless step 2 fails: nothing
in requirements changed, and an unpinned install could upgrade Pillow.

About the pre-checks (step 0): the disk, owner and ledger checks stop
the script; the other lines are only printed, to read once it has run.

- **Disk.** A `tar` that runs out of room in the live directory leaves
  it part old, part new. `set -e` stops the script before the restart,
  but the next crash or reboot starts that mix (`Restart=always`). The
  staged tree, the extracted tree and each backup take tens of MB now
  that the tarball is about 36 MB, and the backups of earlier deploys
  stay in `/home/ubuntu`.
- **Owners.** The extraction runs as `ubuntu`, so a path it writes that
  belongs to someone else (root, after an edit with `sudo`) stops it
  halfway, as above. Only those paths stop the deploy. The first version
  of this check looked at every file in the folder, and it stopped the
  second rollout for nothing: two old root-owned `telegram_bot.py.bak-…`
  copies that no deploy writes. Such files are now listed and left
  alone.
- **Ledger.** A lookup starts only when its run can be counted in
  `logs/service_health.json` (since 277d333). When `ubuntu` cannot write
  that file or its `.lock`, every lookup is refused as if the day's cap
  were reached.
- **Knobs.** Only the lines of these knobs are printed, never the file.
  Look for a `CLAUDE_ANALYZER_TIMEOUT_SECONDS` above 280 (an analysis
  that first waited 20 s could then outlast the app's 5 minutes), a
  `CLAUDE_ANALYZER_DISPATCH` line (`file` is a rollback knob only, and
  it now reaches Telegram and `/upload` photos alone), and anything
  after the number of `CLAUDE_API_BUSY_WAIT_SECONDS` (see
  [Two app requests at once](#two-app-requests-at-once-the-busy-wait)).
  Change such a line in `.env`, then restart while the phone is idle.
  With `CLAUDE_LOOKUP_ENABLED=1`, smoke E answers `400`.
- **Caddy.** A reply can take up to 140 s now (SERVER_TLS.md, "Slow
  replies"), and a `timeout` line in the Caddyfile could cut it off.
  Where Caddy is not set up yet, the line says that the file is missing.
- **`DEPLOYED_SHA` before** names the code that the newest code backup
  holds, which a rollback brings back.

In the second rollout, step 0 printed about 20 GB free, the two
`telegram_bot.py.bak-…` files as left alone, `ledger writable`, the four
knob lines listed under "What is on the VM", no Caddy timeout directive
and f800801 as the `DEPLOYED_SHA` before. Step 2 printed Python
3.10.12, Pillow 11.3.0 and pillow_heif 1.4.0; step 3 listed
`calorie_tracker.py` and `flask_app.py`, old files that nothing
imports. After the restart: `active`, `NRestarts=0`, `Type=notify` and
`WatchdogUSec=2min`.

About the root `.py` files in step 3: the service runs from the live
folder, and Python looks there first for a module, so a leftover named
like a standard module (`functools.py`, say) could be imported in its
place, by the server code and by the libraries alike. The code of the
second rollout imports three standard modules that f800801 did not:
`functools`, `struct` and `termios`. Any other leftover is harmless and
stays.

About the quiet check: a restart cuts off a request that is being
answered. The journal gets its line for a request only when the answer
goes out, and a request that waits for the busy CLI writes nothing
until it runs, so the journal shows only that the phone was idle a
moment ago. The child-process line covers the rest: every CLI run (a
photo, a text or a lookup) is a process that the service starts, so
none means that no analysis is running now. If you just took a photo
yourself, wait for it to finish first.

## Smoke test (on the VM; A–E spend no Claude usage, F spends one run; the key is never printed)

```bash
B=http://127.0.0.1:5000
# A. no tracebacks since the restart
sudo journalctl -u caloriebot --since '-3min' --no-pager | grep -E 'Traceback|ImportError|Error' || echo 'A ok'
# B. auth is enforced: expect "401 401"
curl -s -o /dev/null -w '%{http_code} ' -X POST $B/api/auth_check; curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/ping
# C. new code is live. The key goes in via stdin, never argv or echo. Expect
#    features= {'estimate_confidence': True, 'lookup_jobs': True, 'restaurant_lookup': False}
#    ('restaurant_lookup': True when CLAUDE_LOOKUP_ENABLED is already set on this server, as on this page's VM)
K=$(sudo sed -n 's/^ANDROID_API_KEY=//p' /home/ubuntu/CalorieTracker/.env | head -1 | tr -d "\"'")
printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- -H 'X-Client-Platform: smoke' $B/api/auth_check \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("C ok=",d.get("ok"),"claude_login=",d.get("claude_login"),"features=",d.get("features"))'
# D. the 400 path is logged and rejected before the CLI: expect {"error":"bad_image_format"}, then 400
IMG=$(printf '\x00\x00\x00\x18ftypheic%064d' 0 | base64 -w0)
printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- -H 'Content-Type: application/json' \
  -H 'X-Client-Platform: smoke' --data "{\"image_b64\":\"$IMG\"}" $B/api/analyze_photo
# E. the lookup routes exist. The body is one the server refuses either way, so no lookup runs:
#    lookups off: {"error":"disabled","reason":"disabled"}, then 403
#    lookups on:  {"error":"bad_request","field":"items","reason":"bad_request"}, then 400 (this page's VM)
#    (a 404 means the old code is still running)
printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- -H 'Content-Type: application/json' \
  -H 'X-Client-Platform: smoke' --data '{"items":[]}' $B/api/restaurant_lookup
# F. one whole analysis through the API (ONE plan run; the endpoint stores nothing): expect http 200
#    (curl gives it 200 s: the longest wait for a busy CLI, 60 s, then one analysis at its limit, 120 s, and 20 s to spare)
sudo cat /home/ubuntu/CalorieTracker/app/test_live/fixtures/plate.jpg \
  | python3 -c 'import base64,json,sys; json.dump({"image_b64": base64.b64encode(sys.stdin.buffer.read()).decode()}, open("/tmp/photo_body.json","w"))'
printf 'X-API-Key: %s\n' "$K" | curl -s -m 200 -o /tmp/photo_reply.json -w 'F http %{http_code} in %{time_total}s\n' -X POST -H @- \
  -H 'Content-Type: application/json' -H 'X-Client-Platform: smoke' --data-binary @/tmp/photo_body.json $B/api/analyze_photo
python3 -c 'import json; d=json.load(open("/tmp/photo_reply.json")); a=d.get("analysis") or {}; i=(a.get("food_items") or [{}])[0]; print("F analyzed_by=",d.get("analyzed_by"),"is_food=",a.get("is_food"),"estimate_confidence=",a.get("estimate_confidence"),"restaurant_context=",a.get("restaurant_context"),"portion_state=",a.get("portion_state"),"item keys=",sorted(i))'
rm -f /tmp/photo_body.json /tmp/photo_reply.json
unset K IMG
```

F is part of every deploy, not an extra: a whole analysis is the only
proof that the photo path still works. In the first rollout the photo
prompt had grown; in the second, the busy wait changed how an app
request gets the CLI. F sends a test picture that ships with the code
(a drawing of a plate). Expect `F http 200`, the three context fields
filled in, and `brand`, `qty` and `unit` among the item keys; the answer
came after 12 seconds in the first rollout and 12.2 s in the second.
The model may also decide that a drawing is not food, which the prompt
allows: then F prints `F http 200` with `is_food= False`, the three
fields `None` and `item keys= []`. That is a pass too, for the
endpoint, the CLI and the JSON contract. Do not roll back for it and do
not repeat F (each try is one plan run): the meal-context fields are
then proven by the phone photo.

Then take one food photo with the phone. That is not optional for this
deploy either: it is the only end-to-end proof for the app build that is
installed.

**Day one.** Look once more the next day, after the daily report has
run: the cron starts it at 23:30 by the VM's clock, which need not be
yours (this page's VM keeps China time). Nothing here prints a journal
line whole:

```bash
APP=/home/ubuntu/CalorieTracker
sudo systemctl show caloriebot -p NRestarts      # still NRestarts=0
sudo journalctl -u caloriebot --since '-24h' --no-pager | grep -c -E 'Traceback|Unhandled error' || true    # 0
# the busy lines, and the warnings this deploy can add, counted
sudo journalctl -u caloriebot --since '-24h' --no-pager \
  | grep -oE 'app [a-z]+ request (waited|refused)|falling back to Gemini for this photo|is not a whole number|daily-cap ledger could not be updated|init_timeout' \
  | sort | uniq -c
# the daily report's last run: the day it covered, ok= True, and when it ran
sudo -u ubuntu $APP/venv/bin/python -c 'import json; d=json.load(open("/home/ubuntu/CalorieTracker/logs/service_health.json")).get("daily_report", {}); print("report", d.get("last_target_date"), "ok=", d.get("last_ok"), "at", d.get("last_attempt_at"))'
```

`waited` counts the app requests that the busy wait saved from a `503`,
`refused` those that still got one, and `falling back to Gemini` the
Telegram or `/upload` photos that found the CLI busy. `init_timeout`
counts the lookups whose CLI was slow to start, which the app now tries
again. `is not a whole number` (a `CLAUDE_API_BUSY_WAIT_SECONDS` that is
not a number) and `daily-cap ledger could not be updated` (a ledger the
service cannot write) must not appear at all.

## Two app requests at once (the busy wait)

The server runs one CLI analysis at a time. A request from the app (a
photo, a leftover photo or a text request) that arrives while another
analysis is running used to be answered `503` at once. Server code of
2026-11-28 or later makes it wait for the CLI first:

- It waits up to `CLAUDE_API_BUSY_WAIT_SECONDS`; the default wait is
  20 s. When the CLI comes free in that time, the request is analyzed
  and answered as usual.
- At most 2 requests wait at a time. One more is answered at once.
- A request that is still waiting at the limit, or that finds both
  places taken, gets the same `503 {"retry": true}` as before, now with
  a `Retry-After: 5` header as well. The app builds that are installed
  read the body, which has not changed, and ask again a few seconds
  later, as they always did (for a photo: after 5 s and after 10 s).
- A photo that comes through Telegram or `/upload` never waits for
  another analysis: it goes to Gemini at once, as before.
- A restaurant lookup still gives way to all of these, and none starts
  while a request is waiting.

| Knob | Default | Meaning |
|---|---|---|
| `CLAUDE_API_BUSY_WAIT_SECONDS` | `20` | Seconds an app request waits for a busy CLI (0–60). `0` switches the wait off: the `503` comes at once, as before. Write the number alone on its line: systemd keeps a comment after it as part of the value, the value is then not a number, and the wait stays at 20 s (the journal says so once, in a warning). |

Keep it near 20. An iPhone background scan gives up on its request 22 s
after the scan began. A request that has waited longer than that is
analyzed for a phone that no longer listens: that is one run of your
plan for an answer nobody reads, and the next photo waits behind it. A
higher value only makes sense on a server that no iPhone uses. The limit
only bounds that waste: the server cannot see a phone hang up, so a
request whose phone gave up while it waited is still analyzed in full
when its turn comes.

The journal has one line for each request that found another analysis
on the CLI, and it starts with `Claude CLI busy`. It says what happened
to that request: it waited so many seconds and then ran; or it was
refused, after the wait or at once (two were already waiting, or the
wait is off); or, for a Telegram or `/upload` photo, it went to Gemini.
A request that found a restaurant lookup there stops the lookup, and the
journal says `Restaurant lookup pre-empted by a foreground request.` An
app request that then gets the CLI has its "waited" line as well; a
Telegram or `/upload` photo that then gets it has no line of its own.

The wait needs no setting and no app update. It starts when the server
is deployed: until then the server on your VM still answers a busy
request at once.

## Restaurant lookup (WebSearch on your server)

The restaurant-assist work adds two app endpoints,
`POST /api/restaurant_lookup` and `POST /api/restaurant_lookup/status`,
and a `features` object on `/api/auth_check`. The endpoints are **off**
until you switch them on. Apart from the new fields in a photo reply,
deploying the code changes nothing: photos, leftovers and text run as
before (a running lookup always yields the CLI to them).

What switching it on means: for a meal from a chain restaurant, the app
sends item names, quantities, the brand printed on an item or receipt
and up to 3 chain names from Chopstats' own US chain table — never
coordinates, street, city, the photo or your meal history. Your server
then runs the Claude CLI on your plan with **WebSearch only** (no
WebFetch, no MCP, no plugins, `--safe-mode`, a minimal environment
without the upload key or any plan key). The first event of every run
is checked and the run is killed if any tool, MCP server, plugin or
memory path appears that should not. Each lookup takes about 25–135 s of
plan usage (measured in the first live runs; the default limit is
180 s); results are cached for 24 h.

New `.env` knobs (all optional):

| Knob | Default | Meaning |
|---|---|---|
| `CLAUDE_LOOKUP_ENABLED` | off | `1` turns the endpoints on. Off → `403 {"reason":"disabled"}`. |
| `CLAUDE_LOOKUP_MODEL` | `sonnet` | `haiku` uses less plan usage but was wrong on build-your-own items in the first live runs. |
| `CLAUDE_LOOKUP_TIMEOUT_SECONDS` | `180` | Per-lookup wall clock (20–300). |
| `CLAUDE_LOOKUP_INIT_SECONDS` | `10` | How long the CLI may take to print its first (init) event (5–30). Raise it only if the smoke's `init latency` is close to the limit. |
| `CLAUDE_LOOKUP_DAILY_CAP` | `30` | Lookup runs started per day, counted in `logs/service_health.json`. |
| `CLAUDE_LOOKUP_KEY_SOURCE` | `none` | The `apiKeySource` the guard accepts. Change it only if the smoke tells you to. |
| `API_BIND_HOST` | `0.0.0.0` | `127.0.0.1` only when you close plain HTTP ([SERVER_TLS.md](SERVER_TLS.md#6-close-plain-http)). Leave it unset while http and https run side by side. |

The recommended order for a server that is already live:

1. **Deploy** as above, with the lookups off. Smoke A–F must pass; E
   proves that the routes are there and, when it answers `403`, that the
   knob is off.
2. **Smoke the guard without spending usage** (on the VM, while the
   service runs no photo and no lookup). Look first:

   ```bash
   APP=/home/ubuntu/CalorieTracker
   PID=$(systemctl show caloriebot -p MainPID --value)
   pgrep -P "$PID"   # the processes the service has started: must print nothing
   ```

   Every CLI run is a process the service starts, so a number here means
   that one is running now (a photo, a text or a lookup): wait and look
   again. Go on only when it prints nothing:

   ```bash
   # the service's PATH, and only that line: the same file holds the keys
   SPATH=$(sudo cat /proc/$PID/environ | tr '\0' '\n' | sed -n 's/^PATH=//p')
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 \
     $APP/venv/bin/python $APP/scripts/lookup_smoke.py --init-only; echo "exit code: $?"
   ```

   It passes only when the `status` line says `init_ok` **and** the exit
   code is 0. `guard : pass` and `memory_paths : absent` are not enough:
   both are also printed when the CLI exits before its first event
   (`init tools` then shows `-`, `status` says `cli_error (no_init)` and
   the exit code is 1). A pass also shows
   `init tools : StructuredOutput, WebSearch` and the `apiKeySource` the
   CLI reports, never a key. `init latency` is how long the CLI took to
   start (0.9 s in the first rollout; if it is near the 10 s limit, set
   `CLAUDE_LOOKUP_INIT_SECONDS=20`).

   The service's `PATH` matters because the service and the smoke both
   find `claude` through it, unless `.env` sets `CLAUDE_ANALYZER_BIN` to
   a full path, which both then use instead. Under plain `sudo` the
   smoke could test a different `claude` than the one the service runs,
   or find none.

   The guard was written against CLI 2.1.233 and also passes on 2.1.210,
   which the first rollout ran. If it says `FAIL guard_fail:apiKeySource`
   and shows a value you expect for your sign-in, add
   `CLAUDE_LOOKUP_KEY_SOURCE=<that value>` to `.env` and run it again.
   `FAIL guard_fail:init_timeout` (with `init latency : -`) means that
   the CLI printed nothing within `CLAUDE_LOOKUP_INIT_SECONDS`: set that
   knob to `20` (at most `30`) in `.env`, on a line of its own as in
   step 4, and run the smoke again. Treat it as a different CLI only if
   it still fails.
   Any other `FAIL`, or any `status` other than `init_ok`, means this CLI
   version behaves differently: do not enable the feature; report the
   printed lines instead. For `cli_error (no_init)`, this prints which
   `claude` that `PATH` leads to, then the flags the lookup uses and
   whether this CLI's help knows them (the last line is the `dontAsk`
   permission mode, which must say `yes` too):

   ```bash
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 /bin/bash -c 'C=claude; command -v "$C" || echo "$C: NOT FOUND"; H=$("$C" --help 2>&1); for f in --safe-mode --json-schema --no-session-persistence --strict-mcp-config --tools --allowedTools --disallowedTools --permission-mode --output-format --verbose --model dontAsk; do case "$H" in *"$f"*) echo "$f yes";; *) echo "$f NO";; esac; done'
   ```

   If `.env` sets `CLAUDE_ANALYZER_BIN`, write that path in place of
   `claude` in `C=claude`. The line takes nothing from the service's
   `PATH` but the CLI itself, so it also works where that `PATH` holds
   little else (the example unit in [SERVER.md](SERVER.md) has only the
   venv's `bin`).

   A different CLI version changes the photo path too, because it is
   the same program. After any CLI change, check
   `CLAUDE_ANALYZER_EXTRA_FLAGS` against `claude --help` and analyze one
   real photo (smoke F) before you rely on it.

   Why "no photo and no lookup": for about a second the smoke runs a
   second CLI process next to the service's, on a VM that has no memory
   to spare. If the kernel kills a photo's CLI run for memory, the server
   answers that the run produced nothing usable (`retry: false`), and
   the phone gives up on that photo. An idle phone is not enough once
   lookups are on: a lookup the phone asked for runs for up to
   `CLAUDE_LOOKUP_TIMEOUT_SECONDS`, and longer when it waited behind a
   photo. The `pgrep` line is new on this page: the first rollout did
   not run it.
3. **HTTPS next to http** ([SERVER_TLS.md](SERVER_TLS.md), "Before you
   start" and sections 1–4), if the server does not have it yet. The
   current app sends nothing to an `http://` address, lookups included,
   so this step is required, and what it is for arrives once the app's
   own address is `https://` (step 7). An older app build at an
   `http://` address keeps lookups to printed brands only, and its
   upload key, which also unlocks a web-searching model, travels in
   clear text. Closing plain http (section 6 there) is a separate,
   later step and not part of switching lookups on.
4. **Switch it on.** Add the knob to `.env` and restart. Two things to
   get right: the file must end with a newline before you append to it
   (otherwise the new line is glued onto the last one), and its owner
   and mode must stay as they are.

   ```bash
   ENVF=/home/ubuntu/CalorieTracker/.env
   sudo stat -c '%U %a' $ENVF      # note owner and mode, for example: ubuntu 600
   if [ -n "$(sudo tail -c1 $ENVF)" ]; then echo | sudo tee -a $ENVF >/dev/null; fi
   if sudo grep -q '^CLAUDE_LOOKUP_ENABLED=' $ENVF; then
     echo 'already there: edit that line instead of adding a second one'
   else
     echo 'CLAUDE_LOOKUP_ENABLED=1' | sudo tee -a $ENVF >/dev/null
   fi
   sudo stat -c '%U %a' $ENVF      # unchanged
   ```

   Then `sudo systemctl restart caloriebot`, while the phone is idle
   (the quiet check of the deploy script).
5. **Check without spending usage**:

   ```bash
   B=http://127.0.0.1:5000
   K=$(sudo sed -n 's/^ANDROID_API_KEY=//p' /home/ubuntu/CalorieTracker/.env | head -1 | tr -d "\"'")
   # features: expect 'restaurant_lookup': True
   printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- $B/api/auth_check \
     | python3 -c 'import json,sys; print("features:", json.load(sys.stdin).get("features"))'
   # the same through Caddy, with the certificate checked (skip without https).
   # HOST is what follows https:// in the app: your address or name
   HOST=203.0.113.5
   printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- --connect-to "$HOST:443:127.0.0.1:443" "https://$HOST/api/auth_check" \
     | python3 -c 'import json,sys; print("features over https:", json.load(sys.stdin).get("features"))'
   # a location key is refused before any CLI run: expect
   # {"error":"bad_request","field":"lat","reason":"bad_request"}, then 400
   printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- \
     -H 'Content-Type: application/json' -H 'X-Client-Platform: smoke' \
     --data '{"items":[{"name":"bowl","brand":"Chipotle"}],"lat":1}' $B/api/restaurant_lookup
   unset K
   ```

   The journal shows one `restaurant_lookup refused (400 bad_request)`
   line and nothing about the payload.

   If `restaurant_lookup` is still `False`, the server did not read the
   knob as on or cannot run the Claude backend: `CLAUDE_LOOKUP_ENABLED`
   must be on a line of its own with the value `1`,
   `CLAUDE_ANALYZER_ENABLED` must be on as well, the service must find
   the CLI (`claude` on its `PATH`, or the full path in
   `CLAUDE_ANALYZER_BIN`), and the service must have been restarted
   since the edit.
6. **One real lookup, inside the service** (spends one search run on
   your plan and counts as one of the day's `CLAUDE_LOOKUP_DAILY_CAP`
   runs). It goes through the API, so it runs under the service's own
   CLI lock and a photo that arrives pre-empts it:

   ```bash
   sudo -u ubuntu -H /home/ubuntu/CalorieTracker/venv/bin/python - <<'PY'
   import json, time, urllib.error, urllib.request
   from urllib.parse import urlsplit

   ENV = '/home/ubuntu/CalorieTracker/.env'
   KEY = next(l.split('=', 1)[1].strip().strip('"\'') for l in open(ENV) if l.startswith('ANDROID_API_KEY='))

   def load(raw):
       try:
           return json.loads(raw or '{}')
       except ValueError:
           return {}

   def post(path, body):
       req = urllib.request.Request(
           'http://127.0.0.1:5000' + path, data=json.dumps(body).encode(), method='POST',
           headers={'Content-Type': 'application/json', 'X-API-Key': KEY, 'X-Client-Platform': 'smoke'})
       try:
           with urllib.request.urlopen(req, timeout=40) as r:
               return r.status, load(r.read().decode())
       except urllib.error.HTTPError as e:
           return e.code, load(e.read().decode())

   sample = {"items": [{"name": "chicken burrito bowl", "qty": 1, "unit": "bowl", "brand": "Chipotle"}],
             "order_merchant": "", "chains": [{"key": "chipotle", "size": "20_plus"}],
             "country": "US", "backend": "claude"}
   start = time.time()
   code, body = post('/api/restaurant_lookup', sample)
   print('submit: http', code, 'state', body.get('state'), body.get('error') or '')
   job = body.get('job_id')
   while job and body.get('state') in ('queued', 'running'):
       time.sleep(4)
       code, body = post('/api/restaurant_lookup/status', {"job_id": job})
   lookup = body.get('lookup') or {}
   urls = body.get('cited_urls') or []
   hosts = {urlsplit(u).hostname or '' for u in urls}
   print('final :', body.get('state'), body.get('reason') or '', 'after', round(time.time() - start, 1), 's')
   print('lookup:', lookup.get('status'), '| chain', lookup.get('chain_key'), '| matches', len(lookup.get('matches') or []))
   print('search:', body.get('searches'), 'searches |', len(urls), 'cited urls | chipotle.com cited:',
         any(h == 'chipotle.com' or h.endswith('.chipotle.com') for h in hosts),
         '| analyzed_by', body.get('analyzed_by'))
   PY
   ```

   Expect `submit: http 202 state queued`, then `final : done`,
   `lookup: found | chain chipotle`, at least 1 search,
   `chipotle.com cited: True` and `analyzed_by claude`. The journal has
   one line for the run,
   `Restaurant lookup ok (ok) in <s>s; searches=<n> lines=<n>`, and never
   restaurant names, dishes, queries or URLs. In the first live runs
   this sample came back `found` both times on `sonnet` (after 43.7 s
   and 91.6 s, with 3 and 7 searches). A `final : failed timeout` means
   the lookup ran into `CLAUDE_LOOKUP_TIMEOUT_SECONDS`. Asking again
   within 24 hours gives `submit: http 200 state done` straight from the
   cache, with no new run.

   On a 1 GB VM without swap, do **not** use `lookup_smoke.py` without
   `--init-only` for this. It runs a whole lookup in a second CLI
   process outside the service's lock, and two CLI processes at once do
   not fit in that memory.
7. **Switch the app to https**
   ([SERVER_TLS.md, section 5](SERVER_TLS.md#5-switch-the-app-to-https)):
   the server address in the app becomes `https://…`. Until you do, the
   current app sends your server nothing — no photo, no lookup, no
   upload key — and Settings shows **Needs https://**. An older app
   build sends only the chains a printed brand or the receipt names,
   never the ones found by a photo's location, and its upload key
   travels in clear text with every photo. The first rollout stopped
   before this step.
8. **Record a real stream** (optional; only on a machine with memory
   for a second CLI process, and it spends one more search run). With
   `APP` and `SPATH` set as in step 2:

   ```bash
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 \
     $APP/venv/bin/python $APP/scripts/lookup_smoke.py --record /tmp/lookup_stream.jsonl
   ```

   Expect `status : ok`, a `lookup : found, chain=chipotle …` line and
   `chipotle.com cited: yes`. The `--record` file is the stream with ids,
   paths and every secret-looking value redacted (mode 0600); copy it
   back to the Mac as `tests/fixtures/lookup_streams/vm_<version>.jsonl`
   if you want the tests to pin the real WebSearch shape, then delete it
   from `/tmp`.

To switch it off again, remove `CLAUDE_LOOKUP_ENABLED` (or set `0`) and
restart. The restart drops the queued jobs and the 24 h cache with them:
both live in memory.

## Rollback

```bash
APP=/home/ubuntu/CalorieTracker
B=$(ls -t /home/ubuntu/calorietracker_code_predeploy_*.tgz | head -1); echo "$B"
sudo systemctl stop caloriebot
sudo -u ubuntu tar -xzf "$B" -C $APP     # code only: meals.db, .env, venv, logs untouched
sudo -u ubuntu rm -f $APP/DEPLOYED_SHA
sudo systemctl start caloriebot
sudo systemctl is-active caloriebot
```

The deploy changes no data, so rollback has nothing else to undo. The
full archive restores everything but also rolls `meals.db` back to before
the deploy — last resort only.

What a rollback leaves behind: the files the deploy added stay on disk,
and so do the new `.env` knobs. The old code ignores both. Since the
second rollout, the newest code backup on this page's VM holds
f800801. That code has the lookup routes and `API_BIND_HOST`, so the
rollback takes away the busy wait (a busy CLI is answered `503` at once
again) and the other changes listed under "What is on the VM". A
rollback to code from before the lookup routes takes two more things
with it. The lookup routes are gone, so they answer `404` and an app
with the restaurant assist says that the server needs an update. And
`API_BIND_HOST` is ignored, so a server that listened on localhost only
listens on every interface again: repeat the check in
[SERVER_TLS.md](SERVER_TLS.md#6-close-plain-http) after such a rollback.
