package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	dim     = "\033[2m"
	red     = "\033[31m"
	green   = "\033[32m"
	yellow  = "\033[33m"
	blue    = "\033[34m"
	cyan    = "\033[36m"
	bold    = "\033[1m"
	redBold = "\033[1;31m"
	reset   = "\033[0m"
)

func useColor(w io.Writer) bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	if os.Getenv("CLICOLOR_FORCE") != "" {
		return true
	}
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

func termWidth(w io.Writer) int {
	if c, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && c > 0 {
		return c
	}
	f, ok := w.(*os.File)
	if !ok {
		return 0
	}
	var ws struct{ rows, cols, x, y uint16 }
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws))); errno != 0 {
		return 0
	}
	return int(ws.cols)
}

func (r *recorder) paint(color, s string) string {
	return paint(r.color, color, s)
}

func paint(on bool, color, s string) string {
	if !on || s == "" {
		return s
	}
	return color + s + reset
}

var verbColor = map[string]string{
	"start": bold, "run": blue, "edit": green, "new": green, "delete": yellow,
	"read": red, "flag": red, "net": cyan,
}

func (r *recorder) print(fl *feedLine) {
	r.writeFeed(fl)
	if r.quiet {
		return
	}
	c := r.feedColor
	tag := ""
	if len(r.sessions) > 1 {
		tag = paint(c, dim, fmt.Sprintf("#%d ", fl.s.n))
	}
	what, note := fl.what, fl.note
	if r.width > 0 {
		room := r.width - 27
		if note != "" {
			note = oneLine(note, max(room/2-4, 12))
			room -= len([]rune(note)) + 4
		}
		what = oneLine(what, max(room, 12))
	}
	line := fmt.Sprintf("%s  %s%s %s  %s",
		paint(c, dim, fl.t.Local().Format("15:04:05")),
		tag,
		paint(c, cyan, fmt.Sprintf("%-8s", oneLine(fl.who, 8))),
		paint(c, verbColor[fl.verb], fmt.Sprintf("%-6s", fl.verb)),
		what)
	if note != "" {
		color := red
		if fl.note == "outside the project" {
			color = yellow
		}
		line += "  " + paint(c, color, "! "+note)
	}
	fmt.Fprintln(r.feed, line)
}

func (f *finding) String() string { return f.format(f.what) }

func (f *finding) markdown() string {
	return f.format("`" + strings.ReplaceAll(f.what, "`", "'") + "`")
}

func (f *finding) format(what string) string {
	s := f.label + ": " + what
	extra := []string{}
	if f.count > 1 {
		if strings.HasSuffix(f.label, "outside the project") {
			extra = append(extra, commas(f.count)+" files")
		} else {
			extra = append(extra, "×"+strconv.Itoa(f.count))
		}
	}
	if len(f.who) > 0 {
		extra = append(extra, "by "+strings.Join(f.who, ", "))
	}
	if len(extra) > 0 {
		s += " (" + strings.Join(extra, ", ") + ")"
	}
	return s
}

func (r *recorder) printSummary(s *session, report string) {
	w := r.out
	fmt.Fprintln(w)
	name := s.agent
	if r.count > 1 {
		name = fmt.Sprintf("#%d %s", s.n, s.agent)
	}
	fmt.Fprintf(w, "%s (pid %d) ran for %s\n", r.paint(bold, name), s.root, duration(s))
	if len(s.findings) == 0 {
		fmt.Fprintln(w, "  "+r.paint(green, "nothing stood out"))
	} else {
		fmt.Fprintln(w, "  "+r.paint(redBold, plural(len(s.findings), "thing")+" to look at"))
		for i, f := range s.findings {
			if i == 12 {
				fmt.Fprintf(w, "    …and %d more in the report\n", len(s.findings)-i)
				break
			}
			line := f.String()
			if r.width > 0 {
				line = oneLine(line, max(r.width-6, 20))
			}
			fmt.Fprintln(w, "    "+r.paint(red, "! ")+line)
		}
	}
	runs := 0
	for _, c := range s.commands {
		runs += c.count
	}
	if s.wholeHome() {
		fmt.Fprintf(w, "  %s, %s changed, %d deleted\n", plural(runs, "command"), plural(len(s.changed)+len(s.changedOut), "file"), len(s.deleted))
		fmt.Fprintf(w, "  %s read", plural(s.readIn+len(s.readOut), "file"))
	} else {
		fmt.Fprintf(w, "  %s, %s changed in the project, %d outside it, %d deleted\n",
			plural(runs, "command"), plural(len(s.changed), "file"), len(s.changedOut), len(s.deleted))
		fmt.Fprintf(w, "  %s read in the project, %d outside it", plural(s.readIn, "file"), len(s.readOut))
	}
	if len(s.conns) > 0 {
		fmt.Fprintf(w, ", %s", plural(len(s.conns), "network address"))
	}
	fmt.Fprintln(w)
	if report != "" {
		fmt.Fprintln(w, "  report: "+tilde(report, r.owner.home))
	}
	fmt.Fprintln(w)
}

func duration(s *session) string {
	if s.start.IsZero() || s.end.Before(s.start) {
		return "an unknown time"
	}
	return s.end.Sub(s.start).Round(time.Second).String()
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	if strings.HasSuffix(word, "s") {
		return commas(n) + " " + word + "es"
	}
	return commas(n) + " " + word + "s"
}

func commas(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

func (r *recorder) writeReport(s *session) (string, error) {
	name := fmt.Sprintf("%s-%s-%d.md", s.start.Local().Format("2006-01-02-150405"), s.agent, s.root)
	if s.start.IsZero() {
		name = fmt.Sprintf("%s-%d.md", s.agent, s.root)
	}
	if err := os.MkdirAll(r.reportDir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(r.reportDir, name)
	if err := os.WriteFile(path, []byte(r.markdown(s)), 0o644); err != nil {
		return "", err
	}
	if os.Geteuid() == 0 && r.owner.uid != 0 {
		os.Chown(r.reportDir, r.owner.uid, r.owner.gid)
		os.Chown(path, r.owner.uid, r.owner.gid)
	}
	r.reports = append(r.reports, path)
	return path, nil
}

func (r *recorder) markdown(s *session) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# bodycam: %s", s.agent)
	if !s.start.IsZero() {
		fmt.Fprintf(&b, ", %s", s.start.Local().Format("2 Jan 2006 15:04"))
	}
	b.WriteString("\n\n")
	if s.project != "" {
		fmt.Fprintf(&b, "- Project: `%s`\n", tilde(s.project, s.home))
	}
	if s.cwd != "" && s.cwd != s.project {
		fmt.Fprintf(&b, "- Started in: `%s`\n", tilde(s.cwd, s.home))
	}
	if !s.start.IsZero() {
		fmt.Fprintf(&b, "- Ran: %s to %s (%s)\n", s.start.Local().Format("15:04:05"), s.end.Local().Format("15:04:05"), duration(s))
	}
	fmt.Fprintf(&b, "- Process ID: %d, %s in total\n", s.root, plural(s.procs, "process"))
	if s.late {
		b.WriteString("- bodycam started watching after the agent was already running, so anything it did before that is missing.\n")
	}

	b.WriteString("\n## Things to look at\n\n")
	if len(s.findings) == 0 {
		b.WriteString("Nothing stood out.\n")
	}
	for _, f := range s.findings {
		fmt.Fprintf(&b, "- %s\n", f.markdown())
	}

	runs := 0
	for _, c := range s.commands {
		runs += c.count
	}
	fmt.Fprintf(&b, "\n## Commands (%s, %d different)\n\n", plural(runs, "run"), len(s.commands))
	listCommands(&b, s.commands, 300)

	fmt.Fprintf(&b, "\n## Files changed in the project (%d)\n\n", len(s.changed))
	var listed []string
	for _, p := range sortedKeys(s.changed) {
		rel := strings.TrimPrefix(p, s.project+"/")
		if generatedDir(rel) == "" || s.project == s.home {
			listed = append(listed, p)
		}
	}
	listPaths(&b, s, listed, s.newFiles, 500)
	if len(s.generated) > 0 {
		var parts []string
		for _, g := range sortedKeys(s.generated) {
			parts = append(parts, fmt.Sprintf("%s under %s", plural(s.generated[g], "file"), g))
		}
		fmt.Fprintf(&b, "\nNot listed: %s.\n", strings.Join(parts, ", "))
	}

	if len(s.changedOut) > 0 {
		fmt.Fprintf(&b, "\n## Files changed outside the project (%d)\n\n", len(s.changedOut))
		listPaths(&b, s, sortedKeys(s.changedOut), s.newFiles, 300)
	}
	if len(s.deleted) > 0 {
		fmt.Fprintf(&b, "\n## Deleted (%d)\n\n", len(s.deleted))
		listPaths(&b, s, sortedKeys(s.deleted), nil, 300)
	}
	if len(s.moved) > 0 {
		fmt.Fprintf(&b, "\n## Moved (%d)\n\n", len(s.moved))
		for i, m := range s.moved {
			if i == 200 {
				fmt.Fprintf(&b, "- …and %d more\n", len(s.moved)-i)
				break
			}
			fmt.Fprintf(&b, "- `%s`\n", m)
		}
	}
	fmt.Fprintf(&b, "\n## Files read\n\n%s in the project", plural(s.readIn, "file"))
	if len(s.readOut) == 0 {
		b.WriteString(", none outside it worth listing.\n")
	} else {
		fmt.Fprintf(&b, ", plus these %d outside it:\n\n", len(s.readOut))
		listPaths(&b, s, sortedKeys(s.readOut), nil, 300)
	}

	if len(s.creds) > 0 {
		b.WriteString("\n## Credentials read by the tools they belong to\n\n")
		for _, label := range sortedKeys(s.creds) {
			fmt.Fprintf(&b, "- %s, by %s\n", label, strings.Join(s.creds[label], ", "))
		}
	}

	if len(s.conns) > 0 || len(s.hosts) > 0 {
		b.WriteString("\n## Network\n\n")
	}
	if len(s.conns) > 0 {
		b.WriteString("Connections bodycam saw open (it checks every 2 seconds, so short ones can be missing):\n\n")
		for _, remote := range sortedKeys(s.conns) {
			fmt.Fprintf(&b, "- `%s` from %s\n", remote, strings.Join(sortedKeys(s.conns[remote]), ", "))
		}
	}
	if len(s.hosts) > 0 {
		if len(s.conns) > 0 {
			b.WriteString("\n")
		}
		b.WriteString("Hosts named in commands:\n\n")
		for _, h := range sortedKeys(s.hosts) {
			fmt.Fprintf(&b, "- `%s` (%s)\n", h, s.hosts[h])
		}
	}

	var notes []string
	if s.note != "" {
		notes = append(notes, s.note)
	}
	if s.dropped > 0 {
		notes = append(notes, fmt.Sprintf("macOS dropped %s while this agent ran because they came in faster than bodycam read them, so this report can be missing some activity.", plural(s.dropped, "event")))
	}
	if len(notes) > 0 {
		b.WriteString("\n## Notes\n\n")
		for _, n := range notes {
			fmt.Fprintf(&b, "- %s\n", n)
		}
	}
	fmt.Fprintf(&b, "\n---\nMade by [bodycam](https://github.com/omlahore/bodycam) %s.\n", version)
	return b.String()
}

func listCommands(b *strings.Builder, cmds []*command, max int) {
	if len(cmds) == 0 {
		b.WriteString("None.\n")
		return
	}
	for i, c := range cmds {
		if i == max {
			fmt.Fprintf(b, "- …and %d more\n", len(cmds)-i)
			return
		}
		line := "`" + strings.ReplaceAll(oneLine(c.line, 200), "`", "'") + "`"
		if c.count > 1 {
			line += fmt.Sprintf(" ×%d", c.count)
		}
		fmt.Fprintf(b, "- %s\n", line)
	}
}

func listPaths(b *strings.Builder, s *session, paths []string, created map[string]bool, max int) {
	if len(paths) == 0 {
		b.WriteString("None.\n")
		return
	}
	for i, p := range paths {
		if i == max {
			fmt.Fprintf(b, "- …and %d more\n", len(paths)-i)
			return
		}
		line := "`" + s.show(p) + "`"
		if created[p] {
			line += " (new)"
		}
		fmt.Fprintf(b, "- %s\n", line)
	}
}
