#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/lib/common.sh"
source "$SCRIPT_DIR/download-flight-logs.conf"

usage() {
    cat <<'EOF'
Usage: download-flight-logs -e <env> (-s <search-id> | -t <trace-id>) [-p <profile>] [--pick] [--dry-run]

Download and extract flight logs from S3.

Options:
  -e, --env       Environment: dev, qa, uat, prod
  -s, --search    Search ID (downloads from engine-search-logs + engine-booking-logs)
  -t, --trace     Trace ID (downloads from b2b2c-logs/<env>/flightLogs/)
  -p, --profile   AWS CLI profile (optional, uses default credentials if omitted)
  -f, --pick      Multi-select zip files with fzf before extracting (skip unselected)
  -n, --dry-run   Show what would be downloaded without actually downloading
  -h, --help      Show this help message

Examples:
  download-flight-logs -e uat -s 1760192050955311027
  download-flight-logs --env=qa --trace=0005d1a6f6a417971c6d98704188fc9d
  download-flight-logs -e prod -s 1760192050955311027 -p prod-account
  download-flight-logs -e uat -s 1760192050955311027 --pick
  download-flight-logs -e uat -s 1760192050955311027 --dry-run
EOF
    exit "${1:-0}"
}

resolve_bucket() {
    local env="$1"
    if [[ "$env" == "prod" && -n "$BUCKET_PROD" ]]; then
        echo "$BUCKET_PROD"
    else
        echo "${BUCKET_PATTERN//\{env\}/$env}"
    fi
}

build_aws_cmd() {
    local cmd="aws"
    if [[ -n "$PROFILE" ]]; then
        cmd+=" --profile $PROFILE"
    fi
    echo "$cmd"
}

sync_prefix() {
    local bucket="$1" prefix="$2" dest="$3"
    local aws_cmd
    aws_cmd="$(build_aws_cmd)"
    local s3_path="s3://${bucket}/${prefix}/"

    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] Would sync $s3_path → $dest"
        $aws_cmd s3 ls "$s3_path" 2>/dev/null && return 0 || return 1
    fi

    info "Syncing $s3_path"
    if ! $aws_cmd s3 sync "$s3_path" "$dest" --quiet 2>/dev/null; then
        warn "No files found at $s3_path (or sync failed)"
        return 1
    fi
    return 0
}

list_s3_files() {
    local bucket="$1" prefix="$2"
    local aws_cmd
    aws_cmd="$(build_aws_cmd)"
    $aws_cmd s3 ls "s3://${bucket}/${prefix}/" 2>/dev/null | awk '{print $NF}' || true
}

pick_and_sync() {
    local bucket="$1" dest="$2"
    shift 2
    local prefixes=("$@")

    local files=""
    for prefix in "${prefixes[@]}"; do
        local listing
        listing="$(list_s3_files "$bucket" "$prefix")"
        if [[ -n "$listing" ]]; then
            while IFS= read -r f; do
                files+="${prefix}/${f}"$'\n'
            done <<< "$listing"
        fi
    done
    files="$(echo "$files" | sed '/^$/d')"

    if [[ -z "$files" ]]; then
        error "No files found in S3"
        exit 1
    fi

    local selected
    selected="$(echo "$files" | sed 's|.*/||' | fzf --multi --layout=reverse --header='Select files to download (TAB to multi-select, ENTER to confirm)')" || true

    if [[ -z "$selected" ]]; then
        warn "No files selected"
        exit 0
    fi

    local aws_cmd
    aws_cmd="$(build_aws_cmd)"
    mkdir -p "$dest"

    for prefix in "${prefixes[@]}"; do
        local include_args=("--exclude" "*")
        local has_match=false
        while IFS= read -r filename; do
            if echo "$files" | grep -q "^${prefix}/${filename}$"; then
                include_args+=("--include" "$filename")
                has_match=true
            fi
        done <<< "$selected"
        if [[ "$has_match" == true ]]; then
            info "Syncing selected files from s3://${bucket}/${prefix}/"
            $aws_cmd s3 sync "s3://${bucket}/${prefix}/" "$dest/" "${include_args[@]}" --quiet
        fi
    done
}

extract_all() {
    local dest="$1"
    local zip_count
    zip_count=$(fdfind -e zip . "$dest" 2>/dev/null | wc -l)

    if [[ "$zip_count" -eq 0 ]]; then
        warn "No zip files to extract"
        return
    fi

    info "Extracting $zip_count zip file(s)..."

    while [[ "$zip_count" -gt 0 ]]; do
        fdfind -e zip . "$dest" | while IFS= read -r zipfile; do
            unzip -o -q "$zipfile" -d "$dest"
            rm "$zipfile"
        done
        zip_count=$(fdfind -e zip . "$dest" 2>/dev/null | wc -l)
    done
}

flatten_nested() {
    local dest="$1"
    local nested_count
    nested_count=$(fdfind -t f . "$dest" -d 2 --min-depth 2 2>/dev/null | wc -l)
    if [[ "$nested_count" -gt 0 ]]; then
        info "Flattening nested files..."
        fdfind -t f . "$dest" --min-depth 2 | while IFS= read -r nested_file; do
            local basename
            basename="$(basename "$nested_file")"
            local target="$dest/$basename"
            if [[ -f "$target" && "$nested_file" != "$target" ]]; then
                local name="${basename%.*}"
                local ext="${basename##*.}"
                if [[ "$name" == "$ext" ]]; then
                    target="$dest/${name}_$(date +%s%N)"
                else
                    target="$dest/${name}_$(date +%s%N).${ext}"
                fi
            fi
            mv "$nested_file" "$target"
        done
        fdfind -t d --empty . "$dest" -x rmdir {} 2>/dev/null || true
    fi
}

ENV=""
SEARCH_ID=""
TRACE_ID=""
PROFILE="${DEFAULT_PROFILE:-}"
DRY_RUN=false
PICK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)     ENV="$2"; shift 2 ;;
        -e=*|--env=*) ENV="${1#*=}"; shift ;;
        -s|--search)     SEARCH_ID="$2"; shift 2 ;;
        -s=*|--search=*) SEARCH_ID="${1#*=}"; shift ;;
        -t|--trace)     TRACE_ID="$2"; shift 2 ;;
        -t=*|--trace=*) TRACE_ID="${1#*=}"; shift ;;
        -p|--profile)     PROFILE="$2"; shift 2 ;;
        -p=*|--profile=*) PROFILE="${1#*=}"; shift ;;
        -f|--pick) PICK=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage 0 ;;
        *) error "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$ENV" ]]; then
    error "Environment (-e/--env) is required"
    usage 1
fi

if ! echo "$VALID_ENVS" | grep -qw "$ENV"; then
    error "Invalid environment: $ENV (valid: $VALID_ENVS)"
    exit 1
fi

if [[ -z "$SEARCH_ID" && -z "$TRACE_ID" ]]; then
    error "Either --search (-s) or --trace (-t) is required"
    usage 1
fi

if [[ -n "$SEARCH_ID" && -n "$TRACE_ID" ]]; then
    error "Use either --search or --trace, not both"
    usage 1
fi

if [[ "$PICK" == true && "$DRY_RUN" == true ]]; then
    error "Cannot use --pick with --dry-run"
    usage 1
fi

require_cmd aws
require_cmd unzip
if [[ "$PICK" == true ]]; then
    require_cmd fzf
fi

BUCKET="$(resolve_bucket "$ENV")"

if [[ -n "$SEARCH_ID" ]]; then
    DEST="${OUTPUT_ENGINE}/${SEARCH_ID}"
    PREFIXES=("${ENGINE_SEARCH_PREFIX}/${SEARCH_ID}" "${ENGINE_BOOKING_PREFIX}/${SEARCH_ID}")
else
    DEST="${OUTPUT_API}/${TRACE_ID}"
    PREFIXES=("${B2B2C_PREFIX}/${ENV}/flightLogs/${TRACE_ID}")
fi

if [[ "$PICK" == true ]]; then
    pick_and_sync "$BUCKET" "$DEST" "${PREFIXES[@]}"
else
    if [[ -d "$DEST" ]]; then
        warn "Directory already exists: $DEST (files will be overwritten)"
    fi
    mkdir -p "$DEST"

    FOUND=false
    for prefix in "${PREFIXES[@]}"; do
        if sync_prefix "$BUCKET" "$prefix" "$DEST"; then
            FOUND=true
        fi
    done

    if [[ "$FOUND" == false ]]; then
        error "No files found for the given ID in $BUCKET"
        rmdir "$DEST" 2>/dev/null || true
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[dry-run] Files exist at the above S3 paths. Run without --dry-run to download."
        exit 0
    fi

    extract_all "$DEST"
fi
flatten_nested "$DEST"

FILE_COUNT=$(fdfind -t f . "$DEST" 2>/dev/null | wc -l)
success "Downloaded $FILE_COUNT file(s) to $DEST"

(xdg-open "$DEST" &>/dev/null &) || true
