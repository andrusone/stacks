package main

// The new command writes a stack's health file from a template (HL-FR-06), so
// the owner does not type it by hand:
//
//	health new <forge|runner> <address> [--commit]
//
// It writes health/<stack>.toml under the current folder, which is the stacks
// repo root. It refuses an existing file and an address that is not IPv4, and
// writes nothing for either. It then runs the same check as `health check` over
// the health folder and removes the new file if the check fails. With --commit
// it stages that one file and commits it. It never pushes.
//
// Exit codes: 0 written (and committed), 1 refused or the check failed, 2 usage.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"stacks/internal/healthfile"
)

// newStacks are the stacks this command writes a file for.
var newStacks = map[string]bool{"forge": true, "runner": true}

// forgePort is the port the forge's own HTTP check uses: the FORGE_PORT default
// in compose/forge-vm/.env.example.
const forgePort = "3000"

// runnerPort is the port of the runner's health service in
// compose/runner-vm/docker-compose.yml.
const runnerPort = "8081"

func newCommand(args []string, out, errw io.Writer) int {
	commit := false
	var pos []string
	for _, a := range args {
		if a == "--commit" {
			commit = true
			continue
		}
		pos = append(pos, a)
	}
	if len(pos) != 2 || !newStacks[pos[0]] {
		fmt.Fprintln(errw, "usage: health new <forge|runner> <address> [--commit]")
		return 2
	}
	return newStack(".", pos[0], pos[1], commit, out, errw)
}

// newStack writes health/<stack>.toml under root, checks it and optionally
// commits it. root is the stacks repo.
func newStack(root, stack, addr string, commit bool, out, errw io.Writer) int {
	if !isIPv4(addr) {
		fmt.Fprintf(errw, "new: %q is not an IPv4 address; nothing written\n", addr)
		return 2
	}
	healthDir := filepath.Join(root, "health")
	file := stack + healthfile.Ext
	path := filepath.Join(healthDir, file)

	body, err := template(stack, addr)
	if err != nil {
		fmt.Fprintf(errw, "new: %v\n", err)
		return 2
	}

	// O_EXCL: an existing file is refused, and nothing is overwritten.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			fmt.Fprintf(errw, "new: health/%s already exists; left alone\n", file)
			return 1
		}
		fmt.Fprintf(errw, "new: %v\n", err)
		return 2
	}
	_, werr := f.Write(body)
	cerr := f.Close()
	if werr != nil || cerr != nil {
		os.Remove(path)
		fmt.Fprintf(errw, "new: writing health/%s: %v\n", file, firstErr(werr, cerr))
		return 2
	}

	ok, probs, err := healthfile.CheckDir(healthDir)
	if err != nil {
		os.Remove(path)
		fmt.Fprintf(errw, "health: %v\n", err)
		return 2
	}
	if len(probs) > 0 {
		for _, p := range probs {
			fmt.Fprintln(out, p)
		}
		os.Remove(path)
		fmt.Fprintf(errw, "new: health/%s removed: the check failed\n", file)
		return 1
	}
	fmt.Fprintf(out, "health/%s written; health: %d stacks ok\n", file, ok)

	if !commit {
		fmt.Fprintf(out, "commit health/%s: the monitor reads it from git\n", file)
		return 0
	}
	msg := fmt.Sprintf("health: add %s at %s", stack, addr)
	if err := gitCommit(root, filepath.Join("health", file), msg); err != nil {
		fmt.Fprintf(errw, "new: health/%s is written but not committed: %v\n", file, err)
		return 1
	}
	fmt.Fprintf(out, "committed: %s (not pushed)\n", msg)
	return 0
}

// template returns the health file for stack at addr. The shape is the one
// compose/forge-vm/setup.sh and compose/runner-vm/setup.sh write.
func template(stack, addr string) ([]byte, error) {
	var s string
	switch stack {
	case "forge":
		// Soft: the NAS. It is a comment only, because a needs entry must name
		// another health file, and the typed needs of HL-FR-16 are not written yet.
		s = fmt.Sprintf(`# The forge's health file (FG-FR-09, ST108): written by health new from the VM's address.
# Soft dependency: the NAS (it keeps working, reduced). Not in needs until HL-FR-16 types them.
host = "%[1]s"
service = "%[1]s:%[2]s"
request = "http://%[1]s:%[2]s/"
expect_status = 200
needs = []
`, addr, forgePort)
	case "runner":
		// Hard dependency: the forge. The runner is down without it. needs is the
		// only place it is written until HL-FR-16 adds the type.
		s = fmt.Sprintf(`# The runner's health file (FG-FR-09, ST109): written by health new from the VM's address.
# Hard dependency: the forge (the runner is down without it). Its one entry in needs.
host = "%[1]s"
service = "%[1]s:%[2]s"
request = "http://%[1]s:%[2]s/"
expect_status = 200
needs = ["forge"]
`, addr, runnerPort)
	default:
		return nil, fmt.Errorf("no template for %q", stack)
	}
	return []byte(s), nil
}

// isIPv4 reports whether s is a dotted IPv4 address. IPv6 forms are refused,
// including the IPv4-mapped ones.
func isIPv4(s string) bool {
	if strings.Contains(s, ":") {
		return false
	}
	ip := net.ParseIP(s)
	return ip != nil && ip.To4() != nil
}

// gitCommit stages rel (a path under root) and commits only that path, so
// anything else staged in the repo stays staged.
func gitCommit(root, rel, msg string) error {
	if err := runGit(root, "add", "--", rel); err != nil {
		return err
	}
	return runGit(root, "commit", "-m", msg, "--", rel)
}

func runGit(root string, args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git %s: %v: %s", args[0], err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func firstErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}
