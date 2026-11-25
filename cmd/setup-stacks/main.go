// Command setup-stacks is the stacks installer (SI-FR-01, MVP 1 in ST280; ST283 lists the stacks; ST287 parses the flags; ST291 prints the dry run). Only --help, the flag errors, the stack checks and the dry run are built so far.
package main

import (
	"fmt"
	"io"
	"os"

	"stacks/internal/installer"
	"stacks/internal/stack"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is the command on this machine: the real paths from realEnv.
func run(argv []string, stdout, stderr io.Writer) int {
	home, err := os.UserHomeDir()
	if err != nil && os.Getenv("STACKS_DIR") == "" {
		if _, perr := parseArgs(argv); perr != nil {
			fmt.Fprintf(stderr, "error: %s\n", perr)
			return 2
		}
		fmt.Fprintln(stderr, "error: no home folder, and STACKS_DIR is not set")
		return 1
	}
	return runWith(argv, stdout, stderr, realEnv(home))
}

// runWith is the command with every path and check passed in, so tests can use temp folders.
func runWith(argv []string, stdout, stderr io.Writer, e env) int {
	a, err := parseArgs(argv)
	if err != nil {
		fmt.Fprintf(stderr, "error: %s\n", err)
		return 2
	}
	stacks, errs := stack.Load(e.Stacks)
	if a.Help {
		installer.Help(stdout, e.Stacks, stacks, errs)
		return 0
	}
	if a == (args{}) {
		fmt.Fprintln(stdout, "no stack was named")
		installer.Help(stdout, e.Stacks, stacks, errs)
		return 1
	}
	s, ok := find(stacks, a.Stack)
	if a.Stack != "" && !ok {
		fmt.Fprintf(stdout, "unknown stack: %s\n", a.Stack)
		installer.Help(stdout, e.Stacks, stacks, errs)
		return 1
	}
	if a.Check || a.Apply {
		fmt.Fprintln(stderr, "error: not built yet")
		return 2
	}
	return dryRun(stdout, stderr, e, s)
}

// find returns the loaded stack with this name.
func find(stacks []stack.Stack, name string) (stack.Stack, bool) {
	for _, s := range stacks {
		if s.Name == name {
			return s, true
		}
	}
	return stack.Stack{}, false
}
