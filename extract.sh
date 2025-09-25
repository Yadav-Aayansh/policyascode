#!/usr/bin/env bash
while getopts "m:s:" opt; do
  case $opt in
    m) MODEL=$OPTARG ;;
    s) PROMPT=$OPTARG ;;
    *) echo "Usage: $0 -m MODEL -s \"PROMPT\" files..." >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

SCHEMA='{
  "type":"object",
  "properties":{"rules":{"type":"array","items":{
    "type":"object",
    "properties":{
      "title":{"type":"string","description":"2-8 word summary of body"},
      "body":{"type":"string"},
      "priority":{"type":"string","enum":["low","medium","high"]},
      "rationale":{"type":"string"},
      "quotes":{"type":"array","items":{"type":"string"}}
    },
    "required":["title","body","priority","rationale","quotes"],
    "additionalProperties":false
  }}},
  "required":["rules"],
  "additionalProperties":false
}'

for f in "$@"; do
  llm -m "$MODEL" -s "$PROMPT" --schema "$SCHEMA" < "$f" \
  | jq -c '.rules[] | {title, body, priority, rationale, quotes}'
done
