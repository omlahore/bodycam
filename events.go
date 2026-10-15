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

// stripEnv drops exec environments from saved logs, since that is where API keys live.
func stripEnv(line []byte) []byte {
	var m map[string]any
	if json.Unmarshal(line, &m) != nil {
		return line
	}
	ev, _ := m["event"].(map[string]any)
	ex, _ := ev["exec"].(map[string]any)
	if ex == nil {
		return line
	}
	delete(ex, "env")
	out, err := json.Marshal(m)
	if err != nil {
		return line
	}
	return out
}
