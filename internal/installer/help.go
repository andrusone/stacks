// Package installer holds the stacks installer's pieces. ST280 has the help text; ST283 lists the stacks in it.
package installer

import (
	"fmt"
	"io"
	"path/filepath"
	"sort"

	"stacks/internal/stack"
)

// StacksDir is the folder stacks live in: env (STACKS_DIR) when set, otherwise src/stacks/stacks under home.
func StacksDir(env, home string) string {
	if env != "" {
		return env
	}
	return filepath.Join(home, "src", "stacks", "stacks")
}

// Help writes the flags, one per line with its meaning, then one line per stack
// in name order and one "problem:" line per load error. With no stacks and no
// errors it says there are no stacks yet and where one goes. It changes nothing.
func Help(w io.Writer, stacksDir string, stacks []stack.Stack, errs []error) {
	fmt.Fprintln(w, "flags:")
	fmt.Fprintln(w, "  --help           show this help and change nothing")
	fmt.Fprintln(w, "  --stack <name>   the stack to install (a dry run unless --apply)")
	fmt.Fprintln(w, "  --apply          make the changes the dry run lists")
	fmt.Fprintln(w, "  --check          check what is installed and change nothing")
	if len(stacks) == 0 && len(errs) == 0 {
		fmt.Fprintf(w, "no stacks yet: a stack is a folder with a stack.toml in %s\n", stacksDir)
		return
	}
	sorted := append([]stack.Stack(nil), stacks...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Name < sorted[j].Name })
	for _, s := range sorted {
		fmt.Fprintf(w, "  %s  %s\n", s.Name, s.Meaning)
	}
	for _, err := range errs {
		fmt.Fprintf(w, "problem: %s\n", err)
	}
}
