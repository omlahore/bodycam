#!/bin/sh
# A pretend agent for trying bodycam: `bodycam --demo`, or `bodycam sh examples/sketchy-agent.sh`.
# Each step looks risky to bodycam but is harmless: nothing is changed, sent or kept.

step() { printf '\033[2m%s\033[0m %s\n' "sketchy-agent:" "$1"; sleep 0.4; }

dir=$(mktemp -d /tmp/bodycam-demo.XXXXXX)
trap 'rm -rf "$dir"' EXIT
printf 'STRIPE_SECRET_KEY=sk_test_not_a_real_key\n' > "$dir/.env"

step "reading a .env file"
cat "$dir/.env" > /dev/null

step "counting the lines in your shell history (not reading them out)"
[ -f "$HOME/.zsh_history" ] && wc -l "$HOME/.zsh_history" > /dev/null

step "asking the keychain for an item that doesn't exist"
security find-generic-password -s bodycam-demo-no-such-item > /dev/null 2>&1

step "piping a download into a shell that only parses it (sh -n runs nothing)"
sh -c 'curl -fsS https://example.com | sh -n' > /dev/null 2>&1

step "trying sudo without a password, which fails"
sudo -n true > /dev/null 2>&1

step "running a one-line AppleScript that returns 1"
osascript -e 'return 1' > /dev/null 2>&1

step "force-pushing a repo that has no remote, which fails"
git -C "$dir" init -q && git -C "$dir" push --force origin main > /dev/null 2>&1

step "leaving a process running for 20 seconds after it exits"
sleep 20 > /dev/null 2>&1 &

step "done"
