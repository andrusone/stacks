package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"stacks/internal/installer"
	"stacks/internal/record"
	"stacks/internal/stack"
)

// env is everything a run reads from outside the program: the stacks folder, the install paths and the
// preflight checks. realEnv fills it for this machine; tests fill it with temp folders.
type env struct {
	Stacks string
	Cfg    installer.Config
	Pre    installer.PreflightEnv
}

// realEnv is this machine's paths (SI-FR-05, SI-FR-10): /svr, /var/lib/stacks, /etc/stacks, the clone
// under home, /proc/self/mounts, /etc/os-release and a lock in /tmp.
func realEnv(home string) env {
	return env{
		Stacks: installer.StacksDir(os.Getenv("STACKS_DIR"), home),
		Cfg: installer.Config{
			SvrDir:     "/svr",
			RecordsDir: "/var/lib/stacks",
			EnvDir:     "/etc/stacks",
			CloneDir:   filepath.Join(home, "src", "stacks"),
			MountsPath: "/proc/self/mounts",
		},
		Pre: installer.PreflightEnv{
			UID:           os.Getuid(),
			OSReleasePath: "/etc/os-release",
			LockPath:      "/tmp/setup-stacks.lock",
		},
	}
}

// dryRun is what --stack <name> does without --apply (SI-FR-05): the preflight, then the plan for the
// stack. It prints every would: and blocked: line and changes nothing. Exit 1 when anything is blocked.
func dryRun(stdout, stderr io.Writer, e env, s stack.Stack) int {
	if err := installer.Preflight(e.Pre); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer installer.Release(e.Pre.LockPath)
	installed, err := record.List(e.Cfg.RecordsDir)
	if err != nil {
		fmt.Fprintf(stderr, "error: cannot read the installed records in %s: %v\n", e.Cfg.RecordsDir, err)
		return 1
	}
	res := installer.Plan(e.Cfg, s, installed)
	for _, line := range res.Lines {
		fmt.Fprintln(stdout, line)
	}
	if res.Blocked {
		return 1
	}
	return 0
}
