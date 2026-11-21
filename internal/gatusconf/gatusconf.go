// Package gatusconf writes the Gatus config for the stacks' health files
// (HL-FR-01, HL-FR-06). It is the only code that turns health files into checks
// (HL-NFR-01). It uses the standard library only and builds the YAML text by
// hand, so the output is the same bytes on every run.
//
// The topic and the URL of the phone alert are written as the placeholders
// ${NTFY_TOPIC} and ${NTFY_URL}; Gatus fills them from its environment, so no
// secret reaches git or the output (HL-NFR-02).
package gatusconf

import (
	"fmt"
	"strings"

	"stacks/internal/healthfile"
)

// Generate returns the Gatus config for stacks, which must be in ID order as
// healthfile.LoadDir returns them. It fails when a needs entry names a stack
// that is not in stacks, or when a stack has no expectation to check.
func Generate(stacks []healthfile.Stack) (string, error) {
	byID := map[string]healthfile.Stack{}
	for _, st := range stacks {
		byID[st.ID] = st
	}

	var b strings.Builder
	b.WriteString("# Gatus config, generated from the health files (HL-FR-06). Do not edit: change the health files.\n")
	b.WriteString("# Gatus fills ${NTFY_URL} and ${NTFY_TOPIC} from its environment (HL-NFR-02).\n\n")
	b.WriteString("alerting:\n")
	b.WriteString("  ntfy:\n")
	b.WriteString("    url: \"${NTFY_URL}\"\n")
	b.WriteString("    topic: \"${NTFY_TOPIC}\"\n\n")

	if len(stacks) == 0 {
		b.WriteString("endpoints: []\n")
		return b.String(), nil
	}
	b.WriteString("endpoints:\n")
	for _, st := range stacks {
		fmt.Fprintf(&b, "  # %s\n", st.ID)
		endpoint(&b, st, "host", "icmp://"+st.Host, "", []string{"[CONNECTED] == true"}, false)

		if len(st.Needs) == 0 {
			fmt.Fprintf(&b, "  # %s: no dependencies declared, so its dependencies answer is n/a\n", st.ID)
		}
		for _, need := range st.Needs {
			dep, ok := byID[need]
			if !ok {
				return "", fmt.Errorf("%s needs %q, which is not a stack in the health files", st.ID, need)
			}
			endpoint(&b, st, "dependencies ("+need+")", "tcp://"+dep.Service, "", []string{"[CONNECTED] == true"}, false)
		}

		endpoint(&b, st, "service", "tcp://"+st.Service, "", []string{"[CONNECTED] == true"}, false)

		conds, err := rightAnswer(st)
		if err != nil {
			return "", err
		}
		if st.DNSName != "" {
			// A DNS stack is asked its name at its DNS server, which is its service.
			endpoint(&b, st, "right answer", st.Service, st.DNSName, conds, st.Insecure)
		} else {
			endpoint(&b, st, "right answer", st.Request, "", conds, st.Insecure)
		}
	}
	return b.String(), nil
}

// rightAnswer returns the conditions for a stack's correct reply: the status
// when the file gives one, and the text when it gives one. A DNS stack's right
// answer is an answer that contains its address.
func rightAnswer(st healthfile.Stack) ([]string, error) {
	if st.DNSName != "" {
		return []string{"[BODY] == pat(*" + st.DNSExpect + "*)"}, nil
	}
	var conds []string
	if st.HasStatus {
		conds = append(conds, fmt.Sprintf("[STATUS] == %d", st.ExpectStatus))
	}
	if st.HasText {
		conds = append(conds, "[BODY] == pat(*"+st.ExpectText+"*)")
	}
	if len(conds) == 0 {
		return nil, fmt.Errorf("%s has no expect_status or expect_text", st.ID)
	}
	return conds, nil
}

// endpoint writes one Gatus endpoint for a stack: its name, `<stack>: <answer>`
// (HL-FR-01, so a search by stack or by answer finds it), the stack as its
// group, the URL to check, the conditions, and the phone alert. A non-empty
// dnsName makes it a DNS query for that name, sent to url. insecure adds the
// client block that skips certificate checks (DEV-FR-01).
func endpoint(b *strings.Builder, st healthfile.Stack, answer, url, dnsName string, conds []string, insecure bool) {
	name := st.ID + ": " + answer
	fmt.Fprintf(b, "  - name: %s\n", yamlString(name))
	fmt.Fprintf(b, "    group: %s\n", yamlString(st.ID))
	fmt.Fprintf(b, "    url: %s\n", yamlString(url))
	if dnsName != "" {
		b.WriteString("    dns:\n")
		fmt.Fprintf(b, "      query-name: %s\n", yamlString(dnsName))
		b.WriteString("      query-type: \"A\"\n")
	}
	if insecure {
		b.WriteString("    client:\n")
		b.WriteString("      insecure: true\n")
	}
	b.WriteString("    interval: 10s\n")
	b.WriteString("    conditions:\n")
	for _, c := range conds {
		fmt.Fprintf(b, "      - %s\n", yamlString(c))
	}
	b.WriteString("    alerts:\n")
	b.WriteString("      - type: ntfy\n")
	b.WriteString("        failure-threshold: 2\n")
	b.WriteString("        success-threshold: 1\n")
	b.WriteString("        send-on-resolved: true\n")
	fmt.Fprintf(b, "        description: %s\n", yamlString(name))
}

// yamlString quotes s as a YAML double-quoted scalar, escaping the backslash
// and the double quote so no text can end the string early.
func yamlString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
