// Package stack reads the stacks folder (SI-FR-02): one folder per stack,
// each with a stack.toml that makes the stack exist. It never writes.
package stack

// file is the one file that makes a stack exist, inside its folder.
const file = "stack.toml"

// Stack is one stack as its stack.toml declares it.
type Stack struct {
	Name     string
	Meaning  string
	Version  string
	User     string
	Units    []string
	Ports    []int
	NasPaths []string
	Env      []string
	Dir      string // the folder it was read from
}
