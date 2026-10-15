#!/bin/sh
# Stands in for the engine so you can try the app without root or a real agent.
# It appends lines like the ones app/ENGINE.md describes, a few a second, for one claude session.
#
#   app/tools/fake-engine.sh /tmp/bodycam-try/events.jsonl &
#   open app/.build/bodycam.app --args --events /tmp/bodycam-try/events.jsonl
#
# Stop recording in the app deletes .recording next to the file, and this ends the way the engine does.
set -eu
out="$1"
dir=$(dirname "$out")
run="$dir/.recording"
mkdir -p "$dir"
touch "$run"

now() { date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/'; }
emit() { printf '%s\n' "$1" >> "$out"; }
sid="$(date +%s)-$$"
started=$(date +%s)
end_session() {
  emit "{\"type\":\"end\",\"time\":\"$(now)\",\"session\":\"$sid\",\"agent\":\"claude\",\"pid\":$$,\"project\":\"~/code/invoice-api\",\"seconds\":$(( $(date +%s) - started )),\"findings\":[{\"label\":\"read an .env file\",\"what\":\".env\",\"who\":[\"node\"],\"count\":2},{\"label\":\"read your AWS credentials\",\"what\":\"~/.aws/credentials\",\"who\":[\"python3\"],\"count\":1}],\"commands\":9,\"changed\":2,\"changed_outside\":1,\"deleted\":0,\"reads\":64,\"reads_outside\":3,\"connections\":2,\"dropped\":0,\"report\":\"\"}"
}
stopped() { emit "{\"type\":\"status\",\"time\":\"$(now)\",\"state\":\"stopped\"}"; exit 0; }

emit "{\"type\":\"status\",\"time\":\"$(now)\",\"state\":\"recording\",\"version\":\"0.2.0\",\"pid\":$$}"
sleep 3
emit "{\"type\":\"start\",\"time\":\"$(now)\",\"session\":\"$sid\",\"agent\":\"claude\",\"pid\":$$,\"project\":\"~/code/invoice-api\",\"late\":false}"
while IFS='|' read -r who verb what note flag; do
  sleep 1.5
  if [ ! -e "$run" ]; then end_session; stopped; fi
  emit "{\"type\":\"event\",\"time\":\"$(now)\",\"session\":\"$sid\",\"who\":\"$who\",\"verb\":\"$verb\",\"what\":\"$what\",\"note\":\"$note\",\"flag\":$flag}"
done <<'LINES'
security|run|security find-generic-password -a you -w -s 'Claude Code-credentials'||false
git|run|git status --short||false
claude|net|160.79.104.10:443||false
rg|run|rg --files --hidden||false
npm|run|npm test||false
node|read|.env|an .env file|true
claude|edit|src/config.js||false
npm|run|npm test||false
node|read|.env|an .env file|true
python3|run|python3 scripts/deploy_check.py||false
python3|read|~/.aws/credentials|your AWS credentials|true
claude|edit|src/tax.js||false
npm|new|~/.npm/_cacache/index-v5/2b/91|outside the project|false
npm|run|npm test||false
LINES
sleep 2
end_session
while [ -e "$run" ]; do sleep 0.5; done
stopped
