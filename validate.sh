#!/usr/bin/env bash
while getopts "m:s:r:" opt; do
  case $opt in
    m) MODEL=$OPTARG ;;
    s) PROMPT=$OPTARG ;;
    r) RULES=$OPTARG ;;
    *) echo "Usage: $0 -m MODEL -s \"PROMPT\" -r rules files..." >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

SCHEMA='{
  "type": "object",
  "properties": {
    "validations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "result": {"type": "string", "enum": ["pass", "fail", "n/a", "unknown"]},
          "reason": {"type": "string"}
        },
        "required": ["id", "result", "reason"],
        "additionalProperties": false
      }
    }
  },
  "required": ["validations"],
  "additionalProperties": false
}'

full_prompt="$PROMPT\n\nRules:\n$(jq -s -c '.' < "$RULES" | jq -c 'to_entries | map(.value + {id: ("rule-" + (.key|tostring))})')"

for f in "$@"; do
  result_json=$(llm -m "$MODEL" -s "$full_prompt" --schema "$SCHEMA" < "$f")
  fname=$(basename "$f")
  echo "$result_json" | jq -r --arg fname "$fname" '
    .validations[] |
    (if .result == "pass" then "✅" elif .result == "fail" then "❌" elif .result == "n/a" then "⚪" elif .result == "unknown" then "❓" else "?" end) +
    " \($fname) :: \(.id) -> \(.result | ascii_upcase) - \(.reason)"
  '
done

