#!/usr/bin/env bash

ROOT="$(dirname "$(realpath "$0")")"

declare log_prefix=""
declare log_debug_enabled=false

log()
{
    local level=$1
    shift

    if [[ -n "$log_prefix" ]]; then
        echo "$level $log_prefix: $*"
    else
        echo "$level $*"
    fi
}

debug()
{
    if $log_debug_enabled; then
        log "[DEBUG]" "$*"
    fi
}

info()
{
    log "[INFO ]" "$*"
}

warn()
{
    log "[WARN ]" "$*"
}

error()
{
    log "[ERROR]" "$*"
}

fatal()
{
    error "$*"
    exit 1
}

function handle_args()
{
    for arg in "$@"; do
        shift
        case "$arg" in
        "--debug") set -- "$@" '-d' ;;
        "--help") set -- "$@" '-h' ;;
        *) set -- "$@" "$arg" ;;
        esac
    done

    while getopts ":dh" opt; do
        case $opt in
        d) log_debug_enabled=true ;;
        h)
            echo "$0 usage:"
            echo "    -d, --debug Enable debug messages"
            echo "    -h, --help  Show the usage message"
            exit 0
            ;;
        *) warn "unknown option $OPTARG" ;;
        esac
    done
}

check_command()
{
    command -v "$1" &>/dev/null || fatal "\`$1\` is missing"
}

check_envvar()
{
    [[ -v "$1" ]] || fatal "\`$1\` is unset"
}

run_checks()
{
    check_command curl
    check_command go
    check_command jq

    check_envvar GITHUB_TOKEN

    if [[ -n "$GITLAB_TOKEN" ]]; then
        export GITLAB_AUTH_HEADER="PRIVATE-TOKEN: $GITLAB_TOKEN"
    elif [[ -n "$CI_JOB_TOKEN" ]]; then
        export GITLAB_AUTH_HEADER="JOB-TOKEN: $CI_JOB_TOKEN"
    else
        fatal "\`GITLAB_TOKEN\` is unset"
    fi

    if [[ -z "$GITLAB_PROJECT_ID" ]]; then
        if [[ -n "$CI_PROJECT_ID" ]]; then
            export GITLAB_PROJECT_ID="$CI_PROJECT_ID"
        else
            fatal "\`GITLAB_PROJECT_ID\` is unset"
        fi
    fi
}

get_packages()
{
    declare -n p=$1

    local ret

    info "querying the package registry..."

    local metadata
    if ! ret=$(
        curl --location --silent --show-error --fail-with-body \
            --header "$GITLAB_AUTH_HEADER" \
            "https://gitlab.com/api/v4/projects/$GITLAB_PROJECT_ID/packages" 2>&1
    ); then
        error "$ret"
        fatal "failed to fetch the packages metadata"
    fi
    metadata="$ret"

    [[ $metadata == "[]" ]] && return

    local name_version_pairs
    if ! ret=$(
        jq -r '.[] | [.name, .version] | join(" ")' <<<"$metadata"
    ); then
        error "$ret"
        fatal "failed to parse the name-version pairs from the packages metadata"
    fi
    name_version_pairs="$ret"

    {
        while read -r name version; do
            p["$name"]+=" $version"
        done
    } <<<"$name_version_pairs"
}

pack()
{
    declare -n r=$1
    declare -n t=$2

    local ret

    temp_dir="$(mktemp -d)"
    debug "temp_dir=$temp_dir"

    cd "$temp_dir" || fatal "failed to switch to the temporary directory"

    info "fetching the tarball..."
    if ! ret=$(
        curl \
            --location --silent --show-error --fail-with-body \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${t["tarball_url"]}" -o "source.tar.gz" 2>&1
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

    info "downloading the dependencies (\`go mod ${r["method"]}\`)..."

    local deps_dir_name
    case "${r["method"]}" in
    "download")
        deps_dir_name="go-mod"

        export GOFLAGS="-modcacherw"
        export GOMODCACHE="$temp_dir/$deps_dir_name"

        go mod download
        mapfile -t mod_paths < <(find . -mindepth 2 -name go.mod -print)
        for mod_path in "${mod_paths[@]}"; do
            local mod_dir_path="${mod_path%/go.mod}"
            cd "$mod_dir_path" || fatal "failed to enter the mod directory $mod_dir_path"
            go mod download
        done

        find "${GOMODCACHE}/cache/download" -type f -name '*.zip' -delete
        ;;
    "vendor")
        deps_dir_name="vendor"

        go mod vendor -o "$temp_dir/$deps_dir_name" &>/dev/null
        ;;
    *)
        fatal "unknown method ${r["method"]}"
        ;;
    esac

    info "compressing the dependencies..."

    cd "$temp_dir" || fatal "failed to switch back to the temporary directory"

    export XZ_OPT='-T0 -9'

    if ! ret=$(
        tar \
            --sort=name \
            --owner 0 --group 0 --numeric-owner --posix --mtime="1970-01-01" \
            --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            -acf "$deps_dir_name.tar.xz" "$deps_dir_name" 2>&1
    ); then
        error "$ret"
        fatal "failed to compress the dependencies"
    fi

    cd "$ROOT" || fatal "failed to switch back to the root directory"

    cp "$temp_dir/$deps_dir_name.tar.xz" "${r["name"]}-${t["version"]}-deps.tar.xz"
}

publish()
{
    declare -n r=$1
    declare -n t=$2

    local file="${r["name"]}-${t["version"]}-deps.tar.xz"
    local url="https://gitlab.com/api/v4/projects/$GITLAB_PROJECT_ID/packages/generic/${r["name"]}/${t["version"]}/$file"

    info "publishing the package..."

    if ! ret=$(
        curl \
            --location --silent --show-error --fail-with-body \
            --header "$GITLAB_AUTH_HEADER" \
            --upload-file "$file" "$url" 2>&1
    ); then
        error "$ret"
        fatal "failed to publish the package"
    fi
}

get_tag_github()
{
    declare -n r=$1
    declare -n t=$2

    local ret

    info "querying the latest tag..."

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

    local latest_tag
    if ! ret="$(jq '.[1]' <<<"$tags" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tags"
    fi
    latest_tag="$ret"

    if [[ "$latest_tag" == "null" ]]; then
        fatal "there are no tags"
    fi

    local version
    if ! ret="$(jq -r '.["name"]' <<<"$latest_tag" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the version of the latest tag"
    fi
    version="$ret"

    local tarball_url
    if ! ret="$(jq -r '.["tarball_url"]' <<<"$latest_tag" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tarball URL of the latest tag"
    fi
    tarball_url="$ret"

    t["version"]="$version"
    t["tarball_url"]="$tarball_url"
}

get_tag()
{
    declare -n r=$1

    case ${r["forge"]} in
    "github")
        get_tag_github record tag
        ;;
    *)
        warn "unknown forge ${r["forge"]}"
        return 1
        ;;
    esac
}

process_record()
{
    declare -n r=$1
    # shellcheck disable=SC2178
    declare -n p=$2

    export log_prefix="${r["name"]}"

    info "url: https://${r["host"]}/${r["owner"]}/${r["repo"]}"

    declare -A tag
    if ! get_tag record tag; then
        warn "failed to get the tag"
        return
    fi

    info "version: ${tag["version"]}"
    info "tarball_url: ${tag["tarball_url"]}"

    read -r -a registry_versions <<<"${p["${r["name"]}"]}"
    for registry_version in "${registry_versions[@]}"; do
        if [[ "${tag["version"]}" == "$registry_version" ]]; then
            info "the latest version is already in the registry; skipping"
            return
        fi
    done

    pack record tag
    publish record tag
}

process_records()
{
    {
        declare -A record

        read -ra header
        while read -ra row; do
            for ((i = 0; i < "${#header[@]}"; i++)); do
                # shellcheck disable=SC2034
                record[${header[$i]}]="${row[$i]}"
            done
            process_record record packages
        done
    } <go.csv
}

main()
{
    handle_args "$@"

    run_checks

    # shellcheck disable=SC2034
    declare -A packages
    get_packages packages

    process_records
}

main "$@"
