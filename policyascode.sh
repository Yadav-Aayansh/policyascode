#!/usr/bin/env bash

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration
DEFAULT_MODEL="openai/gpt-4o-mini"
DEFAULT_BASE_URL="https://openrouter.ai/api/v1"
CONFIG_FILE="$HOME/.policyascode/config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show usage information
show_usage() {
    cat << EOF
Policy as Code CLI - Extract and consolidate atomic rules from policy documents

USAGE:
    policyascode <command> [options]

COMMANDS:
    extract      Extract atomic rules from policy documents
    consolidate  Consolidate rules by removing duplicates and merging similar ones
    validate     Validate documents against extracted rules
    config       Configure API settings

GLOBAL OPTIONS:
    --model <model>        LLM model to use (default: $DEFAULT_MODEL)
    --base-url <url>       API base URL (default: $DEFAULT_BASE_URL)
    --api-key <key>        API key (can also use OPENAI_API_KEY env var)
    --help, -h             Show this help message

EXAMPLES:
    # Configure API settings
    policyascode config --api-key sk-... --base-url https://openrouter.ai/api/v1

    # Extract rules from policy documents
    policyascode extract --output rules.json policy1.md policy2.pdf

    # Use custom extraction prompt
    policyascode extract --extraction-prompt "Extract specific rules..." --output rules.json policy.md

    # Consolidate existing rules
    policyascode consolidate --input rules.json --output consolidated.json

    # Validate documents against rules
    policyascode validate --rules rules.json document1.md document2.pdf

For more information on each command, use: policyascode <command> --help
EOF
}

# Show extract command usage
show_extract_usage() {
    cat << EOF
Extract atomic rules from policy documents

USAGE:
    policyascode extract [options] <input-files...>

OPTIONS:
    --output, -o <file>           Output JSON file for extracted rules (required)
    --extraction-prompt <text>    Custom extraction prompt
    --model <model>              LLM model to use
    --base-url <url>             API base URL
    --api-key <key>              API key
    --help, -h                   Show this help message

EXAMPLES:
    policyascode extract -o rules.json policy.md
    policyascode extract --extraction-prompt "Extract compliance rules..." -o rules.json policy1.md policy2.pdf
EOF
}

# Show consolidate command usage
show_consolidate_usage() {
    cat << EOF
Consolidate rules by removing duplicates and merging similar ones

USAGE:
    policyascode consolidate [options]

OPTIONS:
    --input, -i <file>            Input JSON file with rules (required)
    --output, -o <file>           Output JSON file for consolidated rules (required)
    --consolidation-prompt <text> Custom consolidation prompt
    --model <model>              LLM model to use
    --base-url <url>             API base URL
    --api-key <key>              API key
    --help, -h                   Show this help message

EXAMPLES:
    policyascode consolidate -i rules.json -o consolidated.json
    policyascode consolidate --consolidation-prompt "Merge similar rules..." -i rules.json -o consolidated.json
EOF
}

# Show validate command usage
show_validate_usage() {
    cat << EOF
Validate documents against extracted rules

USAGE:
    policyascode validate [options] <input-files...>

OPTIONS:
    --rules, -r <file>           JSON file with rules to validate against (required)
    --output, -o <file>          Output JSON file for validation results
    --validation-prompt <text>   Custom validation prompt
    --model <model>             LLM model to use
    --base-url <url>            API base URL
    --api-key <key>             API key
    --help, -h                  Show this help message

EXAMPLES:
    policyascode validate -r rules.json document.md
    policyascode validate -r rules.json -o validation.json document1.md document2.pdf
EOF
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

# Save configuration
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Policy as Code CLI Configuration
POLICYASCODE_API_KEY="$API_KEY"
POLICYASCODE_BASE_URL="$BASE_URL"
POLICYASCODE_MODEL="$MODEL"
EOF
    log_success "Configuration saved to $CONFIG_FILE"
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
            # For PDF files, we'll use base64 encoding (similar to the web version)
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

# Make API call to LLM
call_llm() {
    local instructions="$1"
    local input_content="$2"
    local schema="$3"
    local schema_name="$4"
    
    # Extract text content from input_content
    local text_content
    text_content=$(echo "$input_content" | jq -r '.text // .file_data // ""')
    
    # Clean text content of problematic characters
    text_content=$(echo "$text_content" | tr -d '\000-\037' | tr -d '\177-\377')
    
    # Add schema description to the instructions
    local enhanced_instructions="$instructions

Please respond with valid JSON matching this schema:
$(echo "$schema" | jq -c .)"
    
    local request_body
    request_body=$(jq -n \
        --arg model "$MODEL" \
        --arg enhanced_instructions "$enhanced_instructions" \
        --arg text_content "$text_content" \
        '{
            model: $model,
            messages: [
                {
                    "role": "system",
                    "content": $enhanced_instructions
                },
                {
                    "role": "user", 
                    "content": $text_content
                }
            ],
            response_format: {
                "type": "json_object"
            },
            stream: false
        }')
    
    log_info "Making API call to $BASE_URL/chat/completions..."
    log_info "Using model: $MODEL"
    
    local response
    response=$(curl -s -X POST "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "HTTP-Referer: policyascode-cli" \
        -H "X-Title: Policy as Code CLI" \
        -d "$request_body")
    
    if [[ $? -ne 0 ]]; then
        log_error "API call failed"
        return 1
    fi
    
    # Check for errors in response
    local error
    error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        log_error "API Error: $error"
        local error_code
        error_code=$(echo "$response" | jq -r '.error.code // empty')
        if [[ -n "$error_code" ]]; then
            log_error "Error code: $error_code"
        fi
        return 1
    fi
    
    # Extract content from response
    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$content" || "$content" == "null" ]]; then
        log_error "No content returned from API"
        return 1
    fi
    
    # Clean and validate JSON before returning
    local cleaned_content
    cleaned_content=$(echo "$content" | tr -d '\000-\037' | tr -d '\177-\377')
    
    # Validate JSON structure
    if ! echo "$cleaned_content" | jq empty 2>/dev/null; then
        log_error "Invalid JSON returned from API"
        log_error "Content: $cleaned_content"
        return 1
    fi
    
    echo "$cleaned_content"
}

# Load JSON schemas
load_schemas() {
    local config_file="$SCRIPT_DIR/config.json"
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        log_error "Please ensure config.json exists in the same directory as this script"
        return 1
    fi
    
    RULES_SCHEMA=$(jq '.schemas.rules' "$config_file")
    EDITS_SCHEMA=$(jq '.schemas.edits' "$config_file")
    VALIDATION_SCHEMA=$(jq '.schemas.validation' "$config_file")
    
    if [[ "$RULES_SCHEMA" == "null" ]]; then
        log_error "Rules schema not found in config file"
        return 1
    fi
    
    if [[ "$EDITS_SCHEMA" == "null" ]]; then
        log_error "Edits schema not found in config file"
        return 1
    fi
    
    if [[ "$VALIDATION_SCHEMA" == "null" ]]; then
        log_error "Validation schema not found in config file"
        return 1
    fi
}

# Extract command
cmd_extract() {
    local output_file=""
    local extraction_prompt="Extract atomic, testable rules from this policy document.
Keep each rule minimal.
Write for an LLM to apply it unambiguously.
Always include concise rationale and quotes.
Each rule should be specific to this document and its context."
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
    
    load_schemas
    
    local all_rules="[]"
    local rule_index=0
    
    for file in "${input_files[@]}"; do
        log_info "Processing file: $file"
        
        local content
        content=$(get_file_content "$file")
        if [[ $? -ne 0 ]]; then
            continue
        fi
        
        local response
        response=$(call_llm "$extraction_prompt" "$content" "$RULES_SCHEMA" "rules")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to process $file"
            continue
        fi
        
        # Parse response and add rule IDs and source file info
        local rules
        rules=$(echo "$response" | jq --arg source_file "$(basename "$file")" --argjson start_index "$rule_index" '
            if .rules then
                .rules | to_entries | map(
                    .value + {
                        id: ("rule-" + (($start_index + .key) | tostring)),
                        source_file: $source_file
                    }
                )
            else
                []
            end
        ')
        
        if [[ "$rules" != "null" && "$rules" != "[]" ]]; then
            local rule_count
            rule_count=$(echo "$rules" | jq 'length')
            rule_index=$((rule_index + rule_count))
            
            # Merge with existing rules
            all_rules=$(echo "$all_rules" | jq --argjson new_rules "$rules" '. + $new_rules')
            
            log_success "Extracted $rule_count rules from $file"
        else
            log_warn "No rules extracted from $file"
        fi
    done
    
    # Save results
    echo "$all_rules" | jq '{rules: .}' > "$output_file"
    
    local total_rules
    total_rules=$(echo "$all_rules" | jq 'length')
    log_success "Extracted $total_rules total rules to $output_file"
}

# Consolidate command
cmd_consolidate() {
    local input_file=""
    local output_file=""
    local consolidation_prompt="Suggest deletes and merges to remove duplicates and generalize rules where appropriate."
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --input|-i)
                input_file="$2"
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
    
    if [[ -z "$input_file" ]]; then
        log_error "Input file is required"
        show_consolidate_usage
        return 1
    fi
    
    if [[ -z "$output_file" ]]; then
        log_error "Output file is required"
        show_consolidate_usage
        return 1
    fi
    
    if [[ ! -f "$input_file" ]]; then
        log_error "Input file not found: $input_file"
        return 1
    fi
    
    load_schemas
    
    log_info "Loading rules from $input_file"
    local rules
    rules=$(jq '.rules' "$input_file")
    
    if [[ "$rules" == "null" || "$rules" == "[]" ]]; then
        log_error "No rules found in input file"
        return 1
    fi
    
    local rules_content
    rules_content=$(jq -n --argjson rules "$rules" '{"type": "input_text", "text": ($rules | tostring)}')
    
    log_info "Consolidating rules..."
    local response
    response=$(call_llm "$consolidation_prompt" "$rules_content" "$EDITS_SCHEMA" "edits")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to consolidate rules"
        return 1
    fi
    
    local edits
    edits=$(echo "$response" | jq '.edits // []')
    
    # Validate that edits is valid JSON array
    if [[ "$edits" == "null" || "$edits" == "[]" ]] || ! echo "$edits" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_info "No consolidation edits suggested"
        cp "$input_file" "$output_file"
        return 0
    fi
    
    # Apply edits to rules
    local consolidated_rules
    consolidated_rules=$(echo "$rules" | jq -c --argjson edits "$edits" '
        # Create lookup for rules by ID
        . as $all_rules |
        (reduce $all_rules[] as $rule ({}; .[$rule.id] = $rule)) as $rule_lookup |
        
        # Collect IDs to delete
        ([$edits[] | select(.edit == "delete" or .edit == "merge") | .ids[]] | unique) as $to_delete |
        
        # Filter out deleted rules
        [$all_rules[] | select(.id as $id | $to_delete | index($id) | not)] as $remaining |
        
        # Add merged rules
        ([$edits[] | select(.edit == "merge") | {
            id: ("rule-merged-" + (.ids | join("-"))),
            title: .title,
            body: .body,
            priority: .priority,
            rationale: .rationale,
            source_files: ([.ids[] | $rule_lookup[.].source_file // empty] | unique | select(length > 0)),
            sources: ([.ids[] | ($rule_lookup[.].sources // [])[] // empty] | unique | select(length > 0))
        } | if (.source_files | length) > 0 then 
            . + {source_file: (.source_files | join(", "))} | del(.source_files)
        else 
            . + {source_file: "merged"} | del(.source_files)
        end]) as $merged_rules |
        
        # Combine remaining and merged rules
        $remaining + $merged_rules
    ')
    
    # Save consolidated rules
    echo "$consolidated_rules" | jq '{rules: .}' > "$output_file"
    
    local edit_count
    edit_count=$(echo "$edits" | jq 'length')
    local final_count
    final_count=$(echo "$consolidated_rules" | jq 'length')
    
    log_success "Applied $edit_count consolidation edits, resulting in $final_count rules saved to $output_file"
}

# Validate command
cmd_validate() {
    local rules_file=""
    local output_file=""
    local validation_prompt="Validate the provided document against the given rules that originated from this same document.

For each rule, determine if the document passes, fails, is not applicable, or if it's unknown/unclear.

Return a validation result for each rule with:
- id: the rule identifier
- result: \"pass\" if the document complies, \"fail\" if it violates the rule, \"n/a\" if the rule is not applicable to this document, \"unknown\" if unclear or needs human review
- reason: brief explanation of why it passes, fails, is not applicable, or is unknown

Be specific and cite relevant parts of the document in your reasoning.

Only validate rules that were originally extracted from this document or are applicable to it."
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
    
    if [[ ! -f "$rules_file" ]]; then
        log_error "Rules file not found: $rules_file"
        return 1
    fi
    
    load_schemas
    
    local rules
    rules=$(jq '.rules' "$rules_file")
    
    if [[ "$rules" == "null" || "$rules" == "[]" ]]; then
        log_error "No rules found in rules file"
        return 1
    fi
    
    local all_validations="[]"
    
    for file in "${input_files[@]}"; do
        log_info "Validating file: $file"
        
        local filename="$(basename "$file")"
        
        # Filter rules to only those from this source file or merged rules that include this file
        local applicable_rules
        applicable_rules=$(echo "$rules" | jq --arg filename "$filename" '
            map(select(
                .source_file == $filename or 
                (.source_file | contains($filename)) or
                (.source_files[]? // empty | . == $filename)
            ))
        ')
        
        local rule_count
        rule_count=$(echo "$applicable_rules" | jq 'length')
        
        if [[ "$rule_count" -eq 0 ]]; then
            log_warn "No applicable rules found for $file"
            continue
        fi
        
        log_info "Found $rule_count applicable rules for $file"
        
        local content
        content=$(get_file_content "$file")
        if [[ $? -ne 0 ]]; then
            continue
        fi
        
        local full_prompt="$validation_prompt

Rules to validate against:
$(echo "$applicable_rules" | jq -c .)"
        
        local response
        response=$(call_llm "$full_prompt" "$content" "$VALIDATION_SCHEMA" "validation")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to validate $file"
            continue
        fi
        
        # Parse response and add file name
        local validations
        validations=$(echo "$response" | jq -c --arg file "$filename" '
            try (
                if .validations then
                    .validations | map(. + {file: $file})
                else
                    []
                end
            ) catch []
        ')
        
        if [[ "$validations" != "null" && "$validations" != "[]" ]]; then
            local validation_count
            validation_count=$(echo "$validations" | jq 'length')
            
            # Merge with existing validations
            all_validations=$(echo "$all_validations" | jq --argjson new_validations "$validations" '. + $new_validations')
            
            log_success "Validated $validation_count applicable rules against $file"
        else
            log_warn "No validations returned for $file"
        fi
    done
    
    # Save or display results
    if [[ -n "$output_file" ]]; then
        echo "$all_validations" | jq '{validations: .}' > "$output_file"
        log_success "Validation results saved to $output_file"
    else
        # Display results in a readable format
        echo "$all_validations" | jq -r '
            group_by(.file) | .[] | 
            "\n=== Validation Results for " + .[0].file + " ===\n" +
            (map("  " + .id + ": " + .result + " - " + .reason) | join("\n")) +
            "\n  Total: " + (length | tostring) + " rules validated"
        '
    fi
}

# Config command
cmd_config() {
    local show_config=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --base-url)
                BASE_URL="$2"
                shift 2
                ;;
            --model)
                MODEL="$2"
                shift 2
                ;;
            --show)
                show_config=true
                shift
                ;;
            --help|-h)
                cat << EOF
Configure API settings

USAGE:
    policyascode config [options]

OPTIONS:
    --api-key <key>      Set API key
    --base-url <url>     Set API base URL
    --model <model>      Set default model
    --show               Show current configuration
    --help, -h           Show this help message

EXAMPLES:
    policyascode config --api-key sk-... --base-url https://openrouter.ai/api/v1
    policyascode config --show
EOF
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                return 1
                ;;
        esac
    done
    
    if [[ "$show_config" == true ]]; then
        echo "Current configuration:"
        echo "  API Key: ${API_KEY:0:10}..." 
        echo "  Base URL: $BASE_URL"
        echo "  Model: $MODEL"
        echo "  Config file: $CONFIG_FILE"
        return 0
    fi
    
    save_config
}

# Main function
main() {
    # Load configuration
    load_config
    
    # Set defaults
    MODEL="${POLICYASCODE_MODEL:-$DEFAULT_MODEL}"
    BASE_URL="${POLICYASCODE_BASE_URL:-$DEFAULT_BASE_URL}"
    API_KEY="${POLICYASCODE_API_KEY:-${OPENAI_API_KEY:-}}"
    
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --model)
                MODEL="$2"
                shift 2
                ;;
            --base-url)
                BASE_URL="$2"
                shift 2
                ;;
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                return 0
                ;;
            extract|consolidate|validate|config)
                local command="$1"
                shift
                break
                ;;
            -*)
                log_error "Unknown global option: $1"
                show_usage
                return 1
                ;;
            *)
                log_error "Unknown command: $1"
                show_usage
                return 1
                ;;
        esac
    done
    
    if [[ -z "${command:-}" ]]; then
        log_error "No command specified"
        show_usage
        return 1
    fi
    
    # Check API key for commands that need it
    if [[ "$command" != "config" && -z "$API_KEY" ]]; then
        log_error "API key is required. Set it using:"
        log_error "  policyascode config --api-key <your-key>"
        log_error "  or set OPENAI_API_KEY environment variable"
        return 1
    fi
    
    # Execute command
    case $command in
        extract)
            cmd_extract "$@"
            ;;
        consolidate)
            cmd_consolidate "$@"
            ;;
        validate)
            cmd_validate "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            return 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
