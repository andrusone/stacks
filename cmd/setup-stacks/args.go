package main

import (
	"errors"
	"fmt"
	"strings"
)

// args is what the command line asks for. parseArgs decides it; run acts on it.
// The zero value means no flags at all.
type args struct {
	Help, Check, Apply bool
	Stack              string
}

const flagList = "the flags are --help, --stack <name>, --apply and --check"

// parseArgs reads the command line. A conflict or an unknown flag is an error
// with one line saying what to change, and nothing is guessed (SI-FR-04).
// A value after --stack must not start with "--".
func parseArgs(argv []string) (args, error) {
	var a args
	stackGiven := false
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		switch arg {
		case "--help":
			a.Help = true
		case "--check":
			a.Check = true
		case "--apply":
			a.Apply = true
		case "--stack":
			if stackGiven {
				return args{}, errors.New("--stack is given twice: pick one stack name")
			}
			if i+1 >= len(argv) || strings.HasPrefix(argv[i+1], "--") {
				return args{}, errors.New("--stack needs a stack name after it: --stack <name>")
			}
			i++
			a.Stack = argv[i]
			stackGiven = true
		default:
			return args{}, fmt.Errorf("unknown flag: %s (%s)", arg, flagList)
		}
	}
	if a.Check && a.Apply {
		return args{}, errors.New("--check and --apply conflict: pick one")
	}
	if a.Apply && a.Stack == "" {
		return args{}, errors.New("--apply needs --stack <name>: pick a stack, or drop --apply")
	}
	if a.Help && (a.Check || a.Apply || stackGiven) {
		return args{}, errors.New("--help is shown alone: pick --help or the other flags")
	}
	return a, nil
}
