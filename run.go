package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// runCommand records one command, started by bodycam itself, and returns its exit code.
func runCommand(r *recorder, args []string, name string, inline bool) int {
	if os.Geteuid() == 0 {
		fail(fmt.Errorf("run it without sudo, as bodycam %s. bodycam asks for your password itself, so %s runs as you and not as root", args[0], args[0]))
	}
	path, err := exec.LookPath(args[0])
	if err != nil {
		fail(err)
	}
	events, err := supportedEvents()
	if err != nil {
		fail(err)
	}

	fmt.Fprintf(os.Stderr, "bodycam needs your Mac password to start Apple's eslogger. %s itself runs as you.\n", name)
	auth := exec.Command("sudo", "-v", "-p", "Password: ")
	auth.Stdin, auth.Stdout, auth.Stderr = os.Stdin, os.Stdout, os.Stderr
	if auth.Run() != nil {
		os.Exit(1)
	}

	es := exec.Command("sudo", append([]string{"-n", "/usr/bin/eslogger"}, events...)...)
	es.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var stderr bytes.Buffer
	es.Stderr = &stderr
	out, err := es.StdoutPipe()
	if err != nil {
		fail(err)
	}
	if err := es.Start(); err != nil {
		fail(err)
	}
	done := make(chan struct{})
	go func() {
		r.read(out)
		close(done)
	}()
	stop := func() {
		es.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			es.Process.Kill()
		}
		es.Wait()
	}

	if err := r.waitForEvents(done, 5*time.Second); err != nil {
		stop()
		if s := stderr.String(); s != "" {
			explain(s)
		} else {
			fmt.Fprintln(os.Stderr, "bodycam:", err)
		}
		os.Exit(1)
	}

	if !inline && !r.quiet {
		live := filepath.Join(r.reportDir, "live.log")
		f, err := openLive(live)
		r.mu.Lock()
		if err == nil {
			defer f.Close()
			r.feed, r.feedColor = f, true
			fmt.Fprintf(os.Stderr, "Recording. Live feed: tail -f %s\n\n", tilde(live, r.owner.home))
		} else {
			r.quiet = true
		}
		r.mu.Unlock()
	}

	r.mu.Lock()
	r.wrapPPID, r.wrapName = os.Getpid(), name
	r.mu.Unlock()

	cmd := exec.Command(path, args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, os.Interrupt, syscall.SIGQUIT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sig)
	if err := cmd.Start(); err != nil {
		stop()
		fail(err)
	}
	go func() {
		for s := range sig {
			// Ctrl-C already reaches the command through the terminal; pass on the rest.
			if s == syscall.SIGTERM || s == syscall.SIGHUP {
				cmd.Process.Signal(s)
			}
		}
	}()
	netStop := make(chan struct{})
	go r.pollNetwork(netStop)

	werr := cmd.Wait()
	close(netStop)
	r.waitForSessions(3 * time.Second)
	stop()
	r.finishAll("")

	var exit *exec.ExitError
	if errors.As(werr, &exit) {
		return exit.ExitCode()
	}
	return 0
}

func openLive(path string) (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
}

func (r *recorder) waitForEvents(done <-chan struct{}, limit time.Duration) error {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := r.events
		r.mu.Unlock()
		if n > 0 {
			return nil
		}
		select {
		case <-done:
			return errors.New("eslogger stopped before it sent any events")
		case <-time.After(20 * time.Millisecond):
		}
	}
	return errors.New("eslogger didn't send any events")
}

// waitForSessions gives eslogger a moment to deliver the command's last events.
func (r *recorder) waitForSessions(limit time.Duration) {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := len(r.sessions)
		r.mu.Unlock()
		if n == 0 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}
