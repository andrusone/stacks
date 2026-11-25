// Package installer holds the stacks installer's pieces. ST280 has only the help text.
package installer

import (
	"fmt"
	"io"
	"path/filepath"
)

// StacksDir is the folder stacks live in: env (STACKS_DIR) when set, otherwise src/stacks/stacks under home.
func StacksDir(env, home string) string {
	if env != "" {
		return env
	}
	return filepath.Join(home, "src", "stacks", "stacks")
}

// Help writes the flags, one per line with its meaning, and says there are no stacks yet.
// It changes nothing. Later stories add a line per stack in stacksDir.
func Help(w io.Writer, stacksDir string) {
	fmt.Fprintln(w, "flags:")
	fmt.Fprintln(w, "  --help           show this help and change nothing")
	fmt.Fprintln(w, "  --stack <name>   the stack to install (a dry run unless --apply)")
	fmt.Fprintln(w, "  --apply          make the changes the dry run lists")
	fmt.Fprintln(w, "  --check          check what is installed and change nothing")
	fmt.Fprintf(w, "no stacks yet: a stack is a folder with a stack.toml in %s\n", stacksDir)
}
