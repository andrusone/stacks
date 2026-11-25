// Command setup-stacks is the stacks installer (SI-FR-01, MVP 1 in ST280; ST283 lists the stacks). Only --help is built so far.
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

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 || args[0] != "--help" {
		fmt.Fprintln(stderr, "error: not built yet")
		return 2
	}
	home, err := os.UserHomeDir()
	if err != nil && os.Getenv("STACKS_DIR") == "" {
		fmt.Fprintln(stderr, "error: no home folder, and STACKS_DIR is not set")
		return 1
	}
	dir := installer.StacksDir(os.Getenv("STACKS_DIR"), home)
	stacks, errs := stack.Load(dir)
	installer.Help(stdout, dir, stacks, errs)
	return 0
}
