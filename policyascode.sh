#!/bin/bash

set -euo pipefail

# Configuration
CONFIG_FILE="config.json"
DEFAULT_MODEL="claude-3-5-sonnet-20241022"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Get schema from config
get_schema() {
    local schema_name="$1"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        return 1
    fi
    jq -r ".schemas.$schema_name" "$CONFIG_FILE"
}

# Generate unique rule ID
generate_rule_id() {
    echo "rule_$(date +%s)_$(openssl rand -hex 4)"
}

# Call Claude API
call_claude() {
    local system_prompt="$1"
    local user_content="$2"
    local model="${3:-$DEFAULT_MODEL}"
    local schema="${4:-}"
    
    local messages='[{"role": "user", "content": '"$(jq -Rs . <<< "$user_content")"'}]'
    
    local request_body=$(jq -n \
        --arg model "$model" \
        --arg system "$system_prompt" \
        --argjson messages "$messages" \
        --argjson schema "$schema" \
        '{
            model: $model,
            max_tokens: 8192,
            system: $system,
            messages: $messages
        } + (if $schema != null and $schema != "" then {
            tools: [{
                type: "function",
                function: {
                    name: "provide_output",
                    description: "Provide structured output",
                    parameters: ($schema | fromjson)
                }
            }],
            tool_choice: {
                type: "function",
                function: { name: "provide_output" }
            }
        } else {} end)')
    
    log_debug "Request body: $request_body"
    
    local response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: prompt-caching-2024-07-31,pdfs-2024-09-25,computer-use-2024-10-22" \
        -d "$request_body")
    
    log_debug "Response: $response"
    
    # Check for errors
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_error "API Error: $(echo "$response" | jq -r '.error.message')"
        return 1
    fi
    
    # Extract the function call result if using schema
    if [[ -n "$schema" ]]; then
        echo "$response" | jq -r '.content[0].input // .content[0].text // .content[0]'
    else
        echo "$response" | jq -r '.content[0].text'
    fi
}

# Get file content based on file type
get_file_content() {
    local file="$1"
    local filename="$(basename "$file")"
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    case "${file,,}" in
        *.pdf)
            # For PDF files, we'll use base64 encoding
            local base64_data="data:application/pdf;base64,$(base64 -w 0 "$file")"
            jq -n --arg filename "$filename" --arg data "$base64_data" \
                '{"type": "input_file", "filename": $filename, "file_data": $data}'
            ;;
        *.md|*.txt|*)
            # For text files
            local content="# $filename\n\n$(cat "$file")"
            jq -n --arg text "$content" '{"type": "input_text", "text": $text}'
            ;;
    esac
}

# Extract command
cmd_extract() {
    local output_file=""
    local extraction_prompt="Extract atomic, testable rules from ONE policy document.
Keep each rule minimal.
Write for an LLM to apply it unambiguously.
Always include concise rationale and quotes.
Generate unique IDs for each rule.
Include the source filename in source_files array and in each quote's file field."
    local input_files=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output|-o)
                output_file="$2"
                shift 2
                ;;
            --extraction-prompt)
                extraction_prompt="$2"
                shift 2
                ;;
            --help|-h)
                show_extract_usage
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_extract_usage
                return 1
                ;;
            *)
                input_files+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ -z "$output_file" ]]; then
        log_error "Output file is required"
        show_extract_usage
        return 1
    fi
    
    if [[ ${#input_files[@]} -eq 0 ]]; then
        log_error "At least one input file is required"
        show_extract_usage
        return 1
    fi
    
    local schema=$(get_schema "rules")
    local all_rules='{"rules": []}'
    
    for file in "${input_files[@]}"; do
        log_info "Extracting rules from: $file"
        local filename="$(basename "$file")"
        local content=$(get_file_content "$file")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to read file: $file"
            continue
        fi
        
        local user_content="Extract rules from this document. Each rule should have source_files: [\"$filename\"] and quotes should include file: \"$filename\".

$content"
        
        local result=$(call_claude "$extraction_prompt" "$user_content" "$DEFAULT_MODEL" "$schema")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to extract rules from: $file"
            continue
        fi
        
        # Add unique IDs if not present and ensure source_files is set
        local rules_with_ids=$(echo "$result" | jq --arg filename "$filename" '.rules |= map(
            if .id == null or .id == "" then .id = ("rule_" + (now | tostring) + "_" + (. | tostring | @base64 | .[0:8])) else . end |
            if .source_files == null or .source_files == [] then .source_files = [$filename] else . end |
            if .sources then .sources |= map(if .file == null or .file == "" then .file = $filename else . end) else . end
        )')
        
        # Merge rules
        all_rules=$(echo "$all_rules" "$rules_with_ids" | jq -s '.[0] * {rules: (.[0].rules + .[1].rules)}')
        
        log_info "Extracted $(echo "$rules_with_ids" | jq '.rules | length') rules from $file"
    done
    
    # Save to output file
    echo "$all_rules" | jq '.' > "$output_file"
    log_info "Saved $(echo "$all_rules" | jq '.rules | length') total rules to $output_file"
}

# Consolidate command
cmd_consolidate() {
    local rules_file=""
    local output_file=""
    local consolidation_prompt="Review rules and identify opportunities to:
1. Delete redundant rules
2. Merge similar rules (combining their source_files arrays)
Be conservative. Only suggest edits that clearly improve the ruleset.
When merging, combine all source_files from the merged rules."
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --rules|-r)
                rules_file="$2"
                shift 2
                ;;
            --output|-o)
                output_file="$2"
                shift 2
                ;;
            --consolidation-prompt)
                consolidation_prompt="$2"
                shift 2
                ;;
            --help|-h)
                show_consolidate_usage
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_consolidate_usage
                return 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                show_consolidate_usage
                return 1
                ;;
        esac
    done
    
    if [[ -z "$rules_file" ]] || [[ -z "$output_file" ]]; then
        log_error "Both rules file and output file are required"
        show_consolidate_usage
        return 1
    fi
    
    log_info "Consolidating rules from: $rules_file"
    
    local rules_content=$(cat "$rules_file")
    local schema=$(get_schema "edits")
    
    local user_content="Review these rules and suggest edits (delete or merge only):

$rules_content

When merging rules, ensure the source_files array contains all unique source files from the rules being merged."
    
    local edits=$(call_claude "$consolidation_prompt" "$user_content" "$DEFAULT_MODEL" "$schema")
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get consolidation suggestions"
        return 1
    fi
    
    log_info "Applying edits..."
    
    # Apply edits to rules
    local updated_rules=$(echo "$rules_content" | jq --argjson edits "$edits" '
        . as $original |
        $edits.edits | reduce .[] as $edit ($original;
            if $edit.edit == "delete" then
                .rules |= map(select(.id as $id | $edit.ids | index($id) | not))
            elif $edit.edit == "merge" then
                # Get all rules being merged
                (.rules | map(select(.id as $id | $edit.ids | index($id)))) as $merged_rules |
                # Combine source_files from all merged rules
                ($merged_rules | map(.source_files // []) | flatten | unique) as $combined_sources |
                # Remove old rules
                .rules |= map(select(.id as $id | $edit.ids | index($id) | not)) |
                # Add merged rule with combined sources
                .rules += [{
                    id: ("merged_" + (now | tostring) + "_" + ($edit.ids | join("_") | .[0:20])),
                    title: $edit.title,
                    body: $edit.body,
                    priority: $edit.priority,
                    rationale: $edit.rationale,
                    source_files: ($edit.source_files // $combined_sources),
                    sources: ($merged_rules | map(.sources // []) | flatten)
                }]
            else
                .
            end
        )
    ')
    
    echo "$updated_rules" | jq '.' > "$output_file"
    
    local original_count=$(echo "$rules_content" | jq '.rules | length')
    local new_count=$(echo "$updated_rules" | jq '.rules | length')
    
    log_info "Consolidation complete: $original_count rules → $new_count rules"
    log_info "Saved to: $output_file"
}

# Validate command
cmd_validate() {
    local rules_file=""
    local output_file=""
    local validation_prompt="Check if the document complies with each rule that was extracted from this specific document.
Only validate rules that have this document in their source_files array.
Be specific and cite relevant parts of the document in your reasoning."
    local input_files=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --rules|-r)
                rules_file="$2"
                shift 2
                ;;
            --output|-o)
                output_file="$2"
                shift 2
                ;;
            --validation-prompt)
                validation_prompt="$2"
                shift 2
                ;;
            --help|-h)
                show_validate_usage
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_validate_usage
                return 1
                ;;
            *)
                input_files+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ -z "$rules_file" ]]; then
        log_error "Rules file is required"
        show_validate_usage
        return 1
    fi
    
    if [[ ${#input_files[@]} -eq 0 ]]; then
        log_error "At least one input file is required"
        show_validate_usage
        return 1
    fi
    
    local rules=$(cat "$rules_file")
    local schema=$(get_schema "validation")
    local all_validations='{"validations": []}'
    
    for file in "${input_files[@]}"; do
        log_info "Validating: $file"
        local filename="$(basename "$file")"
        local content=$(get_file_content "$file")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to read file: $file"
            continue
        fi
        
        # Filter rules to only those from this source file
        local relevant_rules=$(echo "$rules" | jq --arg filename "$filename" '
            .rules |= map(select(.source_files | index($filename)))
        ')
        
        local rule_count=$(echo "$relevant_rules" | jq '.rules | length')
        
        if [[ "$rule_count" -eq 0 ]]; then
            log_warning "No rules found for file: $filename"
            continue
        fi
        
        log_info "Checking $rule_count rules relevant to $filename"
        
        local user_content="Validate this document against the following rules (only those from this source):

RULES (from $filename):
$relevant_rules

DOCUMENT TO VALIDATE:
$content

For each rule, set file: \"$filename\" in the validation result."
        
        local result=$(call_claude "$validation_prompt" "$user_content" "$DEFAULT_MODEL" "$schema")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to validate: $file"
            continue
        fi
        
        # Ensure file field is set in validations
        local validations_with_file=$(echo "$result" | jq --arg filename "$filename" '
            .validations |= map(if .file == null or .file == "" then .file = $filename else . end)
        ')
        
        # Merge validations
        all_validations=$(echo "$all_validations" "$validations_with_file" | jq -s '
            .[0] * {validations: (.[0].validations + .[1].validations)}
        ')
        
        local compliant=$(echo "$validations_with_file" | jq '[.validations[] | select(.compliance == "compliant")] | length')
        local non_compliant=$(echo "$validations_with_file" | jq '[.validations[] | select(.compliance == "non-compliant")] | length')
        
        log_info "Results for $filename: ✓ $compliant compliant, ✗ $non_compliant non-compliant"
    done
    
    # Save results
    if [[ -n "$output_file" ]]; then
        echo "$all_validations" | jq '.' > "$output_file"
        log_info "Validation results saved to: $output_file"
    else
        echo "$all_validations" | jq '.'
    fi
    
    # Summary
    local total_compliant=$(echo "$all_validations" | jq '[.validations[] | select(.compliance == "compliant")] | length')
    local total_non_compliant=$(echo "$all_validations" | jq '[.validations[] | select(.compliance == "non-compliant")] | length')
    local total_partial=$(echo "$all_validations" | jq '[.validations[] | select(.compliance == "partially-compliant")] | length')
    
    log_info "Overall Summary: ✓ $total_compliant compliant, ✗ $total_non_compliant non-compliant, ⚠ $total_partial partially-compliant"
}

# Usage information
show_usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    extract       Extract rules from policy documents
    consolidate   Consolidate and deduplicate rules
    validate      Validate documents against rules

Global Options:
    --help, -h    Show this help message

Environment Variables:
    ANTHROPIC_API_KEY    Required: Your Anthropic API key
    DEBUG               Set to 1 for debug output

Examples:
    # Extract rules from multiple documents
    $0 extract policy1.pdf policy2.md -o rules.json
    
    # Consolidate rules
    $0 consolidate -r rules.json -o consolidated_rules.json
    
    # Validate documents against rules
    $0 validate -r consolidated_rules.json document.pdf -o validation_results.json

EOF
}

show_extract_usage() {
    cat << EOF
Usage: $0 extract [options] <input_files...>

Extract atomic rules from policy documents.

Options:
    --output, -o <file>           Output JSON file for rules (required)
    --extraction-prompt <prompt>  Custom extraction prompt
    --help, -h                    Show this help message

Examples:
    $0 extract policy.pdf -o rules.json
    $0 extract doc1.md doc2.pdf -o combined_rules.json

EOF
}

show_consolidate_usage() {
    cat << EOF
Usage: $0 consolidate [options]

Consolidate and deduplicate extracted rules.

Options:
    --rules, -r <file>            Input rules JSON file (required)
    --output, -o <file>           Output JSON file for consolidated rules (required)
    --consolidation-prompt <prompt> Custom consolidation prompt
    --help, -h                    Show this help message

Examples:
    $0 consolidate -r rules.json -o consolidated.json

EOF
}

show_validate_usage() {
    cat << EOF
Usage: $0 validate [options] <input_files...>

Validate documents against extracted rules.

Options:
    --rules, -r <file>            Rules JSON file (required)
    --output, -o <file>           Output JSON file for validation results
    --validation-prompt <prompt>  Custom validation prompt
    --help, -h                    Show this help message

Examples:
    $0 validate -r rules.json document.pdf -o results.json
    $0 validate -r rules.json doc1.md doc2.pdf

EOF
}

# Main command dispatcher
main() {
    # Check for API key
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        log_error "ANTHROPIC_API_KEY environment variable is not set"
        echo "Please set your Anthropic API key:"
        echo "  export ANTHROPIC_API_KEY='your-api-key-here'"
        exit 1
    fi
    
    # Check for required tools
    for cmd in jq curl; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is required but not installed"
            exit 1
        fi
    done
    
    # Parse command
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi
    
    case "$1" in
        extract)
            shift
            cmd_extract "$@"
            ;;
        consolidate)
            shift
            cmd_consolidate "$@"
            ;;
        validate)
            shift
            cmd_validate "$@"
            ;;
        --help|-h|help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"