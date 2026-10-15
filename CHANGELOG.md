# Changelog

## 0.2.0

- A menu bar app. It records every agent you start, turns red while one runs, sends a notification for each thing to look at and keeps a window per run with its timeline. Download `bodycam-app.zip` from the release.
- `bodycam claude`, or any other command, records that command in the same terminal. bodycam asks for your password once for Apple's `eslogger` and runs the command as you. The live feed goes to `~/Library/Logs/bodycam/live.log`.
- `bodycam --demo` records a harmless pretend agent so you can see what bodycam flags.
- Catches `git push --force` when options come before `push`, like `git -C dir push --force`.
- Runs of `sh script.sh` or `node app.js` are named after the script, and a program that restarts itself, like `/bin/sh`, shows up once.
- The live feed and the summary fit the terminal width.
- Reports no longer look up hostnames for network addresses, so nothing leaves the Mac.

## 0.1.1

- Values in command lines that look like keys or tokens, such as `API_KEY=...`, `Bearer ...` or `--password=...`, are masked in the live feed and the reports.
- `bodycam --version` shows the right version when installed with `go install`.

## 0.1.0

- First release. `sudo bodycam` records every AI coding agent you start: the commands it runs, the files it reads and changes, the background items it registers and the addresses it connects to. When the agent exits you get a summary in the terminal and a full report in `~/Library/Logs/bodycam`.
- Flags reads of secrets such as SSH keys, cloud credentials, token files, `.env` files, the keychain and browser data, changes to shell startup files, launch agents, SSH and git config, and risky commands like `sudo` or piping a download into a shell.
- Tools reading their own credentials, like `gh` reading its token, are listed but not flagged.
- `--save` writes the agent's events to a file that `--replay` turns back into the same report.
