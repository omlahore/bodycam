package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
)

var version = "dev"

var wantedEvents = []string{
	"fork", "exec", "exit", "open", "close", "create", "rename", "unlink",
	"btm_launch_item_add", "uipc_connect",
}

type names []string

func (n *names) String() string     { return strings.Join(*n, ",") }
func (n *names) Set(v string) error { *n = append(*n, v); return nil }

func usage() {
	fmt.Fprintf(os.Stderr, `bodycam records what AI coding agents do on your Mac: the commands they run,
the files they change, the secrets they read and the addresses they connect to.

Usage:
  sudo bodycam                    record every agent you start, and report when each one exits
  sudo bodycam --pid 4242         also record an agent that was already running
  bodycam --replay events.jsonl   make reports from a log saved with --save

Agents it knows by name: %s

Options:
`, strings.Join(defaultAgents, ", "))
	flag.PrintDefaults()
}

func main() {
	var (
		pid     = flag.Int("pid", 0, "record the process with this `id` and everything it starts")
		replay  = flag.String("replay", "", "read events from a saved `file` instead of recording")
		save    = flag.String("save", "", "also save the agents' raw events to `file` (it can get big)")
		quiet   = flag.Bool("quiet", false, "skip the live feed and only print each agent's summary")
		showVer = flag.Bool("version", false, "print the version")
		extra   names
	)
	flag.Var(&extra, "agent", "also watch for processes with this `name` (can repeat)")
	flag.Usage = usage
	flag.Parse()

	if version == "dev" {
		if info, ok := debug.ReadBuildInfo(); ok && strings.HasPrefix(info.Main.Version, "v") {
			version = strings.TrimPrefix(info.Main.Version, "v")
		}
	}
	if *showVer {
		fmt.Println("bodycam", version)
		return
	}
	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "bodycam: unexpected argument %q. Start your agent in another terminal tab instead.\n\n", flag.Arg(0))
		usage()
		os.Exit(2)
	}

	own := currentOwner()
	r := newRecorder(os.Stdout, own, *quiet, extra)

	if *save != "" {
		f, err := os.OpenFile(*save, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			fail(err)
		}
		defer f.Close()
		if os.Geteuid() == 0 {
			f.Chown(own.uid, own.gid)
		}
		r.save = f
	}

	if *replay != "" {
		f, err := os.Open(*replay)
		if err != nil {
			fail(err)
		}
		defer f.Close()
		r.wantPID = *pid
		r.read(f)
		r.finishAll("The log ended before the agent exited.")
		return
	}

	if os.Geteuid() != 0 {
		fmt.Fprint(os.Stderr, "bodycam reads macOS Endpoint Security events, which needs root. Run it with sudo:\n\n  sudo bodycam\n")
		os.Exit(1)
	}

	r.live = true
	events, err := supportedEvents()
	if err != nil {
		fail(err)
	}
	cmd := exec.Command("/usr/bin/eslogger", events...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		fail(err)
	}
	if err := cmd.Start(); err != nil {
		fail(err)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		<-sig
		cmd.Process.Signal(syscall.SIGTERM)
	}()

	running, err := r.attachRunning(*pid)
	if err != nil {
		cmd.Process.Kill()
		fail(err)
	}
	fmt.Printf("bodycam %s is recording. Start your agent in another tab, and press Ctrl-C here to stop.\n", version)
	if len(running) > 0 {
		fmt.Printf("Already running, so not recorded: %s. Use --pid to record one of them.\n", strings.Join(running, ", "))
	}
	fmt.Println()

	stop := make(chan struct{})
	go r.pollNetwork(stop)
	r.read(out)
	close(stop)
	werr := cmd.Wait()
	if r.events == 0 && werr != nil {
		explain(stderr.String())
		os.Exit(1)
	}
	r.finishAll("bodycam stopped before the agent exited.")
}

func supportedEvents() ([]string, error) {
	out, err := exec.Command("/usr/bin/eslogger", "--list-events").Output()
	if err != nil {
		return nil, fmt.Errorf("couldn't run /usr/bin/eslogger, which comes with macOS 13 and later: %w", err)
	}
	have := map[string]bool{}
	for _, e := range strings.Fields(string(out)) {
		have[e] = true
	}
	var events []string
	for _, e := range wantedEvents {
		if have[e] {
			events = append(events, e)
		}
	}
	return events, nil
}

func explain(stderr string) {
	if strings.Contains(stderr, "NOT_PERMITTED") {
		fmt.Fprint(os.Stderr, `macOS didn't let bodycam read Endpoint Security events.
Give your terminal app Full Disk Access in System Settings > Privacy & Security >
Full Disk Access, quit and reopen the terminal, then run bodycam again.
`)
		return
	}
	fmt.Fprintf(os.Stderr, "eslogger stopped: %s\n", strings.TrimSpace(stderr))
}

func currentOwner() owner {
	if os.Geteuid() == 0 {
		if u, err := user.LookupId(os.Getenv("SUDO_UID")); err == nil {
			uid, _ := strconv.Atoi(u.Uid)
			gid, _ := strconv.Atoi(u.Gid)
			return owner{uid: uid, gid: gid, home: u.HomeDir}
		}
	}
	home, _ := os.UserHomeDir()
	return owner{uid: os.Getuid(), gid: os.Getgid(), home: home}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "bodycam:", err)
	os.Exit(1)
}
