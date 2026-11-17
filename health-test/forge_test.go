// Package healthtest proves that the forge's health file (FG-FR-09, ST108) gives
// the monitor its four answers. forge.toml here is synthetic: the real file is
// written on the forge VM by compose/forge-vm/setup.sh and committed by the owner.
package healthtest

import (
	"strings"
	"testing"

	"stacks/internal/gatusconf"
	"stacks/internal/healthfile"
)

// The four answers of a stack with no dependencies: host, dependencies (n/a, a
// comment), service and right answer. Each must appear in the generated config.
func TestForgeFileGivesFourAnswers(t *testing.T) {
	stacks, probs, err := healthfile.LoadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	if len(probs) != 0 {
		t.Fatalf("forge.toml has problems: %v", probs)
	}
	if len(stacks) != 1 || stacks[0].ID != "forge" {
		t.Fatalf("want one stack named forge, got %+v", stacks)
	}
	cfg, err := gatusconf.Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		`name: "forge: host"`,
		`url: "icmp://192.0.2.10"`,
		`# forge: no dependencies declared, so its dependencies answer is n/a`,
		`name: "forge: service"`,
		`url: "tcp://192.0.2.10:3000"`,
		`name: "forge: right answer"`,
		`url: "http://192.0.2.10:3000/"`,
		`- "[STATUS] == 200"`,
	}
	for _, w := range want {
		if !strings.Contains(cfg, w) {
			t.Errorf("generated config misses %q", w)
		}
	}
	if strings.Contains(cfg, `name: "forge: dependencies`) {
		t.Errorf("a stack with no needs must not get a dependencies endpoint")
	}
}
