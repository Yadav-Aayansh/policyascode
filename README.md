# Policy As Code

AI-powered rule extraction, consolidation, and validation toolkit using LLMs.

## Scripts

### extract.sh
Extracts structured rules from files using LLM analysis.

```bash
./extract.sh -m MODEL -s "PROMPT" file1.txt file2.txt
```

**Output**: JSON rules with title, body, priority, rationale, and quotes.

### consolidate.sh
Merges duplicate/overlapping rules to eliminate redundancy.

```bash
./consolidate.sh -m MODEL -s "PROMPT" -i input_rules.json -o output_rules.json
```

**Actions**: Delete redundant rules, merge similar ones.

### validate.sh
Validates files against established rules.

```bash
./validate.sh -m MODEL -s "PROMPT" -r rules.json file1.txt file2.txt
```

**Output**: Pass/fail status with reasons (✅❌⚪❓).

## Workflow

1. **Extract** rules from source files
2. **Consolidate** to remove duplicates
3. **Validate** target files against rules

## Requirements

- `llm` CLI tool
- `jq` for JSON processing
- LLM model access

## Schema

Rules contain: title, body, priority (low/medium/high), rationale, supporting quotes.
