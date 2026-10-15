package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type proc struct {
	pid  int
	name string
	args string
	s    *session
}

type finding struct {
	label string
	what  string
	who   string
	count int
}

type command struct {
	line  string
	count int
}

type session struct {
	agent   string
	root    int
	cwd     string
	project string
	home    string
	start   time.Time
	end     time.Time
	late    bool
	unnamed bool
	dropped int
	note    string
	running map[int]string
	procs   int

	findings []*finding
	findKey  map[string]*finding

	commands []*command
	cmdKey   map[string]*command

	changed    map[string]string
	newFiles   map[string]bool
	changedOut map[string]string
	deleted    map[string]string
	moved      []string
	generated  map[string]int
	genSeen    map[string]bool
	readIn     int
	readOut    map[string]string
	conns      map[string]map[string]bool
	hosts      map[string]string
	shown      map[string]int
	hidden     map[string]int
}

type feedLine struct {
	t    time.Time
	s    *session
	who  string
	verb string
	what string
	note string
	key  string
	dead bool
}

type owner struct {
	uid, gid int
	home     string
}

type recorder struct {
	mu        sync.Mutex
	out       io.Writer
	color     bool
	quiet     bool
	agents    map[string]bool
	procs     map[int]*proc
	sessions  []*session
	queue     []*feedLine
	pending   map[string]*feedLine
	now       time.Time
	events    int
	lastSeq   uint64
	save      io.Writer
	owner     owner
	reportDir string
	homes     map[int]string
	reports   []string
	wantPID   int
}

func newRecorder(out io.Writer, own owner, quiet bool, extra []string) *recorder {
	r := &recorder{
		out:       out,
		color:     useColor(out),
		quiet:     quiet,
		agents:    map[string]bool{},
		procs:     map[int]*proc{},
		pending:   map[string]*feedLine{},
		owner:     own,
		reportDir: filepath.Join(own.home, "Library", "Logs", "bodycam"),
		homes:     map[int]string{},
	}
	for _, a := range append(append([]string{}, defaultAgents...), extra...) {
		r.agents[a] = true
	}
	return r
}

func (r *recorder) read(in io.Reader) {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		r.handle(sc.Bytes())
	}
}

func (r *recorder) homeOf(uid int) string {
	if h, ok := r.homes[uid]; ok {
		return h
	}
	h := r.owner.home
	if u, err := user.LookupId(strconv.Itoa(uid)); err == nil && u.HomeDir != "" && uid != 0 {
		h = u.HomeDir
	}
	r.homes[uid] = h
	return h
}

func (r *recorder) handle(line []byte) {
	var m esMessage
	if json.Unmarshal(line, &m) != nil || len(m.Event) != 1 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	r.events++
	if r.lastSeq != 0 && m.Seq > r.lastSeq+1 {
		for _, s := range r.sessions {
			s.dropped += int(m.Seq - r.lastSeq - 1)
		}
	}
	if m.Seq > r.lastSeq {
		r.lastSeq = m.Seq
	}
	if m.Time.After(r.now) {
		r.now = m.Time
	}
	r.flush(false)

	var kind string
	var body json.RawMessage
	for k, v := range m.Event {
		kind, body = k, v
	}
	pid := m.Process.AuditToken.PID
	p := r.procs[pid]
	t := m.Time
	if p == nil && pid == r.wantPID {
		r.wantPID = 0
		cwd := ""
		var e execEvent
		if kind == "exec" && json.Unmarshal(body, &e) == nil {
			cwd = e.Cwd.Path
		}
		name := filepath.Base(m.Process.Executable.Path)
		p = &proc{pid: pid, name: name, s: r.newSession(name, pid, cwd, r.homeOf(m.Process.AuditToken.RUID), t, true)}
		p.s.unnamed = kind != "exec"
		r.procs[pid] = p
	}

	switch kind {
	case "exec":
		var e execEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		script := ""
		if e.Script != nil {
			script = e.Script.Path
		}
		if p == nil {
			agent := agentName(r.agents, e.Target.Executable.Path, e.Args, script)
			if agent == "" {
				return
			}
			s := r.newSession(agent, pid, e.Cwd.Path, r.homeOf(m.Process.AuditToken.RUID), t, false)
			r.procs[pid] = &proc{pid: pid, name: agent, s: s}
			r.keep(stripEnv(line))
			return
		}
		r.keep(stripEnv(line))
		if p.s.cwd == "" && e.Cwd.Path != "" {
			p.s.setProject(e.Cwd.Path)
		}
		r.onExec(p, e, t)
	case "fork":
		if p == nil {
			return
		}
		var e forkEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		child := e.Child.AuditToken.PID
		r.procs[child] = &proc{pid: child, name: p.name, s: p.s}
		p.s.running[child] = p.name
		p.s.procs++
		r.keep(line)
	case "exit":
		if p == nil {
			return
		}
		r.keep(line)
		delete(r.procs, pid)
		delete(p.s.running, pid)
		if pid == p.s.root {
			r.finish(p.s, t, "")
		}
	case "btm_launch_item_add":
		var e launchItemEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		if ip := r.procs[e.instigator()]; ip != nil {
			r.keep(line)
			r.flag(ip.s, t, "added something that runs in the background", ip.s.show(e.what()), ip.name)
		} else if e.instigator() == 0 {
			for _, s := range r.sessions {
				r.flag(s, t, "something was added to run in the background while it ran", s.show(e.what()), "")
			}
		}
	default:
		if p == nil {
			return
		}
		r.keep(line)
		r.onFile(p, kind, body, t)
	}
}

func (r *recorder) keep(line []byte) {
	if r.save != nil {
		r.save.Write(append(append([]byte{}, line...), '\n'))
	}
}

func (r *recorder) newSession(agent string, root int, cwd, home string, t time.Time, late bool) *session {
	s := &session{
		agent: agent, root: root, home: home, start: t, late: late,
		running: map[int]string{root: agent}, procs: 1,
		findKey: map[string]*finding{}, cmdKey: map[string]*command{},
		changed: map[string]string{}, newFiles: map[string]bool{}, changedOut: map[string]string{},
		deleted: map[string]string{}, generated: map[string]int{}, genSeen: map[string]bool{}, readOut: map[string]string{},
		conns: map[string]map[string]bool{}, hosts: map[string]string{},
		shown: map[string]int{}, hidden: map[string]int{},
	}
	s.setProject(cwd)
	r.sessions = append(r.sessions, s)
	what := fmt.Sprintf("pid %d", root)
	if s.project != "" {
		what += " in " + tilde(s.project, home)
	}
	if late {
		what += ", already running"
	}
	r.emit(&feedLine{t: t, s: s, who: agent, verb: "start", what: what})
	return s
}

func (s *session) setProject(cwd string) {
	s.cwd = cwd
	s.project = projectRoot(cwd, s.home)
	if s.project == s.home || s.project == "/" {
		s.note = "It started in " + tilde(s.project, s.home) + ", so everything under that folder counts as the project."
	}
}

func projectRoot(cwd, home string) string {
	if cwd == "" {
		return ""
	}
	for dir := cwd; dir != "/" && dir != home && dir != "."; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir
		}
	}
	return cwd
}

func (s *session) inProject(p string) bool {
	return s.project != "" && inside(p, s.project)
}

func tilde(p, home string) string {
	if home != "" && inside(p, home) {
		return "~" + strings.TrimPrefix(p, home)
	}
	return p
}

func (s *session) homeToTilde(cmd string) string {
	if s.home == "" || s.home == "/" {
		return cmd
	}
	return strings.ReplaceAll(cmd, s.home+"/", "~/")
}

func (s *session) show(p string) string {
	if s.project != "" && s.project != s.home && s.project != "/" && inside(p, s.project) && p != s.project {
		return strings.TrimPrefix(p, s.project+"/")
	}
	return tilde(p, s.home)
}

func (r *recorder) onExec(p *proc, e execEvent, t time.Time) {
	s := p.s
	args := e.Args
	if len(args) == 0 {
		args = []string{e.Target.Executable.Path}
	}
	tail := strings.Join(args[1:], "\x00")
	if p.args == tail && len(args) > 1 {
		return
	}
	p.args = tail
	p.name = filepath.Base(args[0])
	s.running[p.pid] = p.name
	if p.pid == s.root && s.unnamed {
		s.agent, s.unnamed = p.name, false
	}
	if script, ok := shellScript(args); ok {
		for _, label := range commandFlags(script) {
			r.flag(s, t, label, oneLine(s.homeToTilde(script), 160), p.name)
		}
		for _, h := range commandHosts(script) {
			if _, ok := s.hosts[h]; !ok {
				s.hosts[h] = p.name
			}
		}
		return
	}
	line := s.homeToTilde(commandLine(args))
	c := s.cmdKey[line]
	if c == nil {
		c = &command{line: line}
		s.cmdKey[line] = c
		s.commands = append(s.commands, c)
	}
	c.count++
	for _, h := range commandHosts(line) {
		s.hosts[h] = p.name
	}
	flags := commandFlags(line)
	if c.count == 1 {
		r.emit(&feedLine{t: t, s: s, who: p.name, verb: "run", what: oneLine(line, 120), note: strings.Join(flags, ", ")})
	}
	for _, label := range flags {
		r.recordFinding(s, label, oneLine(line, 160), p.name)
	}
}

func commandLine(args []string) string {
	parts := make([]string, len(args))
	for i, a := range args {
		if a == "" || strings.ContainsAny(a, " \t\n'\"$`\\|&;<>()*?") {
			a = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		}
		parts[i] = a
	}
	if len(parts) > 0 {
		parts[0] = filepath.Base(args[0])
	}
	return strings.Join(parts, " ")
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if len([]rune(s)) > max {
		s = string([]rune(s)[:max-1]) + "…"
	}
	return s
}

func (r *recorder) onFile(p *proc, kind string, body json.RawMessage, t time.Time) {
	s := p.s
	switch kind {
	case "open":
		var e openEvent
		if json.Unmarshal(body, &e) != nil || e.Flags&1 == 0 || e.File.isDir() {
			return
		}
		r.onRead(p, e.File.Path, t)
	case "close":
		var e closeEvent
		if json.Unmarshal(body, &e) != nil || !e.Modified {
			return
		}
		r.onChange(p, e.Target.Path, t)
	case "create":
		var e createEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		s.newFiles[e.Destination.path()] = true
	case "rename":
		var e renameEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		r.onRename(p, e.Source.Path, e.Destination.path(), e.Destination.ExistingFile == nil, t)
	case "unlink":
		var e unlinkEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		r.onDelete(p, e.Target.Path, t)
	case "uipc_connect":
		var e socketEvent
		if json.Unmarshal(body, &e) != nil {
			return
		}
		r.onSocket(p, e.File.Path, t)
	}
}

func (r *recorder) onRead(p *proc, path string, t time.Time) {
	s := p.s
	if label := secretLabel(path, s.home); label != "" {
		key := "read " + label + "\x00" + path
		if s.findKey[key] == nil {
			r.emit(&feedLine{t: t, s: s, who: p.name, verb: "read", what: s.show(path), note: label})
		}
		r.recordFinding(s, "read "+label, s.show(path), p.name)
		return
	}
	if s.inProject(path) {
		s.readIn++
		return
	}
	if noisyRead(path, s.home) {
		return
	}
	if _, ok := s.readOut[path]; !ok {
		s.readOut[path] = p.name
	}
}

func (r *recorder) onChange(p *proc, path string, t time.Time) {
	s := p.s
	if path == "" || ignoredChange(path, s.home) {
		return
	}
	verb := "edit"
	if s.newFiles[path] {
		verb = "new"
	}
	if label := changeLabel(path, s.home); label != "" {
		if s.inProject(path) {
			s.changed[path] = p.name
		} else {
			s.changedOut[path] = p.name
		}
		r.flag(s, t, label, s.show(path), p.name)
		return
	}
	if s.inProject(path) && s.project != s.home && s.project != "/" {
		rel := strings.TrimPrefix(path, s.project+"/")
		if g := generatedDir(rel); g != "" {
			if !s.genSeen[path] {
				s.genSeen[path] = true
				s.generated[g]++
			}
			return
		}
		if _, ok := s.changed[path]; ok {
			return
		}
		s.changed[path] = p.name
		r.emit(&feedLine{t: t, s: s, who: p.name, verb: verb, what: s.show(path), key: path})
		return
	}
	if s.inProject(path) {
		if _, ok := s.changed[path]; !ok {
			s.changed[path] = p.name
			r.emit(&feedLine{t: t, s: s, who: p.name, verb: verb, what: s.show(path), key: path})
		}
		return
	}
	if _, ok := s.changedOut[path]; ok {
		return
	}
	s.changedOut[path] = p.name
	group := groupOf(path, s.home)
	r.recordFinding(s, "changed files outside the project", tilde(group, s.home), p.name)
	r.emitLimited(&feedLine{t: t, s: s, who: p.name, verb: verb, what: s.show(path), note: "outside the project", key: path}, group)
}

func (r *recorder) onRename(p *proc, from, to string, created bool, t time.Time) {
	s := p.s
	if fl := r.pending[from]; fl != nil {
		fl.dead = true
		delete(r.pending, from)
	}
	_, wroteIt := s.changed[from]
	if !wroteIt {
		_, wroteIt = s.changedOut[from]
	}
	delete(s.changed, from)
	delete(s.changedOut, from)
	if created && wroteIt {
		s.newFiles[to] = true
	}
	if !wroteIt && !ignoredChange(from, s.home) {
		s.moved = append(s.moved, s.show(from)+" → "+s.show(to))
	}
	r.onChange(p, to, t)
}

func (r *recorder) onDelete(p *proc, path string, t time.Time) {
	s := p.s
	if fl := r.pending[path]; fl != nil {
		fl.dead = true
		delete(r.pending, path)
	}
	if ignoredChange(path, s.home) {
		return
	}
	if _, wrote := s.changed[path]; wrote && s.newFiles[path] {
		delete(s.changed, path)
		return
	}
	if label := changeLabel(path, s.home); label != "" {
		s.deleted[path] = p.name
		r.flag(s, t, label, s.show(path)+" (deleted)", p.name)
		return
	}
	if s.inProject(path) {
		if g := generatedDir(strings.TrimPrefix(path, s.project+"/")); g != "" && s.project != s.home {
			if !s.genSeen[path] {
				s.genSeen[path] = true
				s.generated[g]++
			}
			return
		}
		if _, ok := s.deleted[path]; !ok {
			s.deleted[path] = p.name
			r.emit(&feedLine{t: t, s: s, who: p.name, verb: "delete", what: s.show(path)})
		}
		return
	}
	if _, ok := s.deleted[path]; ok {
		return
	}
	s.deleted[path] = p.name
	group := groupOf(path, s.home)
	r.recordFinding(s, "deleted files outside the project", tilde(group, s.home), p.name)
	r.emitLimited(&feedLine{t: t, s: s, who: p.name, verb: "delete", what: s.show(path), note: "outside the project"}, group)
}

func (r *recorder) onSocket(p *proc, path string, t time.Time) {
	label := ""
	switch {
	case strings.HasSuffix(path, "docker.sock"):
		label = "talked to Docker"
	case strings.Contains(path, "ssh-agent") || strings.Contains(path, "/com.apple.launchd.") && strings.HasSuffix(path, "/Listeners") ||
		strings.Contains(strings.ToLower(path), "1password") && strings.HasSuffix(path, ".sock"):
		label = "used your SSH agent"
	}
	if label != "" {
		r.flag(p.s, t, label, tilde(path, p.s.home), p.name)
	}
}

// groupOf picks the folder a stray change is reported under, so one install is one line.
func groupOf(p, home string) string {
	parts := strings.Split(strings.TrimPrefix(p, "/"), "/")
	depth := 4
	if rel, ok := relHome(p, home); ok {
		parts = strings.Split(rel, "/")
		depth = 2
		if len(parts) <= depth {
			return p
		}
		return filepath.Join(home, filepath.Join(parts[:depth]...))
	}
	if len(parts) <= depth {
		return p
	}
	return "/" + filepath.Join(parts[:depth]...)
}

func (r *recorder) flag(s *session, t time.Time, label, what, who string) {
	key := label + "\x00" + what
	if s.findKey[key] == nil {
		r.emit(&feedLine{t: t, s: s, who: who, verb: "flag", what: what, note: label})
	}
	r.recordFinding(s, label, what, who)
}

func (r *recorder) recordFinding(s *session, label, what, who string) {
	key := label + "\x00" + what
	if f := s.findKey[key]; f != nil {
		f.count++
		return
	}
	f := &finding{label: label, what: what, who: who, count: 1}
	s.findKey[key] = f
	s.findings = append(s.findings, f)
}

func (r *recorder) emitLimited(fl *feedLine, group string) {
	if fl.s.shown[group] >= 3 {
		fl.s.hidden[group]++
		return
	}
	fl.s.shown[group]++
	r.emit(fl)
}

func (r *recorder) emit(fl *feedLine) {
	if r.quiet {
		return
	}
	r.queue = append(r.queue, fl)
	if fl.key != "" {
		r.pending[fl.key] = fl
	}
}

// flush holds lines for half a second, so a temp file renamed into place prints as one edit.
func (r *recorder) flush(all bool) {
	cut := r.now.Add(-500 * time.Millisecond)
	n := 0
	for _, fl := range r.queue {
		if !all && fl.t.After(cut) {
			break
		}
		n++
		if fl.key != "" && r.pending[fl.key] == fl {
			delete(r.pending, fl.key)
		}
		if !fl.dead {
			r.print(fl)
		}
	}
	r.queue = r.queue[n:]
}

func (r *recorder) finish(s *session, t time.Time, why string) {
	r.flush(true)
	s.end = t
	if why != "" {
		s.note = strings.TrimSpace(s.note + " " + why)
	}
	for pid, name := range s.running {
		if pid != s.root {
			r.recordFinding(s, "left running after it finished", fmt.Sprintf("%s (pid %d)", name, pid), "")
		}
		delete(r.procs, pid)
	}
	for pid, p := range r.procs {
		if p.s == s {
			delete(r.procs, pid)
		}
	}
	for i, x := range r.sessions {
		if x == s {
			r.sessions = append(r.sessions[:i], r.sessions[i+1:]...)
			break
		}
	}
	path, err := r.writeReport(s)
	if err != nil {
		fmt.Fprintf(os.Stderr, "bodycam: couldn't save the report: %v\n", err)
	}
	r.printSummary(s, path)
}

func (r *recorder) finishAll(why string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	end := r.now
	if end.IsZero() {
		end = time.Now()
	}
	for len(r.sessions) > 0 {
		r.finish(r.sessions[0], end, why)
	}
	r.flush(true)
}

func (r *recorder) trackedPIDs() map[int]*proc {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[int]*proc, len(r.procs))
	for pid, p := range r.procs {
		out[pid] = p
	}
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
