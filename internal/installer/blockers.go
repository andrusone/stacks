package installer

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"stacks/internal/stack"
)

// BlockerInput is what Blockers checks (SI-FR-06). Paths are passed in so tests can use temp folders.
type BlockerInput struct {
	Stack      stack.Stack
	EnvFile    string // the stack's values, normally /etc/stacks/<name>.env
	ExampleEnv string // a path to the stack's example.env; skipped if unreadable
	CloneDir   string // the stacks clone
	SvrDir     string // the folder that must be a separate mount, normally /svr
	MountsPath string // a file in /proc/self/mounts format
}

// Blockers returns one "blocked: ..." line per problem, in order: the env values, the clone, the mount.
// It changes nothing on disk.
func Blockers(in BlockerInput) []string {
	var out []string
	out = append(out, envBlockers(in)...)
	if line := cloneBlocker(in.CloneDir); line != "" {
		out = append(out, line)
	}
	if line := mountBlocker(in.SvrDir, in.MountsPath); line != "" {
		out = append(out, line)
	}
	return out
}

// envBlockers names the missing keys of Stack.Env in EnvFile, then the example file's content.
// A file that cannot be read counts as missing, so every key is named.
func envBlockers(in BlockerInput) []string {
	data, err := os.ReadFile(in.EnvFile)
	have := map[string]bool{}
	if err == nil {
		have = keysWithValues(data)
	}
	var missing []string
	for _, k := range in.Stack.Env {
		if !have[k] {
			missing = append(missing, k)
		}
	}
	if err == nil && len(missing) == 0 {
		return nil
	}
	line := fmt.Sprintf("blocked: %s has no value for: %s", in.EnvFile, strings.Join(missing, ", "))
	if err != nil {
		line = fmt.Sprintf("blocked: %s is missing", in.EnvFile)
		if len(missing) > 0 {
			line += "; it must hold: " + strings.Join(missing, ", ")
		}
	}
	out := []string{line}
	if ex, err := os.ReadFile(in.ExampleEnv); err == nil {
		out = append(out, "example: "+strings.TrimRight(string(ex), "\r\n"))
	}
	return out
}

// keysWithValues reads KEY=value lines and returns the keys whose value is not empty.
func keysWithValues(data []byte) map[string]bool {
	have := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		key, val, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		if key = strings.TrimSpace(key); key != "" && strings.TrimSpace(val) != "" {
			have[key] = true
		}
	}
	return have
}

// cloneBlocker reports uncommitted changes in the stacks clone; "" when the clone is clean.
func cloneBlocker(dir string) string {
	out, err := exec.Command("git", "-C", dir, "status", "--porcelain").Output()
	if err != nil {
		return fmt.Sprintf("blocked: cannot read the stacks clone %s: %v", dir, err)
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return ""
	}
	return fmt.Sprintf("blocked: the stacks clone %s has uncommitted changes; commit or discard them", dir)
}

// mountBlocker reports a dir that is not the second field of a line in the mounts file; "" when it is mounted.
// A mounts file that cannot be read counts as not mounted.
func mountBlocker(dir, mountsPath string) string {
	want := filepath.Clean(dir)
	if f, err := os.Open(mountsPath); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			fields := strings.Fields(sc.Text())
			if len(fields) >= 2 && filepath.Clean(fields[1]) == want {
				return ""
			}
		}
	}
	return fmt.Sprintf("blocked: %s is not a mounted filesystem; mount it first (this script never mounts or formats anything)", dir)
}
