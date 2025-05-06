#!/usr/bin/env bash

declare log_prefix=""

debug()
{
    echo "[DEBUG] $log_prefix: $*"
}

info()
{
    echo "[INFO ] $log_prefix: $*"
}

warn()
{
    echo "[WARN ] $log_prefix: $*"
}

error()
{
    echo "[ERROR] $log_prefix: $*"
}

fatal()
{
    error "$*"
    exit 1
}

check_command()
{
    command -v "$1" &>/dev/null || fatal "\`$1\` is missing"
}

check_envvar()
{
    [[ -v "$1" ]] || fatal "\`$1\` is unset"
}

check()
{
    check_command go
    check_command jq

    check_envvar GITHUB_TOKEN
}

pack()
{
    declare -n r=$1

    local tarball_url=$2

    temp_dir="$(mktemp -d)"
    debug "temp_dir=$temp_dir"

    (
        cd "$temp_dir" || fatal "failed to switch to the temporary directory"

        info "fetching the tarball..."
        if ! ret=$(
            curl \
                --location --silent --show-error --fail-with-body \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                "$tarball_url" -o "source.tar.gz" 2>&1
        ); then
            error "$ret"
            fatal "failed to fetch the tarball"
        fi

        mkdir source
        tar -x --strip-components 1 -C source -f source.tar.gz

        cd source || fatal "failed to switch to the source directory"
        cd "${r["path"]}" || fatal "failed to switch to the main module directory"

        if [[ ! -f go.mod ]]; then
            fatal "there is no Go module at the specified path"
        fi

        info "downloading the dependencies..."

        export GOFLAGS="-modcacherw"
        export GOMODCACHE="$temp_dir/go-mod"

        go mod download
        mapfile -t mod_paths < <(find . -mindepth 2 -name go.mod -print)
        for mod_path in "${mod_paths[@]}"; do
            local mod_dir_path="${mod_path%/go.mod}"
            cd "$mod_dir_path" || "failed to enter the mod directory $mod_dir_path"
            go mod download
        done

        find "${GOMODCACHE}/cache/download" -type f -name '*.zip' -delete

        info "compressing the dependencies..."

        cd "$temp_dir" || fatal "failed to switch back to the temporary directory"
        XZ_OPT='-T0 -9' \
            tar --owner 0 --group 0 --posix -acf go-mod.tar.xz go-mod
    )

    cp "$temp_dir/go-mod.tar.xz" "${r["name"]}-deps.tar.xz"
}

get_tarball_github()
{
    declare -n r=$1

    local ret

    info "querying tags..."

    local tags
    if ! ret=$(
        curl \
            --silent --show-error --fail-with-body \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.${r["host"]}/repos/${r["owner"]}/${r["repo"]}/tags" 2>&1
    ); then
        error "$ret"
        fatal "failed to get the tags"
    fi
    tags="$ret"

    local tag
    if ! ret="$(jq '.[1]' <<<"$tags" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tags"
    fi
    tag="$ret"

    if [[ "$tag" == "null" ]]; then
        fatal "there are no tags"
    fi

    local version
    if ! ret="$(jq -r '.["name"]' <<<"$tag" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the version of the latest tag"
    fi
    version="$ret"

    info "version: $version"

    local tarball_url
    if ! ret="$(jq -r '.["tarball_url"]' <<<"$tag" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tarball URL of the latest tag"
    fi
    tarball_url="$ret"

    res="$tarball_url"
}

get_tarball()
{
    declare -n r=$1

    case ${r["forge"]} in
    "github")
        get_tarball_github record
        ;;
    *)
        warn "unknown forge ${r["forge"]}"
        return 1
        ;;
    esac
    tarball_url="$res"

    res="$tarball_url"
}

process()
{
    declare -n r=$1

    export log_prefix="${r["name"]}"

    info "url: https://${r["host"]}/${r["owner"]}/${r["repo"]}"

    if ! get_tarball record; then
        warn "failed to get the tarball"
        return
    fi
    tarball_url="$res"

    info "tarball_url: $tarball_url"

    pack record "$tarball_url"
}

check

{
    declare -A record

    read -ra header
    while read -ra row; do
        for ((i = 0; i < "${#header[@]}"; i++)); do
            record[${header[$i]}]="${row[$i]}"
        done
        process record
    done
} <go.csv
