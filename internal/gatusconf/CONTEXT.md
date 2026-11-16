# gatusconf

Owns writing the Gatus config from the stacks' health files (HL-FR-01, HL-FR-06): four endpoints per stack, the phone alert with `${NTFY_URL}` and `${NTFY_TOPIC}` placeholders, and a fixed output so it is the same bytes on every run.

Does not own: reading or checking the health files (`internal/healthfile`), running Gatus, the compose file, or any topic or token (HL-NFR-02). Not checked against a running Gatus; the next story starts it.
