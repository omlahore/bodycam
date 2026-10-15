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
	exe            string
	args           []string
}

// attachRunning picks up agents that were running before bodycam started, and the --pid one.
func (r *recorder) attachRunning(want int) error {
	rows := map[int]psRow{}
	kids := map[int][]int{}
	err := psEach("pid=,ppid=,uid=,comm=", 3, func(f []string, rest string) {
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		uid, _ := strconv.Atoi(f[2])
		rows[pid] = psRow{pid: pid, ppid: ppid, uid: uid, exe: rest, args: []string{rest}}
		kids[ppid] = append(kids[ppid], pid)
	})
	if err != nil {
		return err
	}
	psEach("pid=,args=", 1, func(f []string, rest string) {
		pid, _ := strconv.Atoi(f[0])
		if row, ok := rows[pid]; ok && rest != "" {
			row.args = strings.Fields(rest)
			rows[pid] = row
		}
	})
	if want > 0 {
		if _, ok := rows[want]; !ok {
			return fmt.Errorf("no process has pid %d", want)
		}
	}
	agentOf := func(row psRow) string {
		return agentName(r.agents, row.exe, row.args, "")
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
			name = filepath.Base(row.exe)
		}
		s := r.newSession(name, pid, cwdOf(pid), r.homeOf(row.uid), time.Now(), true)
		r.procs[pid] = &proc{pid: pid, name: name, s: s}
		queue := kids[pid]
		for len(queue) > 0 {
			k := queue[0]
			queue = queue[1:]
			kname := filepath.Base(rows[k].exe)
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

// psEach runs ps and hands each row's first n columns and the rest of the line to fn.
func psEach(columns string, n int, fn func(fields []string, rest string)) error {
	out, err := exec.Command("ps", "-axww", "-o", columns).Output()
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) <= n {
			continue
		}
		rest := strings.TrimSpace(line)
		for i := 0; i < n; i++ {
			rest = strings.TrimSpace(strings.TrimPrefix(rest, f[i]))
		}
		fn(f[:n], rest)
	}
	return nil
}
