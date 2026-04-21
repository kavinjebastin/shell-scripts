#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COMMON_URL="https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/lib/common.sh"
LIB_PATH="$REPO_ROOT/lib/common.sh"
if [[ -f "$LIB_PATH" ]]; then
    # shellcheck source=../../lib/common.sh
    source "$LIB_PATH"
else
    eval "$(curl -fsSL "$COMMON_URL")"
fi

CONF_PATH="$SCRIPT_DIR/release-backmerge-prs.conf"
if [[ ! -f "$CONF_PATH" ]]; then
    error "Config file not found: $CONF_PATH"
    exit 1
fi
# shellcheck source=./release-backmerge-prs.conf
source "$CONF_PATH"

usage() {
    cat <<'EOF'
Usage: release-backmerge-prs (--all | -r <list> | --pick) [--skip-dev] [--dry-run]

Create backmerge PRs across configured ADO repos after a production release.
For each selected repo, opens PRs from its release branch to every configured
target branch. Skips targets whose branch does not exist, skips if an active
PR already exists, detects no-diff conditions, and reports conflicts.

Selection (one required):
      --all         Run all repos from config
  -r, --repo LIST   Comma-separated list of repos; each entry may override
                    the release branch with 'repo:source' syntax.
                    Examples:
                      -r OTP-UI-4
                      -r OTP-UI-4,b2b2c-Api
                      -r otp-engine-v2:release-v3,b2b2c-Api:hotfix
                    Repos without ':source' use the conf default.
  -f, --pick        Multi-select repos with fzf (uses conf source for each)

Options:
      --skip-dev       Skip all 'dev' targets for this run
      --auto-complete  Set PRs to auto-complete once policies pass
                       (keeps source branch, no squash, no bypass)
  -j, --concurrency N  Parallel PR workers (default 6, max 20)
      --dry-run        Show planned PRs, no writes
  -h, --help           Show this help
EOF
    exit "${1:-0}"
}

declare -A REPO_FILTERS=()
declare -A REPO_SOURCE_OVERRIDES=()
SELECTION_MODE=""
SKIP_DEV_CLI=false
DRY_RUN=false
AUTO_COMPLETE=false
CONCURRENCY=6

parse_repo_list() {
    local list="$1" item name override
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]}"; do
        item="${item// /}"
        [[ -z "$item" ]] && continue
        if [[ "$item" == *:* ]]; then
            name="${item%%:*}"
            override="${item#*:}"
            REPO_FILTERS["$name"]=1
            REPO_SOURCE_OVERRIDES["$name"]="$override"
        else
            REPO_FILTERS["$item"]=1
        fi
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)         SELECTION_MODE="all"; shift ;;
        -r|--repo)     SELECTION_MODE="filter"; parse_repo_list "$2"; shift 2 ;;
        -r=*|--repo=*) SELECTION_MODE="filter"; parse_repo_list "${1#*=}"; shift ;;
        -f|--pick)     SELECTION_MODE="pick"; shift ;;
        --skip-dev)      SKIP_DEV_CLI=true; shift ;;
        --auto-complete) AUTO_COMPLETE=true; shift ;;
        -j|--concurrency)      CONCURRENCY="$2"; shift 2 ;;
        -j=*|--concurrency=*)  CONCURRENCY="${1#*=}"; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage 0 ;;
        *) error "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$SELECTION_MODE" ]]; then
    usage 0
fi

if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 || CONCURRENCY > 20 )); then
    error "Invalid --concurrency: $CONCURRENCY (must be 1-20)"
    exit 1
fi

require_cmd az
require_cmd jq
[[ "$SELECTION_MODE" == "pick" ]] && require_cmd fzf

if [[ "$SELECTION_MODE" == "pick" ]]; then
    conf_repo_names=()
    for entry in "${REPOS[@]}"; do
        IFS='|' read -r r _ _ _ <<< "$entry"
        conf_repo_names+=("$r")
    done
    selected="$(printf '%s\n' "${conf_repo_names[@]}" | fzf --multi --layout=reverse \
        --header='Select repos to backmerge (TAB to multi-select, ENTER to confirm)')" || true
    if [[ -z "$selected" ]]; then
        warn "No repos selected"
        exit 0
    fi
    while IFS= read -r r; do
        REPO_FILTERS["$r"]=1
    done <<< "$selected"
fi

if ! az extension show -n azure-devops &>/dev/null; then
    error "azure-devops extension required: az extension add -n azure-devops"
    exit 1
fi

if ! az devops project list --organization "$ADO_ORG" --top 1 &>/dev/null; then
    error "Not authenticated to $ADO_ORG"
    error "Either export AZURE_DEVOPS_EXT_PAT=<pat> or run: az devops login --organization $ADO_ORG"
    exit 1
fi

TODAY="$(date +%Y-%m-%d)"

if [[ "$SELECTION_MODE" == "filter" ]]; then
    declare -A CONF_REPO_SET=()
    for entry in "${REPOS[@]}"; do
        IFS='|' read -r r _ _ _ <<< "$entry"
        CONF_REPO_SET["$r"]=1
    done
    unknown=()
    for r in "${!REPO_FILTERS[@]}"; do
        [[ -z "${CONF_REPO_SET[$r]:-}" ]] && unknown+=("$r")
    done
    if [[ ${#unknown[@]} -gt 0 ]]; then
        error "Unknown repo(s) in --repo: ${unknown[*]}"
        for u in "${unknown[@]}"; do
            u_lc="$(echo "$u" | tr '[:upper:]' '[:lower:]')"
            u_norm="$(echo "$u_lc" | tr -s 'a-z')"
            suggestion=""
            for r in "${!CONF_REPO_SET[@]}"; do
                r_lc="$(echo "$r" | tr '[:upper:]' '[:lower:]')"
                r_norm="$(echo "$r_lc" | tr -s 'a-z')"
                if [[ "$u_norm" == "$r_norm" || "$r_lc" == *"$u_lc"* || "$u_lc" == *"$r_lc"* ]]; then
                    suggestion="$r"
                    break
                fi
            done
            [[ -n "$suggestion" ]] && error "  did you mean: $suggestion ?"
        done
        error "Configured repos: ${!CONF_REPO_SET[*]}"
        exit 1
    fi
fi

build_pr_url() {
    local repo="$1" pr_id="$2"
    echo "${ADO_ORG}/${ADO_PROJECT}/_git/${repo}/pullrequest/${pr_id}"
}

branch_exists() {
    local repo="$1" branch="$2"
    az repos ref list \
        --organization "$ADO_ORG" --project "$ADO_PROJECT" --repository "$repo" \
        --filter "heads/$branch" \
        --query "[?name=='refs/heads/$branch']|[0].name" -o tsv 2>/dev/null \
        | grep -q .
}

find_active_pr_id() {
    local repo="$1" source="$2" target="$3"
    az repos pr list \
        --organization "$ADO_ORG" --project "$ADO_PROJECT" --repository "$repo" \
        --status active \
        --source-branch "$source" --target-branch "$target" \
        --query "[0].pullRequestId" -o tsv 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true
}

render_title() {
    local source="$1" target="$2"
    local t="$PR_TITLE_TEMPLATE"
    t="${t//\{source\}/$source}"
    t="${t//\{target\}/$target}"
    t="${t//\{date\}/$TODAY}"
    echo "$t"
}

create_backmerge_pr() {
    local repo="$1" source="$2" target="$3"
    local title description
    title="$(render_title "$source" "$target")"
    description="Automated backmerge from $source to $target on $TODAY."

    local -a reviewer_args=()
    if [[ -n "${DEFAULT_REVIEWERS:-}" ]]; then
        # shellcheck disable=SC2206
        local reviewer_list=($DEFAULT_REVIEWERS)
        reviewer_args=(--reviewers "${reviewer_list[@]}")
    fi

    local -a ac_args=()
    if [[ "${AUTO_COMPLETE:-false}" == "true" ]]; then
        ac_args=(
            --auto-complete true
            --delete-source-branch false
            --squash false
            --transition-work-items false
        )
    fi

    az repos pr create \
        --organization "$ADO_ORG" \
        --project "$ADO_PROJECT" \
        --repository "$repo" \
        --source-branch "$source" \
        --target-branch "$target" \
        --title "$title" \
        --description "$description" \
        --output json \
        "${reviewer_args[@]}" \
        "${ac_args[@]}" 2>&1
}

# Echoes a single line: status|pr_url|message
process_pair() {
    local repo="$1" source="$2" target="$3"

    if ! branch_exists "$repo" "$source"; then
        echo "ERROR||source branch $source not found"
        return
    fi

    if ! branch_exists "$repo" "$target"; then
        echo "SKIPPED_NO_BRANCH||target branch $target not found"
        return
    fi

    local existing_pr_id url
    existing_pr_id="$(find_active_pr_id "$repo" "$source" "$target")"
    if [[ -n "$existing_pr_id" ]]; then
        url="$(build_pr_url "$repo" "$existing_pr_id")"
        echo "EXISTS|$url|PR #$existing_pr_id"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY_RUN||would create $source -> $target"
        return
    fi

    local output ec=0
    output="$(create_backmerge_pr "$repo" "$source" "$target")" || ec=$?

    if [[ $ec -ne 0 ]]; then
        local lower
        lower="$(echo "$output" | tr '[:upper:]' '[:lower:]')"

        if echo "$lower" | grep -qE 'no (new )?commit|nothing to merge|no changes|tf401179.*identical|tf401019'; then
            echo "NO_DIFF||no commits between $source and $target"
            return
        fi

        local race_pr_id
        race_pr_id="$(find_active_pr_id "$repo" "$source" "$target")"
        if [[ -n "$race_pr_id" ]]; then
            url="$(build_pr_url "$repo" "$race_pr_id")"
            echo "EXISTS|$url|PR #$race_pr_id"
            return
        fi

        local msg
        msg="$(echo "$output" | tr '\n|' '  ' | tr -s ' ' | cut -c1-220)"
        echo "ERROR||${msg:-az repos pr create failed}"
        return
    fi

    local pr_id merge_status
    pr_id="$(echo "$output" | jq -r '.pullRequestId // empty' 2>/dev/null)"
    merge_status="$(echo "$output" | jq -r '.mergeStatus // empty' 2>/dev/null)"

    if [[ -z "$pr_id" ]]; then
        local msg
        msg="$(echo "$output" | tr '\n|' '  ' | tr -s ' ' | cut -c1-220)"
        echo "ERROR||unexpected response: ${msg:-empty}"
        return
    fi

    url="$(build_pr_url "$repo" "$pr_id")"

    case "$merge_status" in
        conflicts)              echo "CREATED_CONFLICT|$url|PR #$pr_id merge conflicts" ;;
        succeeded|succeededNonFastForward)
                                echo "CREATED|$url|PR #$pr_id" ;;
        rejectedByPolicy)       echo "CREATED_CONFLICT|$url|PR #$pr_id rejected by policy" ;;
        *)                      echo "CREATED|$url|PR #$pr_id" ;;
    esac
}

declare -a RESULTS=()
declare -a ORDERED=()
declare -a JOBS=()
declare -A RESULTS_MAP=()
total_created=0
total_conflict=0
total_exists=0
total_nodiff=0
total_skipped=0
total_error=0
total_dryrun=0

for entry in "${REPOS[@]}"; do
    IFS='|' read -r repo source targets skip_dev_repo <<< "$entry"

    if [[ "$SELECTION_MODE" != "all" ]]; then
        if [[ -z "${REPO_FILTERS[$repo]:-}" ]]; then
            continue
        fi
        override="${REPO_SOURCE_OVERRIDES[$repo]:-}"
        if [[ -n "$override" ]]; then
            info "Override: $repo release branch $source -> $override"
            source="$override"
        fi
    fi

    IFS=',' read -ra target_arr <<< "$targets"
    for target in "${target_arr[@]}"; do
        [[ "$target" == "$source" ]] && continue

        key="$repo|$source|$target"

        if [[ "$target" == "dev" ]]; then
            if [[ "$skip_dev_repo" == "true" ]]; then
                RESULTS_MAP["$key"]="SKIPPED_DEV_CONFIG||dev disabled per-repo"
                ORDERED+=("$key")
                continue
            fi
            if [[ "$SKIP_DEV_CLI" == true ]]; then
                RESULTS_MAP["$key"]="SKIPPED_DEV_RUN||dev skipped for this run"
                ORDERED+=("$key")
                continue
            fi
        fi

        ORDERED+=("$key")
        JOBS+=("$key")
    done
done

if [[ ${#ORDERED[@]} -eq 0 ]]; then
    warn "No PR pairs to process"
    exit 0
fi

if [[ ${#JOBS[@]} -gt 0 ]]; then
    effective_concurrency=$CONCURRENCY
    (( effective_concurrency > ${#JOBS[@]} )) && effective_concurrency=${#JOBS[@]}
    info "Dispatching ${#JOBS[@]} PR job(s) with concurrency $effective_concurrency"

    export ADO_ORG ADO_PROJECT DEFAULT_REVIEWERS PR_TITLE_TEMPLATE TODAY DRY_RUN AUTO_COMPLETE
    export -f build_pr_url branch_exists find_active_pr_id render_title create_backmerge_pr process_pair

    parallel_out="$(mktemp)"
    trap 'rm -f "$parallel_out"' EXIT

    printf '%s\n' "${JOBS[@]}" | xargs -P "$effective_concurrency" -I {} bash -c '
        set -uo pipefail
        IFS="|" read -r repo source target <<< "$1"
        line="$(process_pair "$repo" "$source" "$target")"
        printf "%s|%s|%s|%s\n" "$repo" "$source" "$target" "$line"
    ' _ {} > "$parallel_out"

    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        IFS='|' read -r r s t st u m <<< "$l"
        RESULTS_MAP["$r|$s|$t"]="$st|$u|$m"
    done < "$parallel_out"

    rm -f "$parallel_out"
    trap - EXIT
fi

for key in "${ORDERED[@]}"; do
    value="${RESULTS_MAP[$key]:-ERROR||worker produced no result}"
    RESULTS+=("$key|$value")
    IFS='|' read -r _ _ _ status _ _ <<< "$key|$value"
    case "$status" in
        CREATED)           total_created=$((total_created + 1)) ;;
        CREATED_CONFLICT)  total_created=$((total_created + 1)); total_conflict=$((total_conflict + 1)) ;;
        EXISTS)            total_exists=$((total_exists + 1)) ;;
        NO_DIFF)           total_nodiff=$((total_nodiff + 1)) ;;
        SKIPPED_*)         total_skipped=$((total_skipped + 1)) ;;
        DRY_RUN)           total_dryrun=$((total_dryrun + 1)) ;;
        ERROR)             total_error=$((total_error + 1)) ;;
    esac
done

echo ""
echo "=============================================================="
echo "  Backmerge Summary   (date: $TODAY)"
echo "=============================================================="

current_repo=""
for r in "${RESULTS[@]}"; do
    IFS='|' read -r repo src tgt status url msg <<< "$r"

    if [[ "$current_repo" != "$repo" ]]; then
        [[ -n "$current_repo" ]] && echo ""
        echo ""
        echo "$repo   (source: $src)"
        current_repo="$repo"
    fi

    indicator=""
    case "$status" in
        CREATED_CONFLICT) indicator="  <-- CONFLICTS" ;;
        ERROR)            indicator="  <-- ERROR" ;;
    esac

    detail="$url"
    [[ -z "$detail" ]] && detail="$msg"
    [[ -n "$url" && -n "$msg" ]] && detail="$url  ($msg)"

    printf "  %-8s -> %-10s  %-22s  %s%s\n" "$src" "$tgt" "$status" "$detail" "$indicator"
done

echo ""
echo "--------------------------------------------------------------"
summary="${total_created} created"
[[ $total_conflict -gt 0 ]] && summary="$summary ($total_conflict with conflicts)"
summary="$summary, ${total_exists} existing, ${total_nodiff} no-diff, ${total_skipped} skipped, ${total_error} errors"
[[ $total_dryrun -gt 0 ]] && summary="$summary, ${total_dryrun} dry-run"
echo "  $summary"
echo "=============================================================="

if [[ $total_error -gt 0 ]]; then
    exit 1
fi
