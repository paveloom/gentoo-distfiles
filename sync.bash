#!/usr/bin/env bash

ROOT="$(dirname "$(realpath "$0")")"

declare log_prefix=""

declare option_debug_enabled=false
declare option_ignore_enabled=false
declare option_package_name=""
declare option_publish_enabled=false

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
    if $option_debug_enabled; then
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
        "--ignore") set -- "$@" '-i' ;;
        "--name") set -- "$@" '-n' ;;
        "--publish") set -- "$@" '-p' ;;
        *) set -- "$@" "$arg" ;;
        esac
    done

    while getopts ":dhin:p" opt; do
        case $opt in
        d) option_debug_enabled=true ;;
        h)
            echo "$0 usage:"
            echo "    -d, --debug   Enable debug messages"
            echo "    -h, --help    Show the usage message"
            echo "    -i, --ignore  Ignore existing packages"
            echo "    -n, --name    Build the package with this name"
            echo "    -p, --publish Publish the packages"
            exit 0
            ;;
        i) option_ignore_enabled=true ;;
        n) option_package_name="$OPTARG" ;;
        p) option_publish_enabled=true ;;
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

fetch_deps()
{
    local temp_dir="$1"

    cd "$temp_dir" || fatal "failed to switch to the temporary directory"

    info "fetching the tarball..."
    if ! ret=$(
        curl \
            --location --silent --show-error --fail-with-body \
            "${rev["tarball_url"]}" -o "source.tar.gz" 2>&1
    ); then
        error "$ret"
        fatal "failed to fetch the tarball"
    fi

    mkdir source
    tar -x --strip-components 1 -C source -f source.tar.gz
}

prepare_deps()
{
    declare -n r=$1

    local temp_dir="$2"

    cd "$temp_dir/source" || fatal "failed to switch to the source directory"

    local prepare_script_path="$ROOT/repos/${r["name"]}/prepare.bash"

    if [[ ! -x "$prepare_script_path" ]]; then
        return
    fi

    info "preparing the source code..."

    "$prepare_script_path"
}

download_deps_go()
{
    declare -n r=$1
    declare -n rev=$2

    local temp_dir="$3"
    local deps_dir_name="$4"

    cd "$temp_dir/source" || fatal "failed to switch to the source directory"
    cd "${r["path"]}" || fatal "failed to switch to the main module directory"

    if [[ ! -f go.mod ]]; then
        fatal "there is no Go module at the specified path"
    fi

    info "downloading the dependencies (\`go mod ${r["method"]}\`)..."

    case "${r["method"]}" in
    "download")
        local go_mod_cache_dir="$temp_dir/$deps_dir_name/go-mod"

        export GOFLAGS="-modcacherw"
        export GOMODCACHE="$go_mod_cache_dir"

        go mod download
        mapfile -t mod_paths < <(find . -mindepth 2 -name go.mod -print)
        for mod_path in "${mod_paths[@]}"; do
            local mod_dir_path="${mod_path%/go.mod}"
            cd "$mod_dir_path" || fatal "failed to enter the mod directory $mod_dir_path"
            go mod download
        done

        find "${go_mod_cache_dir}/cache/download" -type f -name '*.zip' -delete
        ;;
    "vendor")
        local vendor_dir
        case ${r["forge"]} in
        "forgejo")
            vendor_dir="$temp_dir/$deps_dir_name/${r["name"]}/${r["path"]}/vendor"
            ;;
        *)
            vendor_dir="$temp_dir/$deps_dir_name/${r["name"]}-${rev["version"]}/${r["path"]}/vendor"
            ;;
        esac

        go mod vendor -o "$vendor_dir" &>/dev/null
        ;;
    *)
        fatal "unknown method ${r["method"]}"
        ;;
    esac
}

download_deps_rust()
{
    declare -n r=$1
    declare -n rev=$2

    local temp_dir="$3"
    local deps_dir_name="$4"

    local ret

    cd "$temp_dir/source" || fatal "failed to switch to the source directory"
    cd "${r["path"]}" || fatal "failed to switch to the main module directory"

    if [[ ! -f Cargo.toml ]]; then
        fatal "there is no \`Cargo.toml\` at the specified path"
    fi

    info "downloading the dependencies (\`cargo vendor\`)..."

    case "${r["method"]}" in
    "vendor")
        local vendor_dir="$temp_dir/$deps_dir_name/cargo_home/gentoo"

        if ! ret=$(cargo vendor "$vendor_dir" 2>&1);  then
            error "$ret"
            fatal "failed to download the dependencies"
        fi
        ;;
    *)
        fatal "unknown method ${r["method"]}"
        ;;
    esac
}

download_deps()
{
    declare -n r=$1
    declare -n rev=$2

    local temp_dir="$3"
    local deps_dir_name="$4"

    case "${r["lang"]}" in
    "go") download_deps_go record revision "$temp_dir" "$deps_dir_name" ;;
    "rust") download_deps_rust record revision "$temp_dir" "$deps_dir_name" ;;
    *)
        fatal "unknown language ${r["lang"]}"
        ;;
    esac
}

compress_deps()
{
    local temp_dir="$1"
    local deps_dir_name="$2"

    info "compressing the dependencies..."

    cd "$temp_dir" || fatal "failed to switch back to the temporary directory"

    export XZ_OPT='-T0 -9'

    if ! ret=$(
        tar \
            --sort=name \
            --owner 0 --group 0 --numeric-owner --posix --mtime="1970-01-01" \
            --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            -C "$deps_dir_name" . -acf "$deps_dir_name.tar.xz" 2>&1
    ); then
        error "$ret"
        fatal "failed to compress the dependencies"
    fi

    cd "$ROOT" || fatal "failed to switch back to the root directory"
}

pack()
{
    declare -n r=$1
    declare -n rev=$2

    local ret

    temp_dir="$(mktemp -d)"
    debug "temp_dir=$temp_dir"

    fetch_deps "$temp_dir"

    prepare_deps record "$temp_dir"

    local deps_dir_name="deps"

    download_deps record revision "$temp_dir" "$deps_dir_name"

    compress_deps "$temp_dir" "$deps_dir_name"

    cp "$temp_dir/$deps_dir_name.tar.xz" "${r["name"]}-${rev["version"]}-deps.tar.xz"
}

publish()
{
    declare -n r=$1
    declare -n rev=$2

    local file="${r["name"]}-${rev["version"]}-deps.tar.xz"
    local url="https://gitlab.com/api/v4/projects/$GITLAB_PROJECT_ID/packages/generic/${r["name"]}/${rev["version"]}/$file"

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

get_latest_tag()
{
    declare -n r=$1
    declare -n rev=$2

    local ret

    case ${r["forge"]} in
    "github") ;;
    *)
        warn "unknown forge ${r["forge"]}"
        return 1
        ;;
    esac

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
    if ! ret="$(jq '.[0]' <<<"$tags" 2>&1)"; then
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

    version=${version#v}

    local tarball_url
    if ! ret="$(jq -r '.["tarball_url"]' <<<"$latest_tag" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tarball URL of the latest tag"
    fi
    tarball_url="$ret"

    rev["version"]="$version"
    rev["tarball_url"]="$tarball_url"
}

get_latest_commit()
{
    declare -n r=$1
    # shellcheck disable=SC2178
    declare -n rev=$2

    local ret

    case ${r["forge"]} in
    "forgejo" | "github") ;;
    *)
        warn "unknown forge ${r["forge"]}"
        return 1
        ;;
    esac

    info "querying the latest commit..."

    local commits
    if ! ret=$(
        case "${r["forge"]}" in
        "forgejo")
            curl \
                --silent --show-error --fail-with-body \
                "https://${r["host"]}/api/v1/repos/${r["owner"]}/${r["repo"]}/commits?limit=1" 2>&1
            ;;
        "github")
            curl \
                --silent --show-error --fail-with-body \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                "https://api.${r["host"]}/repos/${r["owner"]}/${r["repo"]}/commits?per_page=1" 2>&1
        esac
    ); then
        error "$ret"
        fatal "failed to get the commits"
    fi
    commits="$ret"

    local latest_commit
    if ! ret="$(jq '.[0]' <<<"$commits" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the commits"
    fi
    latest_commit="$ret"

    local latest_commit_sha
    if ! ret="$(jq -r '.["sha"]' <<<"$latest_commit" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the SHA of the latest commit"
    fi
    latest_commit_sha="$ret"

    local latest_commit_date_property
    case ${r["forge"]} in
    "forgejo") latest_commit_date_property=".created" ;;
    "github") latest_commit_date_property=".commit.committer.date" ;;
    esac

    local latest_commit_date
    if ! ret="$(jq -r "$latest_commit_date_property" <<<"$latest_commit" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the created date of the latest commit"
    fi
    latest_commit_date="$ret"

    latest_commit_tarball_url="https://${r["host"]}/${r["owner"]}/${r["repo"]}/archive/${latest_commit_sha}.tar.gz"
    latest_commit_date_parsed="$(date "+%Y%m%d" -d "${latest_commit_date}")"

    info "querying the latest tag..."

    local tags
    if ! ret=$(
        case "${r["forge"]}" in
        "forgejo")
            curl \
                --silent --show-error --fail-with-body \
                "https://${r["host"]}/api/v1/repos/${r["owner"]}/${r["repo"]}/tags?limit=1" 2>&1
            ;;
        "github")
            curl \
                --silent --show-error --fail-with-body \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                "https://api.${r["host"]}/repos/${r["owner"]}/${r["repo"]}/tags?per_page=1" 2>&1
            ;;
        esac
    ); then
        error "$ret"
        fatal "failed to get the tags"
    fi
    tags="$ret"

    local latest_tag
    if ! ret="$(jq '.[0]' <<<"$tags" 2>&1)"; then
        error "$ret"
        fatal "failed to parse the tags"
    fi
    latest_tag="$ret"

    local version
    if [[ ! "$latest_tag" == "null" ]]; then
        local latest_tag_name
        if ! ret="$(jq -r '.["name"]' <<<"$latest_tag" 2>&1)"; then
            error "$ret"
            fatal "failed to parse the name of the latest tag"
        fi
        latest_tag_name="$ret"

        version="${latest_tag_name#v}_pre${latest_commit_date_parsed}"
    else
        version="0_pre${latest_commit_date_parsed}"
    fi

    rev["version"]="$version"
    rev["tarball_url"]="$latest_commit_tarball_url"
}

process_record()
{
    declare -n r=$1
    # shellcheck disable=SC2178
    declare -n p=$2

    export log_prefix="${r["name"]}"

    info "url: https://${r["host"]}/${r["owner"]}/${r["repo"]}"

    declare -A revision

    if [[ "${r["live"]}" == "true" ]]; then
        if ! get_latest_commit record revision; then
            warn "failed to form a revision from the latest commit"
            return
        fi
    else
        if ! get_latest_tag record revision; then
            warn "failed to form a revision from the latest tag"
            return
        fi
    fi

    info "version: ${revision["version"]}"
    info "tarball_url: ${revision["tarball_url"]}"

    if ! $option_ignore_enabled; then
        read -r -a registry_versions <<<"${p["${r["name"]}"]}"
        for registry_version in "${registry_versions[@]}"; do
            if [[ "${revision["version"]}" == "$registry_version" ]]; then
                info "the latest version is already in the registry; skipping"
                return
            fi
        done
    fi

    pack record revision

    if $option_publish_enabled; then
        publish record revision
    fi
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

            if [[ "$option_package_name" == "" || "$option_package_name" == "${record["name"]}" ]]; then
                process_record record packages
            fi
        done
    } <"${ROOT}/repos.csv"
}

main()
{
    handle_args "$@"

    run_checks

    # shellcheck disable=SC2034
    declare -A packages

    if ! $option_ignore_enabled; then
        get_packages packages
    fi

    process_records
}

main "$@"
