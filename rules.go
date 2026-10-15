package main

import (
	"path/filepath"
	"regexp"
	"strings"
)

var defaultAgents = []string{
	"claude", "codex", "gemini", "aider", "cursor-agent", "opencode",
	"amp", "crush", "qwen", "copilot", "droid", "kiro-cli",
}

func inside(p, dir string) bool {
	return dir != "" && (p == dir || strings.HasPrefix(p, dir+"/"))
}

func underAny(p string, dirs []string) bool {
	for _, d := range dirs {
		if inside(p, d) {
			return true
		}
	}
	return false
}

// relHome returns p relative to home, and whether p is inside home at all.
func relHome(p, home string) (string, bool) {
	if !inside(p, home) {
		return "", false
	}
	return strings.TrimPrefix(strings.TrimPrefix(p, home), "/"), true
}

var tempDirs = []string{"/tmp", "/private/tmp", "/var/folders", "/private/var/folders", "/private/var/tmp", "/dev"}

// Folders where agents, package managers and shells keep their own state.
var ownDirs = []string{
	".claude", ".claude.json", ".codex", ".gemini", ".aider", ".cursor", ".copilot", ".factory",
	".qwen", ".kiro", ".config/opencode", ".local/share/opencode", ".config/amp", ".config/crush",
	".local/share/crush", ".local/share/claude", ".local/state", ".cache", ".npm", ".bun", ".deno",
	".nvm", ".pyenv", ".rustup", ".cargo/registry", ".cargo/git", ".gradle", ".m2", ".yarn",
	".pnpm-store", ".node-gyp", ".config/configstore", "go/pkg", "Library/Caches", "Library/Logs",
	"Library/pnpm", "Library/Saved Application State", "Library/Application Support/Claude",
	".zsh_sessions", ".zcompdump", ".lesshst", ".viminfo", ".node_repl_history", ".python_history",
}

func isOwnDir(p, home string) bool {
	rel, ok := relHome(p, home)
	if !ok {
		return false
	}
	for _, d := range ownDirs {
		if rel == d || strings.HasPrefix(rel, d+"/") || strings.HasPrefix(rel, d+".") {
			return true
		}
	}
	return false
}

func ignoredChange(p, home string) bool {
	return underAny(p, tempDirs) || isOwnDir(p, home)
}

var shellStartup = map[string]bool{
	".zshrc": true, ".zprofile": true, ".zshenv": true, ".zlogin": true, ".zlogout": true,
	".bashrc": true, ".bash_profile": true, ".bash_login": true, ".profile": true,
	".config/fish/config.fish": true,
}

var secretPaths = []struct {
	path  string // relative to home, a trailing slash covers everything under it
	label string
}{
	{".aws/credentials", "AWS credentials"},
	{".aws/sso/cache/", "AWS login tokens"},
	{".config/gcloud/", "Google Cloud credentials"},
	{".azure/", "Azure credentials"},
	{".kube/config", "Kubernetes credentials"},
	{".docker/config.json", "Docker credentials"},
	{".netrc", "saved passwords in .netrc"},
	{".git-credentials", "saved git passwords"},
	{".npmrc", "your npm token file"},
	{".pypirc", "your PyPI token file"},
	{".gem/credentials", "your RubyGems token"},
	{".cargo/credentials", "your crates.io token"},
	{".cargo/credentials.toml", "your crates.io token"},
	{".config/gh/hosts.yml", "your GitHub CLI token"},
	{".terraform.d/credentials.tfrc.json", "your Terraform token"},
	{".vault-token", "your Vault token"},
	{".gnupg/", "your GPG keys"},
	{".password-store/", "your pass passwords"},
	{".config/op/", "1Password CLI data"},
	{".zsh_history", "your shell history"},
	{".bash_history", "your shell history"},
	{"Library/Keychains/", "your keychain"},
	{"Library/Cookies/", "browser cookies"},
	{"Library/Safari/", "Safari data"},
	{"Library/Containers/com.apple.Safari/", "Safari data"},
	{"Library/Application Support/Google/Chrome/", "Chrome data"},
	{"Library/Application Support/BraveSoftware/", "Brave data"},
	{"Library/Application Support/Microsoft Edge/", "Edge data"},
	{"Library/Application Support/Arc/", "Arc data"},
	{"Library/Application Support/Firefox/", "Firefox data"},
	{"Library/Messages/", "your Messages"},
	{"Library/Mail/", "your Mail"},
	{"Library/Group Containers/2BUA8C4S2C.com.1password/", "1Password data"},
	{"Library/Application Support/Bitwarden/", "Bitwarden data"},
}

// Programs that normally read a kind of secret. Reads by them are listed, not flagged.
var secretOwners = map[string][]string{
	"your npm token file":       {"node", "npm", "npx", "pnpm", "yarn", "bun", "corepack"},
	"your GitHub CLI token":     {"gh"},
	"AWS credentials":           {"aws", "terraform", "pulumi"},
	"AWS login tokens":          {"aws"},
	"Kubernetes credentials":    {"kubectl", "helm", "k9s", "kind", "minikube", "kubectx", "kubens"},
	"Docker credentials":        {"docker", "docker-credential-desktop", "docker-credential-osxkeychain", "com.docker.backend"},
	"saved git passwords":       {"git", "git-credential-store", "git-remote-https"},
	"saved passwords in .netrc": {"git-remote-https", "curl"},
	"an SSH private key":        {"ssh", "ssh-add", "ssh-keygen", "scp", "sftp", "ssh-agent"},
	"your GPG keys":             {"gpg", "gpg2", "gpg-agent", "keyboxd"},
	"your keychain":             {"security", "securityd", "secd"},
	"your crates.io token":      {"cargo"},
	"your Terraform token":      {"terraform"},
	"your Vault token":          {"vault"},
	"your PyPI token file":      {"twine"},
	"your RubyGems token":       {"gem"},
	"1Password CLI data":        {"op"},
	"Google Cloud credentials":  {"gcloud", "gsutil", "bq"},
	"Azure credentials":         {"az"},
}

// Programs that copy or print raw files. Any other program that opens the keychain file is
// going through Apple's keychain API, which asks before it hands anything over.
var rawFileTools = map[string]bool{
	"cat": true, "cp": true, "mv": true, "ditto": true, "tar": true, "zip": true, "gzip": true,
	"rsync": true, "scp": true, "sftp": true, "curl": true, "nc": true, "base64": true, "xxd": true,
	"od": true, "hexdump": true, "strings": true, "sqlite3": true, "dd": true, "head": true,
	"tail": true, "less": true, "more": true, "bat": true,
}

func ownsSecret(label, program string) bool {
	if label == "your keychain" {
		return !rawFileTools[program]
	}
	for _, o := range secretOwners[label] {
		if o == program {
			return true
		}
	}
	return false
}

var keychainUsers = map[string]bool{
	"gh": true, "git": true, "git-credential-osxkeychain": true, "docker-credential-osxkeychain": true,
	"docker-credential-desktop": true, "op": true, "aws-vault": true,
}

var keychainService = regexp.MustCompile(`\s-s\s+(?:'([^']*)'|"([^"]*)"|(\S+))`)

// ownKeychainItem is true when the agent itself, or a tool like gh, reads its own login from the keychain.
func ownKeychainItem(cmd, spawner string, agents map[string]bool) bool {
	if keychainUsers[spawner] {
		return true
	}
	m := keychainService.FindStringSubmatch(cmd)
	if m == nil {
		return false
	}
	service := strings.ToLower(m[1] + m[2] + m[3])
	for a := range agents {
		if strings.Contains(service, a) {
			return true
		}
	}
	return false
}

var envTemplates = map[string]bool{
	".env.example": true, ".env.sample": true, ".env.template": true, ".env.dist": true, ".env.defaults": true,
}

// secretLabel names the kind of secret stored at p, or returns "" if p doesn't look like one.
func secretLabel(p, home string) string {
	base := filepath.Base(p)
	if base == ".env" || strings.HasPrefix(base, ".env.") && !envTemplates[base] {
		return "an .env file"
	}
	rel, ok := relHome(p, home)
	if !ok {
		return ""
	}
	if strings.HasPrefix(rel, ".ssh/") {
		if base == "config" || base == "authorized_keys" || strings.HasPrefix(base, "known_hosts") ||
			strings.HasSuffix(base, ".pub") || base == "agent" {
			return ""
		}
		return "an SSH private key"
	}
	for _, s := range secretPaths {
		if rel == s.path || strings.HasSuffix(s.path, "/") && strings.HasPrefix(rel, s.path) {
			return s.label
		}
	}
	return ""
}

// changeLabel says why a change to p deserves a look, or returns "" for ordinary files.
func changeLabel(p, home string) string {
	rel, inHome := relHome(p, home)
	switch {
	case inHome && shellStartup[rel]:
		return "changed a shell startup file"
	case inHome && strings.HasPrefix(rel, "Library/LaunchAgents/"),
		strings.HasPrefix(p, "/Library/LaunchAgents/"), strings.HasPrefix(p, "/Library/LaunchDaemons/"):
		return "added something that runs in the background"
	case inHome && rel == ".ssh/authorized_keys":
		return "changed who can log in over SSH"
	case inHome && strings.HasPrefix(rel, ".ssh/"):
		return "changed SSH files"
	case inHome && (rel == ".gitconfig" || strings.HasPrefix(rel, ".config/git/")):
		return "changed your git config"
	case strings.HasPrefix(p, "/etc/"), strings.HasPrefix(p, "/private/etc/"):
		return "changed system settings files"
	case strings.HasPrefix(p, "/private/var/at/tabs/"), strings.HasPrefix(p, "/usr/lib/cron/"):
		return "changed scheduled jobs"
	case strings.HasPrefix(p, "/usr/local/bin/"), strings.HasPrefix(p, "/opt/homebrew/bin/"),
		inHome && (strings.HasPrefix(rel, ".local/bin/") || strings.HasPrefix(rel, "bin/")):
		return "installed a command"
	case strings.HasPrefix(p, "/Applications/"):
		return "changed an app"
	}
	if s := secretLabel(p, home); s != "" {
		return "changed " + s
	}
	return ""
}

var quietReads = map[string]bool{
	".gitconfig": true, ".config/git/config": true, ".config/git/ignore": true, ".config/git/attributes": true,
	".gitignore_global": true, ".inputrc": true, ".CFUserTextEncoding": true, ".hushlogin": true,
	".ssh/config": true, ".ssh/known_hosts": true, ".editorconfig": true,
}

// noisyRead is true for reads nobody needs to see: system files, tool caches, shell startup files.
func noisyRead(p, home string) bool {
	rel, ok := relHome(p, home)
	if !ok {
		return !strings.HasPrefix(p, "/Users/") && !strings.HasPrefix(p, "/Volumes/")
	}
	return rel == "" || quietReads[rel] || shellStartup[rel] || isOwnDir(p, home) ||
		strings.HasPrefix(rel, "Library/Preferences/")
}

// Folders inside a project that hold generated files. Changes there are counted, not listed.
var generatedDirs = map[string]bool{
	"node_modules": true, ".git": true, ".venv": true, "venv": true, "__pycache__": true,
	".next": true, ".nuxt": true, ".turbo": true, ".pytest_cache": true, ".mypy_cache": true,
	".ruff_cache": true, ".gradle": true, ".build": true, "target": true, "dist": true,
	"build": true, "coverage": true, ".svelte-kit": true, "vendor": true,
}

func generatedDir(rel string) string {
	for _, part := range strings.Split(filepath.Dir(rel), "/") {
		if generatedDirs[part] {
			return part
		}
	}
	return ""
}

var commandRules = []struct {
	re    *regexp.Regexp
	label string
}{
	{regexp.MustCompile(`(^|[\s;&|(])sudo\s`), "used sudo"},
	{regexp.MustCompile(`\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b`), "piped a download into a shell"},
	{regexp.MustCompile(`\bsecurity\s+(find-generic-password|find-internet-password|dump-keychain|export)\b`), "read from your keychain"},
	{regexp.MustCompile(`\blaunchctl\s+(load|bootstrap|submit|enable)\b`), "registered a background job"},
	{regexp.MustCompile(`(^|[\s;&|(])crontab\s+(-e|-r|[^-\s])`), "changed scheduled jobs"},
	{regexp.MustCompile(`(^|[\s;&|(/])osascript\b`), "ran AppleScript"},
	{regexp.MustCompile(`\bgit\s+push\b[^;&|]*\s(-f|--force|--force-with-lease)\b`), "ran git push --force"},
	{regexp.MustCompile(`\b(npm|pnpm|yarn)\s+publish\b|\bcargo\s+publish\b|\btwine\s+upload\b|\bgh\s+release\s+create\b|\bdocker\s+push\b`), "published something"},
	{regexp.MustCompile(`\bxattr\b[^;&|]*com\.apple\.quarantine|\bxattr\s+-c\b`), "removed a download quarantine flag"},
	{regexp.MustCompile(`\bspctl\s+--master-disable\b|\bcsrutil\s+disable\b`), "turned off a macOS protection"},
	{regexp.MustCompile(`(^|[\s;&|(/])(nc|ncat|socat)\s`), "opened a raw network connection"},
	{regexp.MustCompile(`\bchmod\s+(-R\s+)?777\b`), "made files writable by everyone"},
	{regexp.MustCompile(`\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(/|~|\$HOME)/?(\s|$)`), "tried to delete your whole disk or home folder"},
}

func commandFlags(cmd string) []string {
	var out []string
	for _, r := range commandRules {
		if r.re.MatchString(cmd) {
			out = append(out, r.label)
		}
	}
	return out
}

var hostPatterns = []*regexp.Regexp{
	regexp.MustCompile(`\b(?:https?|wss?|ftp)://(?:[^@/\s'"]+@)?([A-Za-z0-9.-]+)`),
	regexp.MustCompile(`\bgit@([A-Za-z0-9.-]+):`),
}

func commandHosts(cmd string) []string {
	var out []string
	for _, re := range hostPatterns {
		for _, m := range re.FindAllStringSubmatch(cmd, -1) {
			out = append(out, strings.ToLower(m[1]))
		}
	}
	return out
}

var shells = map[string]bool{"sh": true, "bash": true, "zsh": true, "dash": true, "fish": true, "ksh": true}

// shellScript returns the script of a `sh -c script` style command.
func shellScript(args []string) (string, bool) {
	if len(args) < 2 || !shells[strings.TrimPrefix(filepath.Base(args[0]), "-")] {
		return "", false
	}
	sawC := false
	for i := 1; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-o" || a == "+o" || a == "-O" || a == "+O":
			i++
		case strings.HasPrefix(a, "--"):
		case strings.HasPrefix(a, "-") || strings.HasPrefix(a, "+"):
			if strings.ContainsRune(a[1:], 'c') {
				sawC = true
			}
		default:
			if !sawC {
				return "", false
			}
			return a, true
		}
	}
	return "", false
}

var interpreters = map[string]bool{"node": true, "bun": true, "deno": true, "ruby": true}

func isInterpreter(name string) bool {
	return interpreters[name] || strings.HasPrefix(name, "python")
}

// agentName returns which agent an exec starts, or "".
func agentName(agents map[string]bool, exe string, args []string, script string) string {
	for len(args) > 1 && (filepath.Base(args[0]) == "env" || strings.Contains(args[0], "=") || strings.HasPrefix(args[0], "-")) {
		args = args[1:]
	}
	cands := []string{filepath.Base(exe)}
	if len(args) > 0 {
		cands = append(cands, filepath.Base(args[0]))
	}
	if script != "" {
		cands = append(cands, filepath.Base(script))
	}
	if len(args) > 1 && isInterpreter(filepath.Base(args[0])) {
		cands = append(cands, filepath.Base(args[1]))
	}
	for _, c := range cands {
		if agents[c] {
			return c
		}
	}
	if agents["claude"] && strings.Contains(exe, "/claude/versions/") {
		return "claude"
	}
	return ""
}

var secretValues = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?|AUTH)[A-Z0-9_]*=)(?:'[^']*'|"[^"]*"|\S+)`),
	regexp.MustCompile(`(?i)(\b(?:Bearer|Basic|token)\s+)[A-Za-z0-9._~+/=-]{8,}`),
	regexp.MustCompile(`(?i)((?:^|\s)--?(?:password|token|api-key|apikey|secret)[= ])(?:'[^']*'|"[^"]*"|\S+)`),
	regexp.MustCompile(`()\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,})`),
}

// redact hides values that look like keys or tokens, so a report can be shared.
func redact(cmd string) string {
	for _, re := range secretValues {
		cmd = re.ReplaceAllString(cmd, "${1}•••")
	}
	return cmd
}
