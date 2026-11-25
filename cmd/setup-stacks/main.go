// Command setup-stacks is the stacks installer (SI-FR-01, MVP 1 in ST280; ST283 lists the stacks; ST287 parses the flags). Only --help, the flag errors and the stack checks are built so far.
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

func run(argv []string, stdout, stderr io.Writer) int {
	a, err := parseArgs(argv)
	if err != nil {
		fmt.Fprintf(stderr, "error: %s\n", err)
		return 2
	}
	home, err := os.UserHomeDir()
	if err != nil && os.Getenv("STACKS_DIR") == "" {
		fmt.Fprintln(stderr, "error: no home folder, and STACKS_DIR is not set")
		return 1
	}
	dir := installer.StacksDir(os.Getenv("STACKS_DIR"), home)
	stacks, errs := stack.Load(dir)
	if a.Help {
		installer.Help(stdout, dir, stacks, errs)
		return 0
	}
	if a == (args{}) {
		fmt.Fprintln(stdout, "no stack was named")
		installer.Help(stdout, dir, stacks, errs)
		return 1
	}
	if a.Stack != "" && !known(stacks, a.Stack) {
		fmt.Fprintf(stdout, "unknown stack: %s\n", a.Stack)
		installer.Help(stdout, dir, stacks, errs)
		return 1
	}
	fmt.Fprintln(stderr, "error: not built yet")
	return 2
}

// known reports whether a loaded stack has this name.
func known(stacks []stack.Stack, name string) bool {
	for _, s := range stacks {
		if s.Name == name {
			return true
		}
	}
	return false
}
