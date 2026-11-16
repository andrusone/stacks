// Command health checks the health files of the stacks repo (HL-FR-06).
//
//	health check [dir]    dir defaults to "health"
//
// It exits 0 and prints "health: N stacks ok" when every file is good. It exits
// 1 and lists every problem as file:line: message. It exits 2 on a usage or
// read error.
package main

import (
	"fmt"
	"io"
	"os"

	"stacks/internal/healthfile"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, out, errw io.Writer) int {
	if len(args) < 1 || len(args) > 2 || args[0] != "check" {
		fmt.Fprintln(errw, "usage: health check [dir]")
		return 2
	}
	dir := "health"
	if len(args) == 2 {
		dir = args[1]
	}
	ok, probs, err := healthfile.CheckDir(dir)
	if err != nil {
		fmt.Fprintf(errw, "health: %v\n", err)
		return 2
	}
	if len(probs) > 0 {
		for _, p := range probs {
			fmt.Fprintln(out, p)
		}
		return 1
	}
	fmt.Fprintf(out, "health: %d stacks ok\n", ok)
	return 0
}
