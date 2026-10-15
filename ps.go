package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type psRow struct {
	pid, ppid, uid int
	args           []string
}

// attachRunning picks up agents that were running before bodycam started, and the --pid one.
func (r *recorder) attachRunning(want int) error {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,uid=,args=").Output()
	if err != nil {
		return err
	}
	rows := map[int]psRow{}
	kids := map[int][]int{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		uid, _ := strconv.Atoi(f[2])
		rows[pid] = psRow{pid: pid, ppid: ppid, uid: uid, args: f[3:]}
		kids[ppid] = append(kids[ppid], pid)
	}
	if want > 0 {
		if _, ok := rows[want]; !ok {
			return fmt.Errorf("no process has pid %d", want)
		}
	}
	agentOf := func(row psRow) string {
		return agentName(r.agents, row.args[0], row.args, "")
	}
	isRoot := func(pid int) bool {
		row := rows[pid]
		if pid != want && agentOf(row) == "" {
			return false
		}
		for p := row.ppid; p > 1; p = rows[p].ppid {
			anc, ok := rows[p]
			if !ok || p == os.Getpid() {
				break
			}
			if p == want || agentOf(anc) != "" {
				return false
			}
		}
		return true
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	for pid, row := range rows {
		if pid == os.Getpid() || !isRoot(pid) {
			continue
		}
		name := agentOf(row)
		if name == "" {
			name = filepath.Base(row.args[0])
		}
		s := r.newSession(name, pid, cwdOf(pid), r.homeOf(row.uid), time.Now(), true)
		r.procs[pid] = &proc{pid: pid, name: name, s: s}
		queue := kids[pid]
		for len(queue) > 0 {
			k := queue[0]
			queue = queue[1:]
			kname := filepath.Base(rows[k].args[0])
			r.procs[k] = &proc{pid: k, name: kname, s: s}
			s.running[k] = kname
			s.procs++
			queue = append(queue, kids[k]...)
		}
	}
	return nil
}

func cwdOf(pid int) string {
	out, err := exec.Command("lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "n") {
			return line[1:]
		}
	}
	return ""
}
