package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// The JSON lines the menu bar app reads. app/ENGINE.md describes them.

func (r *recorder) writeEvent(v map[string]any) {
	if r.eventsOut == nil {
		return
	}
	line, err := json.Marshal(v)
	if err != nil {
		return
	}
	r.eventsOut.Write(append(line, '\n'))
}

func (s *session) id() string {
	return fmt.Sprintf("%d-%d", s.start.Unix(), s.root)
}

func (r *recorder) writeStart(s *session) {
	if s.announced {
		return
	}
	s.announced = true
	r.writeEvent(map[string]any{
		"type": "start", "time": s.start.Format(time.RFC3339), "session": s.id(), "agent": s.agent,
		"pid": s.root, "project": tilde(s.project, s.home), "late": s.late,
	})
}

func (r *recorder) writeFeed(fl *feedLine) {
	if fl.verb == "start" {
		r.writeStart(fl.s)
		return
	}
	r.writeStart(fl.s)
	r.writeEvent(map[string]any{
		"type": "event", "time": fl.t.Format(time.RFC3339), "session": fl.s.id(), "who": fl.who,
		"verb": fl.verb, "what": fl.what, "note": fl.note,
		"flag": fl.verb == "flag" || fl.verb == "read" || fl.note != "" && fl.note != "outside the project",
	})
}

func (r *recorder) writeEnd(s *session, report string) {
	r.writeStart(s)
	runs := 0
	for _, c := range s.commands {
		runs += c.count
	}
	findings := make([]map[string]any, 0, len(s.findings))
	for _, f := range s.findings {
		who := f.who
		if who == nil {
			who = []string{}
		}
		findings = append(findings, map[string]any{"label": f.label, "what": f.what, "who": who, "count": f.count})
	}
	r.writeEvent(map[string]any{
		"type": "end", "time": s.end.Format(time.RFC3339), "session": s.id(), "agent": s.agent,
		"pid": s.root, "project": tilde(s.project, s.home), "seconds": int(s.end.Sub(s.start).Seconds()),
		"findings": findings, "commands": runs, "changed": len(s.changed), "changed_outside": len(s.changedOut),
		"deleted": len(s.deleted), "reads": s.readIn, "reads_outside": len(s.readOut),
		"connections": len(s.conns), "dropped": s.dropped, "report": report,
	})
}

func (r *recorder) writeStatus(state string, extra map[string]any) {
	v := map[string]any{"type": "status", "time": time.Now().Format(time.RFC3339), "state": state}
	for k, x := range extra {
		v[k] = x
	}
	r.writeEvent(v)
}

func openEvents(path string, own owner) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	if os.Geteuid() == 0 {
		f.Chown(own.uid, own.gid)
	}
	return f, nil
}
