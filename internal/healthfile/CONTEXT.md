# healthfile

Owns the reading and checking of the health files in `health/` (HL-FR-06): the subset of TOML they use, the required parts, and the rule that every `needs` entry names another file. It never writes.

Does not own: generating the monitor's checks from these files (the next story), the compose file, or any running check. Cycle checks and the typed hard and soft needs of HL-FR-16 are not here yet.
