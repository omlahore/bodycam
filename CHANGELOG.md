# Changelog

## 0.1.1

- Values in command lines that look like keys or tokens, such as `API_KEY=...`, `Bearer ...` or `--password=...`, are masked in the live feed and the reports.
- `bodycam --version` shows the right version when installed with `go install`.

## 0.1.0

- First release. `sudo bodycam` records every AI coding agent you start: the commands it runs, the files it reads and changes, the background items it registers and the addresses it connects to. When the agent exits you get a summary in the terminal and a full report in `~/Library/Logs/bodycam`.
- Flags reads of secrets such as SSH keys, cloud credentials, token files, `.env` files, the keychain and browser data, changes to shell startup files, launch agents, SSH and git config, and risky commands like `sudo` or piping a download into a shell.
- Tools reading their own credentials, like `gh` reading its token, are listed but not flagged.
- `--save` writes the agent's events to a file that `--replay` turns back into the same report.
