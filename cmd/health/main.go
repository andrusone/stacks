// Command health checks the health files of the stacks repo (HL-FR-06) and
// writes the monitor's checks from them.
//
//	health check [dir]      dir defaults to "health"
//	health generate [dir]   prints the Gatus config for dir to stdout
//	health new <forge|runner> <address> [--commit]   see new.go
//
// check exits 0 and prints "health: N stacks ok" when every file is good. It
// exits 1 and lists every problem as file:line: message on stdout.
//
// generate prints nothing on stdout unless every file is good. Then it prints
// the whole config. If there are problems it lists them on stderr and exits 1.
//
// Both exit 2 on a usage or read error.
package main

import (
	"fmt"
	"io"
	"os"

	"stacks/internal/gatusconf"
	"stacks/internal/healthfile"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, out, errw io.Writer) int {
	if len(args) >= 1 && args[0] == "new" {
		return newCommand(args[1:], out, errw)
	}
	if len(args) < 1 || len(args) > 2 || (args[0] != "check" && args[0] != "generate") {
		fmt.Fprintln(errw, "usage: health check [dir] | health generate [dir] | health new <forge|runner> <address> [--commit]")
		return 2
	}
	dir := "health"
	if len(args) == 2 {
		dir = args[1]
	}
	if args[0] == "generate" {
		return generate(dir, out, errw)
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

func generate(dir string, out, errw io.Writer) int {
	stacks, probs, err := healthfile.LoadDir(dir)
	if err != nil {
		fmt.Fprintf(errw, "health: %v\n", err)
		return 2
	}
	if len(probs) > 0 {
		for _, p := range probs {
			fmt.Fprintln(errw, p)
		}
		return 1
	}
	cfg, err := gatusconf.Generate(stacks)
	if err != nil {
		fmt.Fprintf(errw, "health: %v\n", err)
		return 1
	}
	fmt.Fprint(out, cfg)
	return 0
}
