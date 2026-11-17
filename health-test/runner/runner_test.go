// Package runnertest proves that the runner's health file (FG-FR-09, ST109) gives
// the monitor its four answers, and that its one dependency is the forge. Both
// files here are synthetic (documentation addresses); the real runner file is not
// written yet.
package runnertest

import (
	"strings"
	"testing"

	"stacks/internal/gatusconf"
	"stacks/internal/healthfile"
)

// The runner has four answers and one dependency, forge. Each must appear in the
// generated config, and nothing may depend on anything else.
func TestRunnerFileGivesFourAnswers(t *testing.T) {
	stacks, probs, err := healthfile.LoadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	if len(probs) != 0 {
		t.Fatalf("health files have problems: %v", probs)
	}
	if len(stacks) != 2 {
		t.Fatalf("want two stacks (forge, runner), got %+v", stacks)
	}
	var runner healthfile.Stack
	for _, st := range stacks {
		if st.ID == "runner" {
			runner = st
		}
	}
	if runner.ID != "runner" {
		t.Fatalf("no runner stack in %+v", stacks)
	}
	if len(runner.Needs) != 1 || runner.Needs[0] != "forge" {
		t.Fatalf("runner must need exactly forge, got %v", runner.Needs)
	}
	cfg, err := gatusconf.Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		`name: "runner: host"`,
		`url: "icmp://192.0.2.11"`,
		`name: "runner: dependencies (forge)"`,
		`url: "tcp://192.0.2.10:3000"`,
		`name: "runner: service"`,
		`url: "tcp://192.0.2.11:8080"`,
		`name: "runner: right answer"`,
		`url: "http://192.0.2.11:8080/"`,
		`- "[STATUS] == 200"`,
	}
	for _, w := range want {
		if !strings.Contains(cfg, w) {
			t.Errorf("generated config misses %q", w)
		}
	}
}
