#!/usr/bin/env bash
#
# Claude-Code-PCCleaner -- Full PC optimization for developers (Linux/macOS)
#
# Usage:
#   ./pccleaner.sh [--scan|--clean|--aggressive] [--caches] [--builds] [--processes] [--apps]
#
# Modes:
#   --scan        Report only -- nothing is modified (default)
#   --clean       Interactive -- confirms before each action
#   --aggressive  Auto-confirm -- maximum cleanup
#
# Modules:
#   --caches      Package manager caches (npm, uv, pip, Go, Cargo)
#   --builds      Build artifacts and stale dependencies
#   --processes   RAM analysis and process management
#   --apps        Browser and application caches
#
# If no module flags are given, all modules run.

set -euo pipefail

# ============================================================
# GLOBALS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/defaults.json"
MODE="scan"
RUN_CACHES=false
RUN_BUILDS=false
RUN_PROCESSES=false
RUN_APPS=false
TOTAL_FREED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'  # No color

# ============================================================
# ARGUMENT PARSING
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan)       MODE="scan"; shift ;;
        --clean)      MODE="clean"; shift ;;
        --aggressive) MODE="aggressive"; shift ;;
        --caches)     RUN_CACHES=true; shift ;;
        --builds)     RUN_BUILDS=true; shift ;;
        --processes)  RUN_PROCESSES=true; shift ;;
        --apps)       RUN_APPS=true; shift ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# If no module flags, run all
if ! $RUN_CACHES && ! $RUN_BUILDS && ! $RUN_PROCESSES && ! $RUN_APPS; then
    RUN_CACHES=true
    RUN_BUILDS=true
    RUN_PROCESSES=true
    RUN_APPS=true
fi

# ============================================================
# CONFIG
# ============================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}ERROR: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse JSON config using basic tools (no jq dependency required, but use it if available)
if command -v jq &>/dev/null; then
    LARGE_FILE_THRESHOLD_MB=$(jq -r '.large_file_threshold_mb' "$CONFIG_FILE")
    INACTIVE_PROJECT_DAYS=$(jq -r '.inactive_project_days' "$CONFIG_FILE")
    TEMP_AGE_DAYS=$(jq -r '.temp_age_days' "$CONFIG_FILE")
else
    # Fallback: grep-based parsing for simple numeric values
    LARGE_FILE_THRESHOLD_MB=$(grep -o '"large_file_threshold_mb": *[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*$')
    INACTIVE_PROJECT_DAYS=$(grep -o '"inactive_project_days": *[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*$')
    TEMP_AGE_DAYS=$(grep -o '"temp_age_days": *[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*$')
fi

# Defaults if parsing failed
LARGE_FILE_THRESHOLD_MB=${LARGE_FILE_THRESHOLD_MB:-500}
INACTIVE_PROJECT_DAYS=${INACTIVE_PROJECT_DAYS:-30}
TEMP_AGE_DAYS=${TEMP_AGE_DAYS:-7}

PROJECTS_DIR="$HOME/projects"

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

format_size() {
    # Converts bytes to human-readable format
    local bytes=$1
    if [[ $bytes -ge 1099511627776 ]]; then
        echo "$(echo "scale=2; $bytes / 1099511627776" | bc) TB"
    elif [[ $bytes -ge 1073741824 ]]; then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
    else
        echo "$bytes B"
    fi
}

dir_size_bytes() {
    # Returns the size of a directory in bytes. Returns 0 if not found.
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo 0
        return
    fi
    # du -sb gives total bytes on Linux; du -sk on macOS (multiply by 1024)
    if du -sb "$path" &>/dev/null; then
        du -sb "$path" 2>/dev/null | awk '{print $1}'
    else
        # macOS fallback: du -sk returns KB
        local kb
        kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
        echo $(( kb * 1024 ))
    fi
}

confirm() {
    # Prompts for confirmation. Returns 0 (yes) or 1 (no).
    local prompt="$1"
    if [[ "$MODE" == "aggressive" ]]; then
        return 0
    elif [[ "$MODE" == "clean" ]]; then
        read -rp "  $prompt [y/N] " response
        [[ "$response" =~ ^[Yy]$ ]]
    else
        return 1  # Scan mode: never confirm
    fi
}

# ============================================================
# DISK AUDIT MODULE
# ============================================================

disk_audit() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  DISK AUDIT${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # Drive capacity
    echo -e "${YELLOW}[Drive Capacity]${NC}"
    echo ""

    df -h / 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""

    # Check free space percentage
    local free_percent
    if [[ "$(uname)" == "Darwin" ]]; then
        free_percent=$(df -h / | tail -1 | awk '{gsub(/%/,""); print 100 - $5}')
    else
        free_percent=$(df -h / | tail -1 | awk '{gsub(/%/,""); print 100 - $5}')
    fi

    if [[ $free_percent -lt 15 ]]; then
        echo -e "  ${RED}WARNING: Only ${free_percent}% free space remaining!${NC}"
    elif [[ $free_percent -lt 25 ]]; then
        echo -e "  ${YELLOW}Note: ${free_percent}% free space remaining.${NC}"
    else
        echo -e "  ${GREEN}${free_percent}% free space available.${NC}"
    fi

    echo ""

    # User profile breakdown
    echo -e "${YELLOW}[Home Directory Breakdown]${NC}"
    echo ""

    local dirs=("Desktop" "Downloads" "Documents" "Pictures" "Videos" "Music" ".cache" ".local")

    printf "  %-20s %15s\n" "Directory" "Size"
    printf "  %-20s %15s\n" "--------------------" "---------------"

    for dir in "${dirs[@]}"; do
        local full_path="$HOME/$dir"
        if [[ -d "$full_path" ]]; then
            local size_str
            size_str=$(du -sh "$full_path" 2>/dev/null | awk '{print $1}')
            printf "  %-20s %15s\n" "$dir" "$size_str"
        fi
    done

    echo ""

    # Projects breakdown
    if [[ -d "$PROJECTS_DIR" ]]; then
        echo -e "${YELLOW}[Projects Breakdown]${NC}"
        echo ""

        printf "  %-40s %15s\n" "Project" "Size"
        printf "  %-40s %15s\n" "----------------------------------------" "---------------"

        for project in "$PROJECTS_DIR"/*/; do
            if [[ -d "$project" ]]; then
                local name
                name=$(basename "$project")
                local size_str
                size_str=$(du -sh "$project" 2>/dev/null | awk '{print $1}')
                printf "  %-40s %15s\n" "$name" "$size_str"
            fi
        done

        echo ""
        local total_projects
        total_projects=$(du -sh "$PROJECTS_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "  Total projects: ${WHITE}$total_projects${NC}"
        echo ""
    fi

    # Large file finder
    echo -e "${YELLOW}[Large Files (> ${LARGE_FILE_THRESHOLD_MB} MB)]${NC}"
    echo ""

    local threshold_bytes=$(( LARGE_FILE_THRESHOLD_MB * 1048576 ))

    local large_files
    large_files=$(find "$HOME" -maxdepth 5 -type f -size +"${LARGE_FILE_THRESHOLD_MB}M" 2>/dev/null | head -30)

    if [[ -z "$large_files" ]]; then
        echo -e "  ${GREEN}No files found above ${LARGE_FILE_THRESHOLD_MB} MB.${NC}"
    else
        printf "  %-12s %-12s %s\n" "Size" "Modified" "Path"
        printf "  %-12s %-12s %s\n" "------------" "------------" "----"

        while IFS= read -r filepath; do
            if [[ -f "$filepath" ]]; then
                local file_size
                if stat --format='%s' "$filepath" &>/dev/null; then
                    file_size=$(stat --format='%s' "$filepath" 2>/dev/null)
                else
                    file_size=$(stat -f '%z' "$filepath" 2>/dev/null)
                fi
                local file_date
                if stat --format='%Y' "$filepath" &>/dev/null; then
                    file_date=$(date -d "@$(stat --format='%Y' "$filepath")" '+%Y-%m-%d' 2>/dev/null)
                else
                    file_date=$(stat -f '%Sm' -t '%Y-%m-%d' "$filepath" 2>/dev/null)
                fi
                local display_path="${filepath/#$HOME/\~}"
                printf "  %12s %-12s %s\n" "$(format_size "$file_size")" "$file_date" "$display_path"
            fi
        done <<< "$large_files"
    fi

    echo ""
}

# ============================================================
# CACHE CLEANER MODULE
# ============================================================

cache_cleaner() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  CACHE CLEANER${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    echo -e "  ${RED}[!] WARNING: ~/.npm (or AppData/Roaming/npm on Windows) is NOT a cache.${NC}"
    echo -e "  ${RED}    It contains globally installed CLI tools. This module will NEVER touch it.${NC}"
    echo ""

    local freed=0

    # npm cache
    echo -e "  ${WHITE}[npm]${NC}"
    local npm_cache=""
    if command -v npm &>/dev/null; then
        npm_cache=$(npm config get cache 2>/dev/null || echo "")
    fi
    if [[ -z "$npm_cache" ]]; then
        npm_cache="$HOME/.npm"
    fi

    if [[ -d "$npm_cache" ]]; then
        local npm_size
        npm_size=$(dir_size_bytes "$npm_cache")
        echo -e "    Size: ${YELLOW}$(format_size "$npm_size")${NC}"
        echo -e "    ${GRAY}Path: $npm_cache${NC}"

        if [[ "$MODE" != "scan" ]] && [[ $npm_size -gt 0 ]]; then
            if confirm "Clean npm cache ($(format_size "$npm_size"))?"; then
                if command -v npm &>/dev/null; then
                    npm cache clean --force 2>/dev/null
                    echo -e "    ${GREEN}Cleaned via: npm cache clean --force${NC}"
                else
                    rm -rf "$npm_cache"
                    echo -e "    ${GREEN}Deleted: $npm_cache${NC}"
                fi
                freed=$(( freed + npm_size ))
            else
                echo -e "    ${GRAY}Skipped.${NC}"
            fi
        fi
    else
        echo -e "    ${GRAY}Not found${NC}"
    fi
    echo ""

    # uv cache (Python)
    echo -e "  ${WHITE}[uv (Python)]${NC}"
    if command -v uv &>/dev/null; then
        local uv_cache
        uv_cache=$(uv cache dir 2>/dev/null || echo "")
        if [[ -n "$uv_cache" ]] && [[ -d "$uv_cache" ]]; then
            local uv_size
            uv_size=$(dir_size_bytes "$uv_cache")
            echo -e "    Size: ${YELLOW}$(format_size "$uv_size")${NC}"
            echo -e "    ${GRAY}Path: $uv_cache${NC}"

            if [[ "$MODE" != "scan" ]] && [[ $uv_size -gt 0 ]]; then
                if confirm "Clean uv cache ($(format_size "$uv_size"))?"; then
                    uv cache clean 2>/dev/null
                    echo -e "    ${GREEN}Cleaned via: uv cache clean${NC}"
                    freed=$(( freed + uv_size ))
                else
                    echo -e "    ${GRAY}Skipped.${NC}"
                fi
            fi
        else
            echo -e "    ${GRAY}Empty or not found${NC}"
        fi
    else
        echo -e "    ${GRAY}uv not installed${NC}"
    fi
    echo ""

    # pip cache
    echo -e "  ${WHITE}[pip]${NC}"
    local pip_cache=""
    if [[ "$(uname)" == "Darwin" ]]; then
        pip_cache="$HOME/Library/Caches/pip"
    else
        pip_cache="$HOME/.cache/pip"
    fi

    if [[ -d "$pip_cache" ]]; then
        local pip_size
        pip_size=$(dir_size_bytes "$pip_cache")
        echo -e "    Size: ${YELLOW}$(format_size "$pip_size")${NC}"
        echo -e "    ${GRAY}Path: $pip_cache${NC}"

        if [[ "$MODE" != "scan" ]] && [[ $pip_size -gt 0 ]]; then
            if confirm "Clean pip cache ($(format_size "$pip_size"))?"; then
                if command -v pip &>/dev/null; then
                    pip cache purge 2>/dev/null
                    echo -e "    ${GREEN}Cleaned via: pip cache purge${NC}"
                elif command -v pip3 &>/dev/null; then
                    pip3 cache purge 2>/dev/null
                    echo -e "    ${GREEN}Cleaned via: pip3 cache purge${NC}"
                else
                    rm -rf "$pip_cache"
                    echo -e "    ${GREEN}Deleted: $pip_cache${NC}"
                fi
                freed=$(( freed + pip_size ))
            else
                echo -e "    ${GRAY}Skipped.${NC}"
            fi
        fi
    else
        echo -e "    ${GRAY}Not found${NC}"
    fi
    echo ""

    # Go module cache
    echo -e "  ${WHITE}[Go modules]${NC}"
    local go_cache="${GOPATH:-$HOME/go}/pkg/mod/cache"

    if [[ -d "$go_cache" ]]; then
        local go_size
        go_size=$(dir_size_bytes "$go_cache")
        echo -e "    Size: ${YELLOW}$(format_size "$go_size")${NC}"
        echo -e "    ${GRAY}Path: $go_cache${NC}"

        if [[ "$MODE" != "scan" ]] && [[ $go_size -gt 0 ]]; then
            if confirm "Clean Go module cache ($(format_size "$go_size"))?"; then
                if command -v go &>/dev/null; then
                    go clean -modcache 2>/dev/null
                    echo -e "    ${GREEN}Cleaned via: go clean -modcache${NC}"
                else
                    rm -rf "$go_cache"
                    echo -e "    ${GREEN}Deleted: $go_cache${NC}"
                fi
                freed=$(( freed + go_size ))
            else
                echo -e "    ${GRAY}Skipped.${NC}"
            fi
        fi
    else
        echo -e "    ${GRAY}Not found${NC}"
    fi
    echo ""

    # Cargo cache
    echo -e "  ${WHITE}[Cargo]${NC}"
    local cargo_cache="$HOME/.cargo/registry/cache"

    if [[ -d "$cargo_cache" ]]; then
        local cargo_size
        cargo_size=$(dir_size_bytes "$cargo_cache")
        echo -e "    Size: ${YELLOW}$(format_size "$cargo_size")${NC}"
        echo -e "    ${GRAY}Path: $cargo_cache${NC}"

        if [[ "$MODE" != "scan" ]] && [[ $cargo_size -gt 0 ]]; then
            if confirm "Clean Cargo cache ($(format_size "$cargo_size"))?"; then
                rm -rf "$cargo_cache"
                echo -e "    ${GREEN}Deleted: $cargo_cache${NC}"
                freed=$(( freed + cargo_size ))
            else
                echo -e "    ${GRAY}Skipped.${NC}"
            fi
        fi
    else
        echo -e "    ${GRAY}Not found${NC}"
    fi
    echo ""

    echo -e "  ${WHITE}Total cache space freed: $(format_size $freed)${NC}"
    echo ""

    TOTAL_FREED=$(( TOTAL_FREED + freed ))
}

# ============================================================
# BUILD CLEANER MODULE
# ============================================================

build_cleaner() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  BUILD ARTIFACT CLEANER${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        echo -e "  ${RED}Projects directory not found: $PROJECTS_DIR${NC}"
        return
    fi

    echo -e "  ${GRAY}Scanning: $PROJECTS_DIR${NC}"
    echo -e "  ${GRAY}Inactive threshold: $INACTIVE_PROJECT_DAYS days${NC}"
    echo ""

    local freed=0
    local build_patterns=(".next" "dist" "build" "target" "out" "__pycache__" ".pytest_cache" ".mypy_cache")

    # Build artifacts
    echo -e "${YELLOW}[Build Artifacts]${NC}"
    echo ""

    local found_any=false

    printf "  %-16s %12s %-12s %s\n" "Type" "Size" "Modified" "Path"
    printf "  %-16s %12s %-12s %s\n" "----------------" "------------" "------------" "----"

    for pattern in "${build_patterns[@]}"; do
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue

            # Skip if inside node_modules or .git
            if [[ "$dir" == *"/node_modules/"* ]] || [[ "$dir" == *"/.git/"* ]]; then
                continue
            fi

            found_any=true
            local size_str
            size_str=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            local mod_date
            if stat --format='%Y' "$dir" &>/dev/null; then
                mod_date=$(date -d "@$(stat --format='%Y' "$dir")" '+%Y-%m-%d' 2>/dev/null)
            else
                mod_date=$(stat -f '%Sm' -t '%Y-%m-%d' "$dir" 2>/dev/null)
            fi
            local display_path="${dir/#$HOME/\~}"

            printf "  %-16s %12s %-12s %s\n" "$pattern" "$size_str" "$mod_date" "$display_path"
        done < <(find "$PROJECTS_DIR" -maxdepth 5 -type d -name "$pattern" 2>/dev/null)
    done

    if ! $found_any; then
        echo -e "  ${GREEN}No build artifacts found.${NC}"
    fi

    echo ""

    # Clean build artifacts
    if [[ "$MODE" != "scan" ]] && $found_any; then
        if confirm "Remove all build artifacts?"; then
            for pattern in "${build_patterns[@]}"; do
                while IFS= read -r dir; do
                    [[ -z "$dir" ]] && continue
                    [[ "$dir" == *"/node_modules/"* ]] && continue
                    [[ "$dir" == *"/.git/"* ]] && continue

                    local size_bytes
                    size_bytes=$(dir_size_bytes "$dir")
                    rm -rf "$dir" 2>/dev/null
                    freed=$(( freed + size_bytes ))
                    echo -e "    ${GREEN}Removed: ${dir/#$HOME/\~}${NC}"
                done < <(find "$PROJECTS_DIR" -maxdepth 5 -type d -name "$pattern" 2>/dev/null)
            done
        else
            echo -e "  ${GRAY}Skipped.${NC}"
        fi
        echo ""
    fi

    # Stale node_modules
    echo -e "${YELLOW}[Stale node_modules (inactive > $INACTIVE_PROJECT_DAYS days)]${NC}"
    echo ""

    local stale_nm_found=false

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue

        # Only top-level node_modules (not nested)
        local parent
        parent=$(dirname "$dir")
        local grandparent
        grandparent=$(dirname "$parent")

        # Check if the parent project was recently modified
        local project_dir="$parent"
        local recent_file
        recent_file=$(find "$project_dir" -maxdepth 1 -type f -mtime "-${INACTIVE_PROJECT_DAYS}" 2>/dev/null | head -1)

        if [[ -z "$recent_file" ]]; then
            stale_nm_found=true
            local size_str
            size_str=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            local display_path="${dir/#$HOME/\~}"
            echo -e "  $size_str\t${display_path}"
        fi
    done < <(find "$PROJECTS_DIR" -maxdepth 4 -type d -name "node_modules" 2>/dev/null)

    if ! $stale_nm_found; then
        echo -e "  ${GREEN}No stale node_modules found.${NC}"
    fi
    echo ""

    if [[ "$MODE" != "scan" ]] && $stale_nm_found; then
        if confirm "Remove all stale node_modules?"; then
            while IFS= read -r dir; do
                [[ -z "$dir" ]] && continue
                local project_dir
                project_dir=$(dirname "$dir")
                local recent_file
                recent_file=$(find "$project_dir" -maxdepth 1 -type f -mtime "-${INACTIVE_PROJECT_DAYS}" 2>/dev/null | head -1)

                if [[ -z "$recent_file" ]]; then
                    local size_bytes
                    size_bytes=$(dir_size_bytes "$dir")
                    rm -rf "$dir" 2>/dev/null
                    freed=$(( freed + size_bytes ))
                    echo -e "    ${GREEN}Removed: ${dir/#$HOME/\~}${NC}"
                fi
            done < <(find "$PROJECTS_DIR" -maxdepth 4 -type d -name "node_modules" 2>/dev/null)
        else
            echo -e "  ${GRAY}Skipped.${NC}"
        fi
        echo ""
    fi

    # Stale .venv
    echo -e "${YELLOW}[Stale .venv (inactive > $INACTIVE_PROJECT_DAYS days)]${NC}"
    echo ""

    local stale_venv_found=false

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue

        local project_dir
        project_dir=$(dirname "$dir")
        local recent_file
        recent_file=$(find "$project_dir" -maxdepth 1 -type f -mtime "-${INACTIVE_PROJECT_DAYS}" 2>/dev/null | head -1)

        if [[ -z "$recent_file" ]]; then
            stale_venv_found=true
            local size_str
            size_str=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            local display_path="${dir/#$HOME/\~}"
            echo -e "  $size_str\t${display_path}"
        fi
    done < <(find "$PROJECTS_DIR" -maxdepth 4 -type d -name ".venv" 2>/dev/null)

    if ! $stale_venv_found; then
        echo -e "  ${GREEN}No stale .venv directories found.${NC}"
    fi
    echo ""

    if [[ "$MODE" != "scan" ]] && $stale_venv_found; then
        if confirm "Remove all stale .venv directories?"; then
            while IFS= read -r dir; do
                [[ -z "$dir" ]] && continue
                local project_dir
                project_dir=$(dirname "$dir")
                local recent_file
                recent_file=$(find "$project_dir" -maxdepth 1 -type f -mtime "-${INACTIVE_PROJECT_DAYS}" 2>/dev/null | head -1)

                if [[ -z "$recent_file" ]]; then
                    local size_bytes
                    size_bytes=$(dir_size_bytes "$dir")
                    rm -rf "$dir" 2>/dev/null
                    freed=$(( freed + size_bytes ))
                    echo -e "    ${GREEN}Removed: ${dir/#$HOME/\~}${NC}"
                fi
            done < <(find "$PROJECTS_DIR" -maxdepth 4 -type d -name ".venv" 2>/dev/null)
        else
            echo -e "  ${GRAY}Skipped.${NC}"
        fi
    fi

    echo ""
    echo -e "  ${WHITE}Build cleaner freed: $(format_size $freed)${NC}"
    echo ""

    TOTAL_FREED=$(( TOTAL_FREED + freed ))
}

# ============================================================
# PROCESS AUDIT MODULE
# ============================================================

process_audit() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  PROCESS AUDIT${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # System memory overview
    echo -e "${YELLOW}[System Memory]${NC}"
    echo ""

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use vm_stat
        local page_size
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local total_mem
        total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

        local vm_output
        vm_output=$(vm_stat 2>/dev/null)
        local free_pages
        free_pages=$(echo "$vm_output" | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local inactive_pages
        inactive_pages=$(echo "$vm_output" | grep "Pages inactive" | awk '{print $3}' | tr -d '.')

        local free_mem=$(( (free_pages + inactive_pages) * page_size ))
        local used_mem=$(( total_mem - free_mem ))
        local used_pct=$(( used_mem * 100 / total_mem ))

        echo -e "  Total RAM:     $(format_size $total_mem)"
        echo -e "  Used:          $(format_size $used_mem) ($used_pct%)"
        echo -e "  Available:     $(format_size $free_mem) ($(( 100 - used_pct ))%)"
    else
        # Linux: use /proc/meminfo or free
        if command -v free &>/dev/null; then
            free -h | head -2 | while IFS= read -r line; do
                echo "  $line"
            done

            local total_kb available_kb
            total_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')

            if [[ -n "$total_kb" ]] && [[ -n "$available_kb" ]] && [[ $total_kb -gt 0 ]]; then
                local free_pct=$(( available_kb * 100 / total_kb ))
                local used_pct=$(( 100 - free_pct ))

                echo ""
                if [[ $free_pct -lt 15 ]]; then
                    echo -e "  ${RED}WARNING: Only ${free_pct}% RAM available!${NC}"
                elif [[ $free_pct -lt 30 ]]; then
                    echo -e "  ${YELLOW}Note: ${free_pct}% RAM available.${NC}"
                else
                    echo -e "  ${GREEN}${free_pct}% RAM available.${NC}"
                fi
            fi
        fi
    fi

    echo ""

    # Top processes by memory
    echo -e "${YELLOW}[Top 20 Processes by Memory]${NC}"
    echo ""

    if [[ "$(uname)" == "Darwin" ]]; then
        ps aux --sort=-%mem 2>/dev/null | head -21 | while IFS= read -r line; do
            echo "  $line"
        done
    else
        ps aux --sort=-%mem 2>/dev/null | head -21 | while IFS= read -r line; do
            echo "  $line"
        done
    fi

    echo ""

    # Grouped by command
    echo -e "${YELLOW}[Memory by Application (grouped)]${NC}"
    echo ""

    printf "  %-25s %10s %12s\n" "Application" "Instances" "RSS Total"
    printf "  %-25s %10s %12s\n" "-------------------------" "----------" "------------"

    ps -eo comm,rss --no-headers 2>/dev/null |
        awk '{cmd=$1; mem=$2; a[cmd]+=mem; c[cmd]++} END {for(i in a) printf "%s %d %d\n", i, c[i], a[i]}' |
        sort -k3 -nr |
        head -20 |
        while read -r cmd count rss_kb; do
            local rss_bytes=$(( rss_kb * 1024 ))
            printf "  %-25s %10d %12s\n" "$cmd" "$count" "$(format_size $rss_bytes)"
        done

    echo ""

    # Kill suggestions in clean/aggressive mode
    if [[ "$MODE" != "scan" ]]; then
        echo -e "${YELLOW}[Process Management]${NC}"
        echo ""
        echo -e "  ${GRAY}Use 'kill PID' or 'killall PROCESS_NAME' to terminate specific processes.${NC}"
        echo -e "  ${GRAY}This module provides analysis only. Manual kill is safer on Unix.${NC}"
        echo ""
    fi
}

# ============================================================
# APP CLEANER MODULE
# ============================================================

app_cleaner() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  APPLICATION CACHE CLEANER${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    local freed=0

    # Determine cache base directory
    local cache_base
    if [[ "$(uname)" == "Darwin" ]]; then
        cache_base="$HOME/Library/Caches"
    else
        cache_base="$HOME/.cache"
    fi

    # Browser caches
    local browser_caches=()

    if [[ "$(uname)" == "Darwin" ]]; then
        browser_caches=(
            "Chrome:$HOME/Library/Caches/Google/Chrome/Default/Cache"
            "Firefox:$HOME/Library/Caches/Firefox/Profiles"
            "Safari:$HOME/Library/Caches/com.apple.Safari"
        )
    else
        browser_caches=(
            "Chrome:$HOME/.cache/google-chrome/Default/Cache"
            "Chrome Code Cache:$HOME/.cache/google-chrome/Default/Code Cache"
            "Firefox:$HOME/.cache/mozilla/firefox"
            "Edge:$HOME/.cache/microsoft-edge/Default/Cache"
        )
    fi

    echo -e "${YELLOW}[Browser Caches]${NC}"
    echo ""

    local browser_total=0

    for entry in "${browser_caches[@]}"; do
        local name="${entry%%:*}"
        local path="${entry#*:}"

        if [[ -d "$path" ]]; then
            local size_bytes
            size_bytes=$(dir_size_bytes "$path")
            browser_total=$(( browser_total + size_bytes ))

            echo -e "  ${WHITE}$name${NC}  $(format_size $size_bytes)"
            echo -e "    ${GRAY}$path${NC}"
        fi
    done

    echo ""
    echo -e "  Subtotal: $(format_size $browser_total)"
    echo ""

    if [[ "$MODE" != "scan" ]] && [[ $browser_total -gt 0 ]]; then
        if confirm "Clean all browser caches ($(format_size $browser_total))?"; then
            for entry in "${browser_caches[@]}"; do
                local name="${entry%%:*}"
                local path="${entry#*:}"
                if [[ -d "$path" ]]; then
                    local size_bytes
                    size_bytes=$(dir_size_bytes "$path")
                    rm -rf "$path"/* 2>/dev/null
                    freed=$(( freed + size_bytes ))
                    echo -e "    ${GREEN}Cleaned: $name${NC}"
                fi
            done
        else
            echo -e "  ${GRAY}Skipped.${NC}"
        fi
        echo ""
    fi

    # Electron app caches
    local electron_caches=()

    if [[ "$(uname)" == "Darwin" ]]; then
        electron_caches=(
            "Discord:$HOME/Library/Application Support/discord/Cache"
            "Slack:$HOME/Library/Application Support/Slack/Cache"
            "VS Code:$HOME/Library/Application Support/Code/Cache"
            "VS Code CachedData:$HOME/Library/Application Support/Code/CachedData"
            "Figma:$HOME/Library/Application Support/Figma/Cache"
            "Spotify:$HOME/Library/Application Support/Spotify/PersistentCache"
        )
    else
        electron_caches=(
            "Discord:$HOME/.config/discord/Cache"
            "Slack:$HOME/.config/Slack/Cache"
            "VS Code:$HOME/.config/Code/Cache"
            "VS Code CachedData:$HOME/.config/Code/CachedData"
            "Figma:$HOME/.config/Figma/Cache"
            "Spotify:$HOME/.cache/spotify/Data"
        )
    fi

    echo -e "${YELLOW}[Electron / App Caches]${NC}"
    echo ""

    local electron_total=0

    for entry in "${electron_caches[@]}"; do
        local name="${entry%%:*}"
        local path="${entry#*:}"

        if [[ -d "$path" ]]; then
            local size_bytes
            size_bytes=$(dir_size_bytes "$path")
            electron_total=$(( electron_total + size_bytes ))

            echo -e "  ${WHITE}$name${NC}  $(format_size $size_bytes)"
            echo -e "    ${GRAY}$path${NC}"
        fi
    done

    echo ""
    echo -e "  Subtotal: $(format_size $electron_total)"
    echo ""

    if [[ "$MODE" != "scan" ]] && [[ $electron_total -gt 0 ]]; then
        if confirm "Clean all Electron/app caches ($(format_size $electron_total))?"; then
            for entry in "${electron_caches[@]}"; do
                local name="${entry%%:*}"
                local path="${entry#*:}"
                if [[ -d "$path" ]]; then
                    local size_bytes
                    size_bytes=$(dir_size_bytes "$path")
                    rm -rf "$path"/* 2>/dev/null
                    freed=$(( freed + size_bytes ))
                    echo -e "    ${GREEN}Cleaned: $name${NC}"
                fi
            done
        else
            echo -e "  ${GRAY}Skipped.${NC}"
        fi
        echo ""
    fi

    # Temp files
    echo -e "${YELLOW}[Temp Files (> $TEMP_AGE_DAYS days old)]${NC}"
    echo ""

    local tmp_dir="${TMPDIR:-/tmp}"

    if [[ -d "$tmp_dir" ]]; then
        local old_temp_size=0
        local old_temp_count=0

        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local fsize
            if stat --format='%s' "$file" &>/dev/null; then
                fsize=$(stat --format='%s' "$file" 2>/dev/null || echo 0)
            else
                fsize=$(stat -f '%z' "$file" 2>/dev/null || echo 0)
            fi
            old_temp_size=$(( old_temp_size + fsize ))
            old_temp_count=$(( old_temp_count + 1 ))
        done < <(find "$tmp_dir" -maxdepth 2 -type f -mtime "+${TEMP_AGE_DAYS}" -user "$(whoami)" 2>/dev/null)

        echo -e "  Temp dir: $tmp_dir"
        echo -e "  Old files (> $TEMP_AGE_DAYS days): $old_temp_count files, $(format_size $old_temp_size)"

        if [[ "$MODE" != "scan" ]] && [[ $old_temp_size -gt 0 ]]; then
            if confirm "Clean old temp files ($(format_size $old_temp_size))?"; then
                find "$tmp_dir" -maxdepth 2 -type f -mtime "+${TEMP_AGE_DAYS}" -user "$(whoami)" -delete 2>/dev/null
                freed=$(( freed + old_temp_size ))
                echo -e "    ${GREEN}Cleaned $old_temp_count temp files.${NC}"
            else
                echo -e "  ${GRAY}Skipped.${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "  ${WHITE}App cleaner freed: $(format_size $freed)${NC}"
    echo ""

    TOTAL_FREED=$(( TOTAL_FREED + freed ))
}

# ============================================================
# MAIN
# ============================================================

# Before metrics
BEFORE_FREE_KB=0
if [[ "$(uname)" == "Darwin" ]]; then
    BEFORE_FREE_KB=$(df -k / | tail -1 | awk '{print $4}')
else
    BEFORE_FREE_KB=$(df -k / | tail -1 | awk '{print $4}')
fi

START_TIME=$(date +%s)

# Banner
echo ""
echo -e "${CYAN}  ================================================${NC}"
echo -e "${CYAN}    Claude-Code-PCCleaner (Unix)${NC}"
echo -e "${CYAN}    Full PC Optimization for Developers${NC}"
echo -e "${CYAN}  ================================================${NC}"
echo ""

case "$MODE" in
    scan)       echo -e "  Mode: ${GREEN}SCAN (report only -- nothing will be modified)${NC}" ;;
    clean)      echo -e "  Mode: ${YELLOW}CLEAN (interactive -- will confirm before each action)${NC}" ;;
    aggressive) echo -e "  Mode: ${RED}AGGRESSIVE (auto-confirm -- maximum cleanup)${NC}" ;;
esac

echo -e "  ${GRAY}Time: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "  ${GRAY}User: $(whoami) @ $(hostname)${NC}"
echo -e "  ${GRAY}OS:   $(uname -sr)${NC}"

active_modules=""
$RUN_CACHES    && active_modules+="Caches "
$RUN_BUILDS    && active_modules+="Builds "
$RUN_PROCESSES && active_modules+="Processes "
$RUN_APPS      && active_modules+="Apps "

echo -e "  ${GRAY}Modules: $active_modules${NC}"
echo ""

# Safety confirmation for aggressive mode
if [[ "$MODE" == "aggressive" ]]; then
    echo -e "  ${RED}!! AGGRESSIVE MODE -- All actions will be auto-confirmed !!${NC}"
    echo ""
    read -rp "  Type 'YES' to proceed: " aggressive_confirm
    if [[ "$aggressive_confirm" != "YES" ]]; then
        echo -e "  ${YELLOW}Aborted.${NC}"
        exit 0
    fi
    echo ""
fi

# Execute modules
disk_audit

$RUN_CACHES    && cache_cleaner
$RUN_BUILDS    && build_cleaner
$RUN_PROCESSES && process_audit
$RUN_APPS      && app_cleaner

# After metrics and summary
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  SUMMARY${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

echo -e "  ${GRAY}Duration: ${ELAPSED} seconds${NC}"
echo ""

if [[ "$MODE" != "scan" ]]; then
    AFTER_FREE_KB=$(df -k / | tail -1 | awk '{print $4}')
    DISK_DELTA_KB=$(( AFTER_FREE_KB - BEFORE_FREE_KB ))
    DISK_DELTA_BYTES=$(( DISK_DELTA_KB * 1024 ))

    if [[ $DISK_DELTA_BYTES -gt 0 ]]; then
        echo -e "  ${GREEN}Disk space recovered: +$(format_size $DISK_DELTA_BYTES)${NC}"
    fi

    if [[ $TOTAL_FREED -gt 0 ]]; then
        echo -e "  ${GREEN}Total freed (reported): $(format_size $TOTAL_FREED)${NC}"
    fi
else
    echo -e "  ${GREEN}No changes made (scan mode).${NC}"
    echo -e "  ${GRAY}Run with --clean or --aggressive to take action.${NC}"
fi

echo ""
echo -e "${CYAN}  ================================================${NC}"
echo -e "${CYAN}    Scan complete.${NC}"
echo -e "${CYAN}  ================================================${NC}"
echo ""
