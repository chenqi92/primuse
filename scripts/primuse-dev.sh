#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Primuse.xcodeproj}"
IOS_SCHEME="${IOS_SCHEME:-Primuse}"
MAC_SCHEME="${MAC_SCHEME:-PrimuseMac}"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
MAC_CONFIGURATION="${MAC_CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.welape.yuanyin}"
DEVICE_TIMEOUT="${DEVICE_TIMEOUT:-120}"
DEVICE_DISCOVERY_TIMEOUT="${DEVICE_DISCOVERY_TIMEOUT:-15}"

IOS_DERIVED_DATA="${IOS_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/iOS}"
MAC_DERIVED_DATA="${MAC_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/macOS}"
IOS_APP_PATH="${IOS_APP_PATH:-$IOS_DERIVED_DATA/Build/Products/$IOS_CONFIGURATION-iphoneos/Primuse.app}"
MAC_APP_PATH="${MAC_APP_PATH:-$MAC_DERIVED_DATA/Build/Products/$MAC_CONFIGURATION/Primuse.app}"

DEVICE_TEMP_DIR=""
DEVICE_JSON=""
DEVICE_CORE_ID=""
DEVICE_UDID=""
DEVICE_NAME=""
DEVICE_MODEL=""
DEVICE_OS=""

usage() {
    cat <<'EOF'
用法：
  scripts/primuse-dev.sh
  scripts/primuse-dev.sh ios-clean
  scripts/primuse-dev.sh ios-overwrite
  scripts/primuse-dev.sh iphone-clean
  scripts/primuse-dev.sh iphone-overwrite
  scripts/primuse-dev.sh devices
  scripts/primuse-dev.sh mac

操作：
  ios-clean         编译后卸载并重新安装到 iPhone/iPad，会清除 App 本地数据
  ios-overwrite     编译后直接覆盖安装到 iPhone/iPad，保留 App 本地数据
  iphone-clean      ios-clean 的兼容别名
  iphone-overwrite  ios-overwrite 的兼容别名
  devices           检查当前可用于开发的 iPhone/iPad
  mac               编译并启动 macOS App

可选环境变量：
  DEVICE_ID               目标设备名称、CoreDevice ID 或硬件 UDID；未设置时自动发现
  IOS_CONFIGURATION       iOS 构建配置，默认 Debug
  MAC_CONFIGURATION       macOS 构建配置，默认 Debug
  IOS_DERIVED_DATA        iOS DerivedData 路径
  MAC_DERIVED_DATA        macOS DerivedData 路径
  DEVICE_TIMEOUT          devicectl 超时秒数，默认 120
  DEVICE_DISCOVERY_TIMEOUT 设备发现单次超时秒数，默认 15
EOF
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "缺少命令：$command_name" >&2
        exit 1
    fi
}

ensure_project_exists() {
    if [[ ! -d "$PROJECT_PATH" ]]; then
        echo "找不到 Xcode 工程：$PROJECT_PATH" >&2
        exit 1
    fi
}

cleanup_device_temp() {
    if [[ -z "$DEVICE_TEMP_DIR" || ! -d "$DEVICE_TEMP_DIR" ]]; then
        return
    fi

    if [[ -f "$DEVICE_JSON" ]]; then
        rm -f "$DEVICE_JSON"
    fi
    rmdir "$DEVICE_TEMP_DIR" 2>/dev/null || true
    DEVICE_TEMP_DIR=""
    DEVICE_JSON=""
}

trap cleanup_device_temp EXIT

plist_value() {
    /usr/bin/plutil -extract "$1" raw "$DEVICE_JSON" 2>/dev/null || true
}

fetch_device_details() {
    local requested_id="$1"
    local attempt=1

    while [[ $attempt -le 3 ]]; do
        rm -f "$DEVICE_JSON"
        if xcrun devicectl device info details \
            --device "$requested_id" \
            --quiet \
            --timeout "$DEVICE_DISCOVERY_TIMEOUT" \
            --json-output "$DEVICE_JSON"; then
            return 0
        fi

        if [[ $attempt -lt 3 ]]; then
            echo "设备详情暂不可用，正在重试（$((attempt + 1))/3）……"
            sleep 1
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

load_ios_devices() {
    IOS_DEVICE_NAMES=()
    IOS_DEVICE_MODELS=()
    IOS_DEVICE_OSES=()
    IOS_DEVICE_TRANSPORTS=()
    IOS_DEVICE_CORE_IDS=()
    IOS_DEVICE_UDIDS=()
    IOS_DEVICE_READY=()
    IOS_DEVICE_REASONS=()

    echo "正在读取 iPhone/iPad 设备列表……"
    local candidate_ids=()
    if [[ -n "${DEVICE_ID:-}" ]]; then
        candidate_ids+=("$DEVICE_ID")
    else
        local xctrace_output
        if ! xctrace_output="$(xcrun xctrace list devices 2>/dev/null)"; then
            echo "无法读取 Xcode 设备列表。请检查 Xcode 命令行工具和设备连接。" >&2
            exit 1
        fi

        local in_device_section="false"
        local line
        local udid_pattern='[(]([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})[)][[:space:]]*$'
        while IFS= read -r line; do
            if [[ "$line" == "== Devices ==" || "$line" == "== Devices Offline ==" ]]; then
                in_device_section="true"
                continue
            fi
            if [[ "$line" == "== Simulators ==" ]]; then
                break
            fi
            if [[ "$line" == "=="* ]]; then
                in_device_section="false"
                continue
            fi
            if [[ "$in_device_section" == "true" && "$line" =~ $udid_pattern ]]; then
                candidate_ids+=("${BASH_REMATCH[1]}")
            fi
        done <<< "$xctrace_output"
    fi

    if [[ ${#candidate_ids[@]} -eq 0 ]]; then
        return
    fi

    DEVICE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/primuse-devices.XXXXXX")"
    DEVICE_JSON="$DEVICE_TEMP_DIR/device.json"

    local index
    local platform
    local reality
    local name
    local model
    local os_version
    local core_id
    local udid
    local pairing_state
    local tunnel_state
    local transport_type
    local developer_mode
    local ddi_available
    local ready
    local reason

    for ((index = 0; index < ${#candidate_ids[@]}; index++)); do
        if ! fetch_device_details "${candidate_ids[$index]}"; then
            if [[ -n "${DEVICE_ID:-}" ]]; then
                echo "无法读取目标设备详情：$DEVICE_ID" >&2
                exit 1
            fi
            echo "跳过无法读取详情的设备：${candidate_ids[$index]}" >&2
            continue
        fi

        platform="$(plist_value "result.hardwareProperties.platform")"
        reality="$(plist_value "result.hardwareProperties.reality")"
        if [[ "$platform" != "iOS" || "$reality" != "physical" ]]; then
            continue
        fi

        name="$(plist_value "result.deviceProperties.name")"
        model="$(plist_value "result.hardwareProperties.marketingName")"
        os_version="$(plist_value "result.deviceProperties.osVersionNumber")"
        core_id="$(plist_value "result.identifier")"
        udid="$(plist_value "result.hardwareProperties.udid")"
        pairing_state="$(plist_value "result.connectionProperties.pairingState")"
        tunnel_state="$(plist_value "result.connectionProperties.tunnelState")"
        transport_type="$(plist_value "result.connectionProperties.transportType")"
        developer_mode="$(plist_value "result.deviceProperties.developerModeStatus")"
        ddi_available="$(plist_value "result.deviceProperties.ddiServicesAvailable")"

        ready="false"
        reason=""
        if [[ "$pairing_state" != "paired" ]]; then
            reason="未配对"
        elif [[ "$tunnel_state" != "connected" ]]; then
            reason="未连接"
        elif [[ "$developer_mode" != "enabled" ]]; then
            reason="Developer Mode 未启用"
        elif [[ "$ddi_available" != "true" ]]; then
            reason="开发服务未就绪"
        elif [[ -z "$core_id" || -z "$udid" ]]; then
            reason="缺少设备标识"
        else
            ready="true"
        fi

        IOS_DEVICE_NAMES+=("$name")
        IOS_DEVICE_MODELS+=("$model")
        IOS_DEVICE_OSES+=("$os_version")
        IOS_DEVICE_TRANSPORTS+=("$transport_type")
        IOS_DEVICE_CORE_IDS+=("$core_id")
        IOS_DEVICE_UDIDS+=("$udid")
        IOS_DEVICE_READY+=("$ready")
        IOS_DEVICE_REASONS+=("$reason")
    done

    cleanup_device_temp
}

print_ios_device() {
    local index="$1"
    local transport="${IOS_DEVICE_TRANSPORTS[$index]}"
    case "$transport" in
        wired) transport="USB" ;;
        localNetwork) transport="Wi-Fi" ;;
        "") transport="未知连接" ;;
    esac

    printf "%s — %s — iOS/iPadOS %s — %s — %s" \
        "${IOS_DEVICE_NAMES[$index]}" \
        "${IOS_DEVICE_MODELS[$index]}" \
        "${IOS_DEVICE_OSES[$index]}" \
        "$transport" \
        "${IOS_DEVICE_UDIDS[$index]}"
}

select_ios_device_at_index() {
    local index="$1"
    DEVICE_NAME="${IOS_DEVICE_NAMES[$index]}"
    DEVICE_MODEL="${IOS_DEVICE_MODELS[$index]}"
    DEVICE_OS="${IOS_DEVICE_OSES[$index]}"
    DEVICE_CORE_ID="${IOS_DEVICE_CORE_IDS[$index]}"
    DEVICE_UDID="${IOS_DEVICE_UDIDS[$index]}"

    echo "目标设备：${DEVICE_NAME} — ${DEVICE_MODEL} — iOS/iPadOS ${DEVICE_OS}"
    echo "Xcode 构建 UDID：${DEVICE_UDID}"
}

show_ios_devices() {
    load_ios_devices

    if [[ ${#IOS_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现当前在线的物理 iPhone 或 iPad。" >&2
        return 1
    fi

    echo
    echo "已发现的 iPhone/iPad："
    local index
    for ((index = 0; index < ${#IOS_DEVICE_NAMES[@]}; index++)); do
        printf "%s" "- "
        print_ios_device "$index"
        if [[ "${IOS_DEVICE_READY[$index]}" == "true" ]]; then
            echo "（可用）"
        else
            printf "（不可用：%s）\n" "${IOS_DEVICE_REASONS[$index]}"
        fi
    done
}

select_ios_device() {
    load_ios_devices

    if [[ ${#IOS_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现物理 iPhone 或 iPad。请连接并解锁设备后重试。" >&2
        exit 1
    fi

    local index
    local match_index=-1
    local match_count=0
    if [[ -n "${DEVICE_ID:-}" ]]; then
        for ((index = 0; index < ${#IOS_DEVICE_NAMES[@]}; index++)); do
            if [[ "$DEVICE_ID" == "${IOS_DEVICE_NAMES[$index]}" || \
                  "$DEVICE_ID" == "${IOS_DEVICE_CORE_IDS[$index]}" || \
                  "$DEVICE_ID" == "${IOS_DEVICE_UDIDS[$index]}" ]]; then
                match_index="$index"
                match_count=$((match_count + 1))
            fi
        done

        if [[ $match_count -eq 0 ]]; then
            echo "找不到 DEVICE_ID 指定的 iPhone/iPad：$DEVICE_ID" >&2
            exit 1
        fi
        if [[ $match_count -gt 1 ]]; then
            echo "DEVICE_ID 匹配到多个设备，请改用 CoreDevice ID 或硬件 UDID。" >&2
            exit 1
        fi
        if [[ "${IOS_DEVICE_READY[$match_index]}" != "true" ]]; then
            echo "目标设备当前不可用：${IOS_DEVICE_REASONS[$match_index]}。" >&2
            echo "请解锁、信任此 Mac，并等待 Xcode 完成设备准备。" >&2
            exit 1
        fi

        select_ios_device_at_index "$match_index"
        return
    fi

    local ready_indices=()
    for ((index = 0; index < ${#IOS_DEVICE_NAMES[@]}; index++)); do
        if [[ "${IOS_DEVICE_READY[$index]}" == "true" ]]; then
            ready_indices+=("$index")
        fi
    done

    if [[ ${#ready_indices[@]} -eq 0 ]]; then
        echo "没有已连接且可用于开发的 iPhone/iPad。" >&2
        for ((index = 0; index < ${#IOS_DEVICE_NAMES[@]}; index++)); do
            printf "%s" "- " >&2
            print_ios_device "$index" >&2
            printf "（%s）\n" "${IOS_DEVICE_REASONS[$index]}" >&2
        done
        echo "请解锁设备、信任此 Mac、启用 Developer Mode，并等待 Xcode 完成设备准备。" >&2
        exit 1
    fi

    if [[ ${#ready_indices[@]} -eq 1 ]]; then
        select_ios_device_at_index "${ready_indices[0]}"
        return
    fi

    echo
    echo "可用的 iPhone/iPad："
    local selection_number
    for ((index = 0; index < ${#ready_indices[@]}; index++)); do
        selection_number=$((index + 1))
        printf "%d) " "$selection_number"
        print_ios_device "${ready_indices[$index]}"
        echo
    done

    echo
    printf "请选择目标设备："
    local selection
    if ! IFS= read -r selection; then
        echo
        echo "未选择设备，操作已取消。" >&2
        exit 1
    fi
    if [[ ! "$selection" =~ ^[0-9]+$ || \
          "$selection" -lt 1 || \
          "$selection" -gt ${#ready_indices[@]} ]]; then
        echo "无效的设备选项：$selection" >&2
        exit 1
    fi

    select_ios_device_at_index "${ready_indices[$((selection - 1))]}"
}

build_ios() {
    echo
    echo "正在为 ${DEVICE_NAME} 编译 App（${IOS_CONFIGURATION}）……"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$IOS_SCHEME" \
        -configuration "$IOS_CONFIGURATION" \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$IOS_DERIVED_DATA" \
        -allowProvisioningUpdates \
        build

    if [[ ! -d "$IOS_APP_PATH" ]]; then
        echo "编译完成，但找不到 App：$IOS_APP_PATH" >&2
        exit 1
    fi
}

install_ios() {
    echo
    echo "正在安装到 ${DEVICE_NAME}……"
    xcrun devicectl device install app \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        "$IOS_APP_PATH"
}

launch_ios() {
    echo
    echo "正在启动 ${DEVICE_NAME} 上的 App……"
    if xcrun devicectl device process launch \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --terminate-existing \
        "$BUNDLE_ID"; then
        echo "${DEVICE_NAME} 上的 App 已安装并启动。"
        return
    fi

    echo "App 已安装，但自动启动失败。请解锁 ${DEVICE_NAME} 后手动启动，或重新运行此操作。" >&2
    return 1
}

ios_clean_install() {
    select_ios_device

    echo
    echo "警告：下一步会卸载 ${BUNDLE_ID}，并删除它在 ${DEVICE_NAME} 上的全部本地数据。"
    printf "输入 DELETE 继续完全重装："
    local confirmation
    if ! IFS= read -r confirmation; then
        echo
        echo "未确认删除，操作已取消；现有 App 和数据未变更。"
        return
    fi
    if [[ "$confirmation" != "DELETE" ]]; then
        echo "未确认删除，操作已取消；现有 App 和数据未变更。"
        return
    fi

    build_ios

    echo
    echo "正在卸载旧 App 和本地数据……"
    if ! xcrun devicectl device uninstall app \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        "$BUNDLE_ID"; then
        echo "卸载失败，已停止安装，避免把覆盖安装误当成完全重装。" >&2
        return 1
    fi

    install_ios
    launch_ios
}

ios_overwrite_install() {
    select_ios_device
    build_ios

    # 不执行 uninstall，系统会替换 App 包并保留现有数据容器。
    install_ios
    launch_ios
}

build_and_launch_mac() {
    echo
    echo "正在编译 macOS App（${MAC_CONFIGURATION}）……"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$MAC_SCHEME" \
        -configuration "$MAC_CONFIGURATION" \
        -destination "platform=macOS" \
        -derivedDataPath "$MAC_DERIVED_DATA" \
        build

    if [[ ! -d "$MAC_APP_PATH" ]]; then
        echo "编译完成，但找不到 App：$MAC_APP_PATH" >&2
        exit 1
    fi

    echo
    echo "正在启动 macOS App……"
    /usr/bin/open -n "$MAC_APP_PATH"
    echo "macOS App 已启动：$MAC_APP_PATH"
}

interactive_action() {
    echo "Primuse 开发工具"
    echo
    echo "1) 完全重装到 iPhone/iPad（清除 App 本地数据）"
    echo "2) 覆盖安装到 iPhone/iPad（保留 App 本地数据）"
    echo "3) 编译并启动 macOS"
    echo "4) 检查 iPhone/iPad 连接状态"
    echo "q) 退出"
    echo
    printf "请选择操作："

    local selection
    if ! IFS= read -r selection; then
        echo
        SELECTED_ACTION="quit"
        return
    fi

    case "$selection" in
        1) SELECTED_ACTION="ios-clean" ;;
        2) SELECTED_ACTION="ios-overwrite" ;;
        3) SELECTED_ACTION="mac" ;;
        4) SELECTED_ACTION="devices" ;;
        q|Q) SELECTED_ACTION="quit" ;;
        *)
            echo "无效选项：$selection" >&2
            exit 1
            ;;
    esac
}

main() {
    local action="${1:-}"

    if [[ "$action" == "--help" || "$action" == "-h" ]]; then
        usage
        return
    fi

    if [[ $# -gt 1 ]]; then
        usage >&2
        exit 1
    fi

    if [[ -z "$action" ]]; then
        SELECTED_ACTION=""
        interactive_action
        action="$SELECTED_ACTION"
    fi

    if [[ "$action" == "quit" ]]; then
        echo "已退出。"
        return
    fi

    require_command xcodebuild
    ensure_project_exists

    case "$action" in
        ios-clean|iphone-clean)
            require_command xcrun
            require_command plutil
            ios_clean_install
            ;;
        ios-overwrite|iphone-overwrite)
            require_command xcrun
            require_command plutil
            ios_overwrite_install
            ;;
        devices)
            require_command xcrun
            require_command plutil
            show_ios_devices
            ;;
        mac)
            build_and_launch_mac
            ;;
        *)
            echo "未知操作：$action" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
