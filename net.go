package main

import (
	"encoding/json"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type conn struct {
	pid    int
	name   string
	remote string
}

// pollNetwork samples the agents' open TCP connections, because Endpoint Security has no connect event.
func (r *recorder) pollNetwork(stop <-chan struct{}) {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		procs := r.trackedPIDs()
		if len(procs) == 0 {
			continue
		}
		pids := make([]string, 0, len(procs))
		for pid := range procs {
			pids = append(pids, strconv.Itoa(pid))
		}
		out, _ := exec.Command("lsof", "-nP", "-a", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn", "-p", strings.Join(pids, ",")).Output()
		conns := parseLsof(out)
		if len(conns) == 0 {
			continue
		}
		r.mu.Lock()
		now := time.Now()
		for _, c := range conns {
			if p := r.procs[c.pid]; p != nil {
				r.addConn(p, c.name, c.remote, now)
			}
		}
		r.mu.Unlock()
	}
}

func parseLsof(out []byte) []conn {
	var res []conn
	var pid int
	var name string
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			pid, _ = strconv.Atoi(line[1:])
		case 'c':
			name = line[1:]
		case 'n':
			i := strings.Index(line, "->")
			if i < 0 {
				continue
			}
			remote := line[i+2:]
			if host, _, err := net.SplitHostPort(remote); err == nil {
				if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
					continue
				}
			}
			res = append(res, conn{pid: pid, name: name, remote: remote})
		}
	}
	return res
}

func (r *recorder) addConn(p *proc, name, remote string, t time.Time) {
	s := p.s
	if s.conns[remote] == nil {
		s.conns[remote] = map[string]bool{}
		r.emit(&feedLine{t: t, s: s, who: name, verb: "net", what: remote})
		if r.save != nil {
			line, _ := json.Marshal(map[string]any{"bodycam_conn": map[string]any{
				"time": t, "pid": p.pid, "name": name, "remote": remote,
			}})
			r.save.Write(append(line, '\n'))
		}
	}
	s.conns[remote][name] = true
}
