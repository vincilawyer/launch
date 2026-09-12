#!/bin/zsh

# Select an installed macOS SDK that the active Swift compiler can actually
# import. Command Line Tools upgrades can leave MacOSX.sdk pointing at a newer
# patch-level interface than swiftc, while an older compatible SDK remains
# installed beside it.
resolve_compatible_macos_sdk() {
    emulate -L zsh
    setopt local_options null_glob

    local project_directory="$1"
    local probe_source="$2"
    local compiler
    compiler="$(/usr/bin/xcrun --find swiftc)" || return 1

    local -a candidates
    if [[ -n "${SDKROOT:-}" ]]; then
        candidates+=("${SDKROOT}")
    fi
    local active_sdk
    active_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" || return 1
    candidates+=("${active_sdk}")
    local developer_directory
    developer_directory="$(/usr/bin/xcode-select -p)" || return 1
    candidates+=(
        ${developer_directory}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk(N)
    )
    candidates+=(/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(N))

    local -A seen
    local candidate canonical candidate_cache
    integer candidate_index=0
    for candidate in "${candidates[@]}"; do
        [[ -d "${candidate}" ]] || continue
        canonical="${candidate:A}"
        if (( ${+seen[${canonical}]} )); then
            continue
        fi
        seen[${canonical}]=1
        candidate_index+=1
        candidate_cache="${project_directory}/.build/SDKProbeModuleCache/${candidate_index}"
        mkdir -p "${candidate_cache}"
        if "${compiler}" \
            -sdk "${canonical}" \
            -module-cache-path "${candidate_cache}" \
            -typecheck "${probe_source}" \
            >/dev/null 2>&1; then
            print -r -- "${canonical}"
            return 0
        fi
    done

    print -u2 -- "No installed macOS SDK is compatible with ${compiler}."
    return 1
}
