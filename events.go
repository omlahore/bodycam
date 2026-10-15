package main

import (
	"encoding/json"
	"net/url"
	"path/filepath"
	"time"
)

// The subset of eslogger's JSON that bodycam reads.

type esFile struct {
	Path string `json:"path"`
	Stat *struct {
		Mode int `json:"st_mode"`
	} `json:"stat"`
}

func (f esFile) isDir() bool {
	return f.Stat != nil && f.Stat.Mode&0o170000 == 0o040000
}

type esToken struct {
	PID  int `json:"pid"`
	RUID int `json:"ruid"`
}

type esProcess struct {
	AuditToken esToken `json:"audit_token"`
	Executable esFile  `json:"executable"`
}

type esMessage struct {
	Time    time.Time                  `json:"time"`
	Seq     uint64                     `json:"global_seq_num"`
	Process esProcess                  `json:"process"`
	Event   map[string]json.RawMessage `json:"event"`
}

type esDestination struct {
	ExistingFile *esFile `json:"existing_file"`
	NewPath      *struct {
		Dir      esFile `json:"dir"`
		Filename string `json:"filename"`
	} `json:"new_path"`
}

func (d esDestination) path() string {
	if d.ExistingFile != nil {
		return d.ExistingFile.Path
	}
	if d.NewPath != nil {
		return filepath.Join(d.NewPath.Dir.Path, d.NewPath.Filename)
	}
	return ""
}

type forkEvent struct {
	Child esProcess `json:"child"`
}

type execEvent struct {
	Target esProcess `json:"target"`
	Args   []string  `json:"args"`
	Cwd    esFile    `json:"cwd"`
	Script *esFile   `json:"script"`
}

type openEvent struct {
	File  esFile `json:"file"`
	Flags int    `json:"fflag"`
}

type closeEvent struct {
	Target   esFile `json:"target"`
	Modified bool   `json:"modified"`
}

type createEvent struct {
	Destination esDestination `json:"destination"`
}

type renameEvent struct {
	Source      esFile        `json:"source"`
	Destination esDestination `json:"destination"`
}

type unlinkEvent struct {
	Target esFile `json:"target"`
}

type socketEvent struct {
	File esFile `json:"file"`
}

type launchItemEvent struct {
	Instigator      *esProcess `json:"instigator"`
	InstigatorToken *esToken   `json:"instigator_token"`
	Item            *struct {
		ItemURL string `json:"item_url"`
		AppURL  string `json:"app_url"`
	} `json:"item"`
	ExecutablePath string `json:"executable_path"`
}

func (e launchItemEvent) instigator() int {
	if e.Instigator != nil {
		return e.Instigator.AuditToken.PID
	}
	if e.InstigatorToken != nil {
		return e.InstigatorToken.PID
	}
	return 0
}

func (e launchItemEvent) what() string {
	if e.Item != nil && e.Item.ItemURL != "" {
		return fileURLPath(e.Item.ItemURL)
	}
	if e.ExecutablePath != "" {
		return e.ExecutablePath
	}
	if e.Item != nil {
		return fileURLPath(e.Item.AppURL)
	}
	return "a background item"
}

func fileURLPath(s string) string {
	if u, err := url.Parse(s); err == nil && u.Scheme == "file" {
		return u.Path
	}
	return s
}

// Fields bodycam never reads. Saved logs drop them, exec environments with their API keys included.
var unusedFields = map[string]bool{
	"env": true, "cdhash": true, "codesigning_flags": true, "signing_id": true, "team_id": true,
	"parent_audit_token": true, "responsible_audit_token": true, "entitlements": true, "fds": true,
	"tty": true, "start_time": true, "is_platform_binary": true, "is_es_client": true, "session_id": true,
	"group_id": true, "cs_validation_category": true, "thread": true, "mach_time": true, "action": true,
	"action_type": true, "seq_num": true, "dyld_exec_path": true, "last_fd": true, "image_cputype": true,
	"image_cpusubtype": true, "path_truncated": true, "schema_version": true, "version": true,
}

func compact(line []byte) []byte {
	var m map[string]any
	if json.Unmarshal(line, &m) != nil {
		return nil
	}
	prune(m)
	out, err := json.Marshal(m)
	if err != nil {
		return nil
	}
	return out
}

func prune(v any) {
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			switch {
			case k == "stat":
				if st, ok := child.(map[string]any); ok {
					x[k] = map[string]any{"st_mode": st["st_mode"]}
				}
			case unusedFields[k]:
				delete(x, k)
			default:
				prune(child)
			}
		}
	case []any:
		for _, child := range x {
			prune(child)
		}
	}
}

// savedConn is how --save records a sampled network connection, since eslogger has no event for it.
type savedConn struct {
	Conn *struct {
		Time   time.Time `json:"time"`
		PID    int       `json:"pid"`
		Name   string    `json:"name"`
		Remote string    `json:"remote"`
	} `json:"bodycam_conn"`
}
