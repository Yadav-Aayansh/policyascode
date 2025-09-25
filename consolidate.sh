#!/usr/bin/env bash
while getopts "m:s:i:o:" opt; do
  case $opt in
    m) MODEL=$OPTARG ;; s) PROMPT=$OPTARG ;; i) INPUT=$OPTARG ;; o) OUTPUT=$OPTARG ;;
    *) echo "Usage: $0 -m MODEL -s PROMPT -i input_rules -o output_rules" >&2; exit 1 ;;
  esac
done; shift $((OPTIND-1))

SCHEMA='{
  "type": "object",
  "properties": {
    "edits": {
      "type": "array",
      "items": {
        "anyOf": [
          {
            "type": "object",
            "properties": {
              "edit": {"type": "string", "const": "delete"},
              "ids": {"type": "array", "items": {"type": "string"}, "minItems": 1},
              "reason": {"type": "string"}
            },
            "required": ["edit", "ids", "reason"],
            "additionalProperties": false
          },
          {
            "type": "object",
            "properties": {
              "edit": {"type": "string", "const": "merge"},
              "ids": {"type": "array", "items": {"type": "string"}, "minItems": 2},
              "title": {"type": "string", "description": "2-8 word summary of body"},
              "body": {"type": "string", "description": "Merge .body of merged items"},
              "priority": {"type": "string", "enum": ["low", "medium", "high"]},
              "rationale": {"type": "string", "description": "Merge .rationale of merged items"},
              "reason": {"type": "string", "description": "Explain reason for merging"}
            },
            "required": ["edit", "ids", "title", "body", "priority", "rationale", "reason"],
            "additionalProperties": false
          }
        ]
      }
    }
  },
  "required": ["edits"],
  "additionalProperties": false
}'

rules=$(jq -s -c '.[0].rules // .' < "$INPUT" | jq -c 'to_entries|map(.value+{id:"rule-"+(.key|tostring)})')
edits=$(echo "$rules" | llm -m "$MODEL" -s "$PROMPT" --schema "$SCHEMA" | jq -c '.edits // []')

if [ "$(jq 'length' <<< "$edits")" -eq 0 ]; then
  jq -c '.[]|del(.id)' <<< "$rules" > "$OUTPUT"
  echo "No consolidation edits suggested" >&2
else
  jq -c --argjson edits "$edits" '
    . as $rules
    | ($edits|map(select(.edit=="delete" or .edit=="merge")|.ids[])|flatten) as $to_delete
    | ($edits|map(select(.edit=="merge"))|map({title,body,priority,rationale,quotes:[$rules[]|select(.id as $rid|any($edits[];.edit=="merge" and (.ids|contains([$rid]))))|.quotes[]? // empty]})) as $merged
    | ([$rules[]|select(.id as $rid|($to_delete|index($rid)|not))]+$merged)[]|del(.id)
  ' <<< "$rules" > "$OUTPUT"
  echo "Applied $(jq 'length' <<< "$edits") edits -> $(wc -l < "$OUTPUT") rules saved to $OUTPUT" >&2
fi
