# Policy as Code CLI

Extract, consolidate, and validate atomic rules from policy documents using LLMs.

## Installation

```bash
# Make executable
chmod +x policyascode.sh

# Optional: Add to PATH
sudo ln -s $(pwd)/policyascode.sh /usr/local/bin/policyascode
```

## Quick Start

```bash
# Configure API
policyascode config --api-key sk-... --base-url https://openrouter.ai/api/v1

# Extract rules from documents
policyascode extract -o rules.json policy.md contract.pdf

# Consolidate duplicates
policyascode consolidate -i rules.json -o consolidated.json

# Validate compliance
policyascode validate -r consolidated.json document.md
```

## Commands

| Command | Purpose | Example |
|---------|---------|---------|
| `extract` | Extract atomic rules from documents | `policyascode extract -o rules.json policy.md` |
| `consolidate` | Remove duplicates and merge similar rules | `policyascode consolidate -i rules.json -o clean.json` |
| `validate` | Check document compliance against rules | `policyascode validate -r rules.json doc.md` |
| `config` | Set API credentials and preferences | `policyascode config --api-key sk-...` |

## Configuration

Set via environment variables or config command:
- `OPENAI_API_KEY` - API key
- `POLICYASCODE_BASE_URL` - API endpoint (default: OpenRouter)
- `POLICYASCODE_MODEL` - LLM model (default: gpt-4o-mini)

Config stored in `~/.policyascode/config`

## Supported Formats

- **Input**: Markdown (`.md`), Text (`.txt`), PDF (`.pdf`)
- **Output**: JSON with structured rule data

## Rule Structure

```json
{
  "id": "rule-1",
  "title": "Brief rule summary",
  "body": "Detailed rule description",
  "priority": "high|medium|low",
  "rationale": "Why this rule exists",
  "source_file": "policy.md",
  "sources": [{"quote": "Original text"}]
}
```

## Examples

### Extract from multiple sources
```bash
policyascode extract -o all-rules.json \
  security-policy.md \
  compliance-doc.pdf \
  guidelines.txt
```

### Custom prompts
```bash
policyascode extract \
  --extraction-prompt "Focus on security requirements only" \
  -o security-rules.json policy.md
```

### Validation with output
```bash
policyascode validate \
  -r rules.json \
  -o validation-report.json \
  implementation.md
```

## Requirements

- Bash 4.0+
- `jq` for JSON processing
- `curl` for API calls
- `base64` for PDF handling
