package gatusconf

import (
	"flag"
	"os"
	"regexp"
	"strings"
	"testing"

	"stacks/internal/healthfile"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata")

// The probes folder holds copies of the two OC8 test targets, probe-a and
// probe-b. probe-a has no needs.
func TestProbesGolden(t *testing.T) {
	golden(t, "testdata/probes", "testdata/probes.golden")
}

// The cases folder holds one stack with both expectations and one whose text
// has a single quote and a backslash, and one stack that needs the other.
func TestCasesGolden(t *testing.T) {
	golden(t, "testdata/cases", "testdata/cases.golden")
}

func golden(t *testing.T, dir, file string) {
	t.Helper()
	stacks, probs, err := healthfile.LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(probs) != 0 {
		t.Fatalf("fixture has problems: %v", probs)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if *update {
		if err := os.WriteFile(file, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Fatalf("output differs from %s (run go test -update to rewrite it)\n--- got ---\n%s", file, got)
	}
	again, err := Generate(stacks)
	if err != nil || again != got {
		t.Fatalf("second run differs from the first")
	}
}

// The output holds the two placeholders for the phone alert and no other topic.
func TestOnlyPlaceholderTopic(t *testing.T) {
	stacks, _, err := healthfile.LoadDir("testdata/probes")
	if err != nil {
		t.Fatal(err)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, `    url: "${NTFY_URL}"`) || !strings.Contains(got, `    topic: "${NTFY_TOPIC}"`) {
		t.Fatalf("placeholders missing:\n%s", got)
	}
	topic := regexp.MustCompile(`(?i)topic`)
	for _, line := range strings.Split(got, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if topic.MatchString(line) && strings.TrimSpace(line) != `topic: "${NTFY_TOPIC}"` {
			t.Fatalf("unexpected topic-like line: %q", line)
		}
	}
}

// A stack with no needs gets a comment in place of a dependencies endpoint.
func TestNoNeedsSaysSo(t *testing.T) {
	stacks, _, err := healthfile.LoadDir("testdata/probes")
	if err != nil {
		t.Fatal(err)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "# probe-a: no dependencies declared, so its dependencies answer is n/a") {
		t.Fatalf("no comment for probe-a's missing needs:\n%s", got)
	}
	// probe-b has the one dependencies endpoint; probe-a has none of its own.
	if n := strings.Count(got, `name: "dependencies (`); n != 1 {
		t.Fatalf("want one dependencies endpoint (probe-b's), got %d", n)
	}
}

// Quotes and backslashes in the expected text are escaped, so they cannot end
// the YAML string early.
func TestTextIsEscaped(t *testing.T) {
	st := healthfile.Stack{
		ID: "q", Host: "q", Service: "q:1", Request: "http://q:1/",
		ExpectText: `say "hi" \o/`, HasText: true,
	}
	got, err := Generate([]healthfile.Stack{st})
	if err != nil {
		t.Fatal(err)
	}
	want := `      - "[BODY] == pat(*say \"hi\" \\o/*)"`
	if !strings.Contains(got, want) {
		t.Fatalf("want %s in:\n%s", want, got)
	}
}

// A needs entry that names no stack in the list is refused, not written.
func TestUnknownNeedIsRefused(t *testing.T) {
	st := healthfile.Stack{
		ID: "x", Host: "x", Service: "x:1", Request: "r", ExpectStatus: 200, HasStatus: true,
		Needs: []string{"nope"},
	}
	if _, err := Generate([]healthfile.Stack{st}); err == nil {
		t.Fatal("want an error for a need that is not a stack")
	}
}
