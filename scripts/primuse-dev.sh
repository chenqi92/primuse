#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Primuse.xcodeproj}"
IOS_SCHEME="${IOS_SCHEME:-Primuse}"
MAC_SCHEME="${MAC_SCHEME:-PrimuseMac}"
TV_SCHEME="${TV_SCHEME:-PrimuseTV}"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
MAC_CONFIGURATION="${MAC_CONFIGURATION:-Debug}"
TV_CONFIGURATION="${TV_CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.welape.yuanyin}"
TV_BUNDLE_ID="${TV_BUNDLE_ID:-$BUNDLE_ID}"
DEVICE_TIMEOUT="${DEVICE_TIMEOUT:-120}"
DEVICE_DISCOVERY_TIMEOUT="${DEVICE_DISCOVERY_TIMEOUT:-15}"
APP_GROUP_ID="${APP_GROUP_ID:-group.com.welape.yuanyin}"
LOG_OUTPUT_DIR="${LOG_OUTPUT_DIR:-$ROOT_DIR/logs}"
SYNC_TEST_WAIT="${SYNC_TEST_WAIT:-180}"
# 设备上日志轮转最多保留几代（与 App 里 DiagnosticLoggingPolicy.diagnosticLimits 一致）。
LOG_GENERATIONS=4

IOS_DERIVED_DATA="${IOS_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/iOS}"
MAC_DERIVED_DATA="${MAC_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/macOS}"
TV_DERIVED_DATA="${TV_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/tvOS}"
IOS_APP_PATH="${IOS_APP_PATH:-$IOS_DERIVED_DATA/Build/Products/$IOS_CONFIGURATION-iphoneos/Primuse.app}"
IOS_SIMULATOR_APP_PATH="${IOS_SIMULATOR_APP_PATH:-$IOS_DERIVED_DATA/Build/Products/$IOS_CONFIGURATION-iphonesimulator/Primuse.app}"
MAC_APP_PATH="${MAC_APP_PATH:-$MAC_DERIVED_DATA/Build/Products/$MAC_CONFIGURATION/Primuse.app}"
TV_SIMULATOR_APP_PATH="${TV_SIMULATOR_APP_PATH:-$TV_DERIVED_DATA/Build/Products/$TV_CONFIGURATION-appletvsimulator/PrimuseTV.app}"
TV_DEVICE_APP_PATH="${TV_DEVICE_APP_PATH:-$TV_DERIVED_DATA/Build/Products/$TV_CONFIGURATION-appletvos/PrimuseTV.app}"
TV_APP_PATH=""

DEVICE_TEMP_DIR=""
DEVICE_JSON=""
DEVICE_CORE_ID=""
DEVICE_UDID=""
DEVICE_NAME=""
DEVICE_MODEL=""
DEVICE_OS=""
DEVICE_KIND=""
DEVICE_STATE=""
SIMULATOR_WINDOW_SHOWN=""

usage() {
    cat <<'EOF'
用法：
  scripts/primuse-dev.sh              不带参数时显示交互菜单
  scripts/primuse-dev.sh <操作> [参数]

安装与运行
  install           选择 iPhone/iPad，再选覆盖安装或完全重装
  ios-overwrite     编译并覆盖安装到 iPhone/iPad，保留 App 本地数据（别名 iphone-overwrite）
  ios-clean         编译后卸载重装到 iPhone/iPad，会清除 App 本地数据（别名 iphone-clean）
  sim-install       选择 iOS 模拟器，再选安装方式
  sim               编译、覆盖安装并启动到 iOS 模拟器（别名 sim-overwrite）
  sim-clean         编译后完全重装到 iOS 模拟器，会清除 App 本地数据
  tv-install        选择 tvOS 模拟器或 Apple TV 真机，再选安装方式
  tv                编译、覆盖安装并启动 tvOS App（别名 tv-overwrite）
  tv-clean          编译后完全重装 tvOS App，会清除 App 本地数据
  mac               编译并启动 macOS App

检查设备
  devices           检查可用于开发的 iPhone/iPad
  sim-devices       列出 iOS 模拟器及能否运行 App
  tv-devices        扫描 tvOS 模拟器和已配对的 Apple TV 真机

诊断与测试（iPhone/iPad，需 Debug 构建；日志拉到 logs/）
  diag              诊断日志模式菜单：开启 / 关闭 / 拉取日志
  diag-on [小时]    开启诊断日志模式并重启 App，默认 24 小时（1–72）：
                    日志单文件 25MB、保留 4 代，每 10 秒记录 CPU、线程、内存、磁盘读写、
                    唤醒、主线程卡顿和发热，用来事后查看界面上看不出来的后台问题
  diag-off          关闭诊断日志模式并重启 App
  sync-test         iCloud 同步测试场景：模拟升级/恢复后首次同步、全新安装、正常冷启动，
                    跑完自动拉取日志并打印同步摘要
  pull-logs         只拉取调试日志（含轮转的历史代）和 MetricKit 诊断报告，并打印摘要

可选环境变量：
  DEVICE_ID               目标设备名称、CoreDevice ID 或 UDID；未设置时自动发现
  TV_DEVICE_ID            tvOS 目标设备名称、CoreDevice ID 或 UDID；优先于 DEVICE_ID
  SIM_DEVICE_ID           iOS 模拟器名称或 UDID；未设置时交互选择
  IOS_CONFIGURATION       iOS 构建配置，默认 Debug
  MAC_CONFIGURATION       macOS 构建配置，默认 Debug
  TV_CONFIGURATION        tvOS 构建配置，默认 Debug
  IOS_DERIVED_DATA        iOS DerivedData 路径
  MAC_DERIVED_DATA        macOS DerivedData 路径
  TV_DERIVED_DATA         tvOS DerivedData 路径
  DEVICE_TIMEOUT          devicectl 超时秒数，默认 120
  DEVICE_DISCOVERY_TIMEOUT 设备发现单次超时秒数，默认 15
  SYNC_TEST_WAIT          同步测试场景启动后等待多少秒再拉日志，默认 180
  LOG_OUTPUT_DIR          拉取日志的存放目录，默认仓库下的 logs/
  APP_GROUP_ID            诊断报告所在的 App Group，默认 group.com.welape.yuanyin
EOF
}

# 破坏性操作前的确认：只有输入 DELETE 才返回 0，其余一律视为取消。
confirm_delete() {
    local warning="$1"

    echo
    echo "$warning"
    printf "输入 DELETE 继续："
    local confirmation=""
    if ! IFS= read -r confirmation; then
        echo
    fi
    if [[ "$confirmation" == "DELETE" ]]; then
        return 0
    fi
    echo "未确认删除，操作已取消；现有 App 和数据未变更。"
    return 1
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

    local selection
    local selected_index=-1
    local selection_match_count
    while [[ $selected_index -lt 0 ]]; do
        echo
        printf "请选择目标设备（输入序号、设备名或 UDID，q 退出）："
        if ! IFS= read -r selection; then
            echo
            echo "未选择设备，操作已取消。" >&2
            exit 1
        fi

        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            echo "操作已取消。"
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [[ "$selection" -ge 1 && "$selection" -le ${#ready_indices[@]} ]]; then
                selected_index="${ready_indices[$((selection - 1))]}"
                break
            fi
        else
            selection_match_count=0
            for ((index = 0; index < ${#ready_indices[@]}; index++)); do
                local candidate_index="${ready_indices[$index]}"
                if [[ "$selection" == "${IOS_DEVICE_NAMES[$candidate_index]}" || \
                      "$selection" == "${IOS_DEVICE_CORE_IDS[$candidate_index]}" || \
                      "$selection" == "${IOS_DEVICE_UDIDS[$candidate_index]}" ]]; then
                    selected_index="$candidate_index"
                    selection_match_count=$((selection_match_count + 1))
                fi
            done

            if [[ $selection_match_count -gt 1 ]]; then
                selected_index=-1
                echo "设备名匹配到多台设备，请改用序号或 UDID。" >&2
                continue
            fi
        fi

        if [[ $selected_index -lt 0 ]]; then
            echo "无法识别设备：${selection}。请输入列表序号、设备名或 UDID。" >&2
        fi
    done

    select_ios_device_at_index "$selected_index"
}

build_ios() {
    echo
    echo "正在为 ${DEVICE_NAME} 编译 App（${IOS_CONFIGURATION}）……"
    # 新设备第一次装机时要先登记到开发者账号，描述文件才会包含它；
    # 只给 -allowProvisioningUpdates 时 xcodebuild 不会替你登记设备。
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$IOS_SCHEME" \
        -configuration "$IOS_CONFIGURATION" \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$IOS_DERIVED_DATA" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
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

ensure_ios_device_selected() {
    if [[ -z "$DEVICE_CORE_ID" || -z "$DEVICE_UDID" ]]; then
        select_ios_device
    fi
}

ios_clean_install() {
    ensure_ios_device_selected

    confirm_delete "警告：下一步会卸载 ${BUNDLE_ID}，并删除它在 ${DEVICE_NAME} 上的全部本地数据。" || return 0

    ios_clean_install_confirmed
}

# 已经确认过删除之后的完全重装：编译、卸载、安装、启动。
ios_clean_install_confirmed() {
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
    ensure_ios_device_selected
    build_ios

    # 不执行 uninstall，系统会替换 App 包并保留现有数据容器。
    install_ios
    launch_ios
}

interactive_ios_install() {
    select_ios_device

    while true; do
        echo
        echo "请选择安装方式："
        echo "1) 覆盖安装（保留 App 本地数据）"
        echo "2) 完全重装（清除 App 本地数据）"
        echo "q) 取消"
        echo
        printf "请选择："

        local install_selection
        if ! IFS= read -r install_selection; then
            echo
            echo "未选择安装方式，操作已取消。"
            return
        fi

        case "$install_selection" in
            1)
                ios_overwrite_install
                return
                ;;
            2)
                ios_clean_install
                return
                ;;
            q|Q)
                echo "操作已取消。"
                return
                ;;
            *)
                echo "无效选项：${install_selection}" >&2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# iCloud 同步测试场景
#
# App 只在 Debug 构建里读取 PRIMUSE_SYNC_TEST_SCENARIO（见 CloudKitSyncService 的
# SyncTestScenario）。devicectl 会把 App 的 `-xxx` 启动参数当成自己的选项吞掉，
# 所以场景走环境变量：同时用 --environment-variables 和 DEVICECTL_CHILD_ 前缀两条路，
# 以拉回的日志里有没有 🧪 行为准。
# ---------------------------------------------------------------------------

# 启动 iPhone/iPad 上的 App，并把 KEY=VALUE 形式的环境变量传给它（可以不传）。
# 同时走 --environment-variables 和 DEVICECTL_CHILD_ 前缀两条路，第一条失败再只用第二条；
# 参数有没有真的传进 App，以拉回的日志为准（同步测试有 🧪 行，诊断模式有 🩺 行）。
launch_ios_with_env() {
    local description="$1"
    shift

    echo
    echo "正在启动 ${DEVICE_NAME} 上的 App（${description}）……"
    if [[ $# -eq 0 ]]; then
        if xcrun devicectl device process launch \
            --device "$DEVICE_CORE_ID" \
            --timeout "$DEVICE_TIMEOUT" \
            --terminate-existing \
            "$BUNDLE_ID"; then
            return 0
        fi
        echo "App 启动失败。请解锁 ${DEVICE_NAME} 后重试。" >&2
        return 1
    fi

    local json="{" pair key value
    local child_env=()
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        if [[ "$json" != "{" ]]; then
            json="${json},"
        fi
        json="${json}\"${key}\":\"${value}\""
        child_env+=("DEVICECTL_CHILD_${key}=${value}")
    done
    json="${json}}"

    if env "${child_env[@]}" xcrun devicectl device process launch \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --terminate-existing \
        --environment-variables "$json" \
        "$BUNDLE_ID"; then
        return 0
    fi

    echo "带 --environment-variables 启动失败，改为只用 DEVICECTL_CHILD_ 前缀再试一次……" >&2
    if env "${child_env[@]}" xcrun devicectl device process launch \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --terminate-existing \
        "$BUNDLE_ID"; then
        return 0
    fi

    echo "App 启动失败。请解锁 ${DEVICE_NAME} 后重试。" >&2
    return 1
}

launch_ios_with_scenario() {
    local scenario="$1"

    if [[ -z "$scenario" ]]; then
        launch_ios_with_env "正常启动"
    else
        launch_ios_with_env "测试场景 ${scenario}" "PRIMUSE_SYNC_TEST_SCENARIO=${scenario}"
    fi
}

wait_for_sync_test() {
    local remaining="$1"

    echo
    echo "请保持 ${DEVICE_NAME} 解锁、Primuse 在前台，等 iCloud 同步跑完。"
    if [[ ! -t 0 ]]; then
        echo "${remaining} 秒后自动拉取日志……"
        sleep "$remaining"
        return
    fi

    echo "${remaining} 秒后自动拉取日志；确认同步已完成可按回车提前拉取。"
    local ignored
    while [[ "$remaining" -gt 0 ]]; do
        printf "\r还剩 %3d 秒…… " "$remaining"
        if IFS= read -r -t 5 ignored; then
            break
        fi
        remaining=$((remaining - 5))
    done
    printf "\n"
}

count_log_matches() {
    grep -c -- "$1" "$2" 2>/dev/null || true
}

sum_log_field() {
    # $1: sed -E 表达式，捕获一个整数；输出 "次数 总和"
    sed -nE "$1" "$2" 2>/dev/null | awk '{ sum += $1; count += 1 } END { printf "%d %d", count, sum }'
}

summarize_sync_log() {
    local log="$1"
    local session="$2"
    local label="${3:-}"

    local start_line
    start_line="$(grep -n 'SESSION START' "$log" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)"
    if [[ -n "$start_line" ]]; then
        tail -n +"$start_line" "$log" > "$session"
    else
        cp "$log" "$session"
    fi

    local scenario_confirmed refetch_count reseed_line
    scenario_confirmed="$(count_log_matches '🧪 Sync test scenario upgrade-reset' "$session")"
    refetch_count="$(count_log_matches 'scheduling full refetch' "$session")"
    reseed_line="$(grep -- 'initial upload re-seeding' "$session" 2>/dev/null | tail -n 1 | sed -E 's/^.*re-seeding //' || true)"

    local fetched sent snapshot startup_cache system_fields
    fetched="$(sum_log_field 's/.*CloudKitSync: fetched ([0-9]+).*/\1/p' "$session")"
    sent="$(sum_log_field 's/.*CloudKitSync: sent saved=([0-9]+).*/\1/p' "$session")"
    snapshot="$(sum_log_field 's/.*Library snapshot written bytes=([0-9]+).*/\1/p' "$session")"
    startup_cache="$(sum_log_field 's/.*Library startup cache written bytes=([0-9]+).*/\1/p' "$session")"
    system_fields="$(sum_log_field 's/.*system fields cache written entries=[0-9]+ bytes=([0-9]+).*/\1/p' "$session")"

    local fetched_batches fetched_records sent_batches sent_records
    local snapshot_writes snapshot_bytes cache_writes cache_bytes fields_writes fields_bytes
    read -r fetched_batches fetched_records <<< "$fetched"
    read -r sent_batches sent_records <<< "$sent"
    read -r snapshot_writes snapshot_bytes <<< "$snapshot"
    read -r cache_writes cache_bytes <<< "$startup_cache"
    read -r fields_writes fields_bytes <<< "$system_fields"

    echo
    echo "—— 本次启动的同步摘要（${session#$ROOT_DIR/}）——"
    if [[ "$label" == "upgrade-reset" ]]; then
        echo "测试场景已生效：$([[ "${scenario_confirmed:-0}" -gt 0 ]] && echo 是 || echo 否（环境变量没传进 App）)"
    fi
    echo "全量重拉触发：${refetch_count:-0} 次"
    echo "首次上传重排：${reseed_line:-无}"
    echo "CloudKit 拉取：${fetched_batches} 批，共 ${fetched_records} 条"
    echo "CloudKit 推送：${sent_batches} 批，共 ${sent_records} 条"
    awk -v n="$snapshot_writes" -v b="$snapshot_bytes" 'BEGIN { printf "整库快照写入：%d 次，共 %.1f MB\n", n, b / 1048576 }'
    awk -v n="$cache_writes" -v b="$cache_bytes" 'BEGIN { printf "启动缓存写入：%d 次，共 %.1f MB\n", n, b / 1048576 }'
    awk -v n="$fields_writes" -v b="$fields_bytes" 'BEGIN { printf "同步字段缓存写入：%d 次，共 %.1f MB\n", n, b / 1048576 }'

    local triggers
    triggers="$(sed -nE 's/.*snapshot write armed in [0-9.]+s by ([^(]+).*/\1/p' "$session" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -n 5 | awk '{ printf "  %s 次  %s\n", $1, $2 }' || true)"
    if [[ -n "$triggers" ]]; then
        echo "整库快照由谁触发（前 5）："
        printf '%s\n' "$triggers"
    fi
}

pull_ios_logs() {
    local label="$1"
    local stamp safe_device dest errors
    stamp="$(date +%Y%m%d-%H%M%S)"
    safe_device="$(printf '%s' "$DEVICE_NAME" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
    dest="$LOG_OUTPUT_DIR/${stamp}-${label}-${safe_device}"
    errors="$dest/devicectl-errors.txt"
    mkdir -p "$dest"

    echo
    echo "正在从 ${DEVICE_NAME} 拉取调试日志到 ${dest#$ROOT_DIR/} ……"
    local copied_logs=0
    if copy_ios_app_file "Library/Caches/primuse_debug.log" "$dest/primuse_debug.log" "$errors"; then
        copied_logs=1
    else
        echo "没拉到 primuse_debug.log（详情见 ${errors#$ROOT_DIR/}）。可在 App 的设置里手动导出日志。" >&2
    fi
    # 轮转出来的历史代：常规模式只有 .1，诊断模式最多到 .4。缺了哪一代就不再往后找。
    local generation=1
    while [[ "$generation" -le "$LOG_GENERATIONS" ]]; do
        if ! copy_ios_app_file "Library/Caches/primuse_debug.log.${generation}" \
            "$dest/primuse_debug.log.${generation}" /dev/null; then
            break
        fi
        copied_logs=$((copied_logs + 1))
        generation=$((generation + 1))
    done

    echo "正在拉取 MetricKit 诊断报告……"
    local listing="$dest/.diagnostic-listing.json" report copied_reports=0
    if xcrun devicectl device info files \
            --device "$DEVICE_CORE_ID" \
            --timeout "$DEVICE_TIMEOUT" \
            --domain-type appGroupDataContainer \
            --domain-identifier "$APP_GROUP_ID" \
            --subdirectory DiagnosticReports \
            --quiet \
            --json-output "$listing" >>"$errors" 2>&1 \
        || xcrun devicectl device info files \
            --device "$DEVICE_CORE_ID" \
            --timeout "$DEVICE_TIMEOUT" \
            --domain-type appGroupDataContainer \
            --domain-identifier "$APP_GROUP_ID" \
            --quiet \
            --json-output "$listing" >>"$errors" 2>&1; then
        # 不依赖 JSON 的键名，只认 CrashDiagnosticsService 的文件名格式。
        for report in $(grep -oE 'crash-[0-9]+-[0-9A-Za-z]+\.json' "$listing" 2>/dev/null | sort -u || true); do
            mkdir -p "$dest/DiagnosticReports"
            if xcrun devicectl device copy from \
                --device "$DEVICE_CORE_ID" \
                --timeout "$DEVICE_TIMEOUT" \
                --domain-type appGroupDataContainer \
                --domain-identifier "$APP_GROUP_ID" \
                --source "DiagnosticReports/$report" \
                --destination "$dest/DiagnosticReports/$report" >>"$errors" 2>&1; then
                copied_reports=$((copied_reports + 1))
            fi
        done
    fi
    rm -f "$listing"
    if [[ ! -s "$errors" ]]; then
        rm -f "$errors"
    fi

    echo "已拉取：调试日志 ${copied_logs} 个，诊断报告 ${copied_reports} 份。"
    echo "（MetricKit 报告由系统延后投递，常见在下次启动或 24 小时内出现，没有不代表没问题。）"
    if [[ -f "$dest/primuse_debug.log" ]]; then
        local combined="$dest/primuse_debug.log"
        if [[ "$copied_logs" -gt 1 ]]; then
            # 按时间顺序拼起来：最老的一代在前，当前文件在最后。
            combined="$dest/primuse_debug.all.log"
            : > "$combined"
            generation=$((copied_logs - 1))
            while [[ "$generation" -ge 1 ]]; do
                cat "$dest/primuse_debug.log.${generation}" >> "$combined"
                generation=$((generation - 1))
            done
            cat "$dest/primuse_debug.log" >> "$combined"
        fi
        summarize_sync_log "$combined" "$dest/last-session.log" "$label"
        summarize_diagnostics "$combined"
    fi
    echo
    echo "日志目录：${dest#$ROOT_DIR/}"
}

# 从 App 数据容器拷一个文件回来；失败信息写进 $3（可以是 /dev/null）。
copy_ios_app_file() {
    local source="$1"
    local destination="$2"
    local errors="$3"

    xcrun devicectl device copy from \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "$source" \
        --destination "$destination" >>"$errors" 2>&1
}

# 诊断日志模式留下的 🩺 采样汇总（整份日志，不只最后一段会话：诊断模式往往跨好几次启动）。
summarize_diagnostics() {
    local log="$1"

    local samples
    samples="$(count_log_matches '🩺 cpu=' "$log")"
    if [[ "${samples:-0}" -eq 0 ]]; then
        return
    fi

    echo
    echo "—— 运行状态（诊断日志模式，🩺 采样 ${samples} 次，约每 10 秒一次）——"
    awk '
        /🩺 cpu=/ {
            for (i = 1; i <= NF; i++) {
                split($i, kv, "=")
                value = kv[2]
                if (kv[1] == "cpu") { sub(/%/, "", value); cpu_sum += value; cpu_n++; if (value + 0 > cpu_max) cpu_max = value + 0 }
                else if (kv[1] == "threads") { if (value + 0 > threads_max) threads_max = value + 0 }
                else if (kv[1] == "footprint") { sub(/MB/, "", value); if (value + 0 > mem_max) mem_max = value + 0 }
                else if (kv[1] == "diskW") { sub(/^\+/, "", value); sub(/MB/, "", value); disk_sum += value }
                else if (kv[1] == "wakeups") { sub(/\/s/, "", value); if (value + 0 > wake_max) wake_max = value + 0 }
                else if (kv[1] == "mainMax") { sub(/ms/, "", value); if (value + 0 > main_max) main_max = value + 0 }
                else if (kv[1] == "thermal") { thermal[value]++ }
            }
        }
        /🩺 main thread blocked for/ {
            stalls++
            value = $NF; sub(/s$/, "", value)
            if (value + 0 > stall_max) stall_max = value + 0
        }
        END {
            if (cpu_n > 0) printf "CPU：平均 %.0f%%，峰值 %.0f%%\n", cpu_sum / cpu_n, cpu_max
            printf "线程数峰值：%d；内存峰值：%.1f MB\n", threads_max, mem_max
            printf "进程磁盘写入（采样累加）：%.1f MB；唤醒峰值：%.0f 次/秒（含诊断探测约 2 次/秒）\n", disk_sum, wake_max
            printf "主线程：最长延迟 %.0f ms；卡住 1 秒以上 %d 次", main_max, stalls
            if (stalls > 0) printf "（最长 %.2f 秒）", stall_max
            printf "\n"
            line = ""
            for (state in thermal) line = line state "×" thermal[state] " "
            if (line != "") printf "发热等级：%s\n", line
        }
    ' "$log"

    local busy
    busy="$(grep -o 'top=\[[^]]*\]' "$log" 2>/dev/null \
        | sed -e 's/^top=\[//' -e 's/\]$//' \
        | tr ',' '\n' \
        | sed -E -e 's/^ +//' -e 's/ [0-9]+%$//' \
        | sort | uniq -c | sort -rn | head -n 5 \
        | awk '{ count = $1; $1 = ""; sub(/^ /, ""); printf "  %s 次  %s\n", count, $0 }' || true)"
    if [[ -n "$busy" ]]; then
        echo "CPU 偏高时最常出现的繁忙线程："
        printf '%s\n' "$busy"
    fi
}

sync_test_offer_build() {
    echo
    printf "先编译并覆盖安装当前代码吗？（保留 App 数据）[Y/n]："
    local answer=""
    if ! IFS= read -r answer; then
        answer=""
    fi
    case "$answer" in
        n|N)
            echo "跳过编译，使用设备上已安装的版本（需是包含同步测试开关的 Debug 构建）。"
            ;;
        *)
            build_ios
            install_ios
            ;;
    esac
}

sync_test_upgrade_reset() {
    ensure_ios_device_selected

    echo
    echo "场景：模拟升级到新增了音乐源类型的版本、或从备份恢复后的首次启动。"
    echo "  · 保留本机全部数据，只丢弃这台设备的 iCloud 同步进度；"
    echo "  · App 会重新拉取云端全部记录，并按正常规则只把与云端不同的内容推上去；"
    echo "  · 只在 Debug 构建里生效，且每次启动只模拟一次。"
    echo "建议同时打开另一台设备上的 Primuse，之后用「换一台设备」拉取它的日志，看有没有被来回推送。"
    sync_test_offer_build
    launch_ios_with_scenario "upgrade-reset"
    wait_for_sync_test "$SYNC_TEST_WAIT"
    pull_ios_logs "upgrade-reset"
}

sync_test_fresh_install() {
    ensure_ios_device_selected

    echo
    echo "场景：模拟全新安装的新设备（真实的卸载重装）。"
    confirm_delete "警告：会卸载 ${BUNDLE_ID}，并删除它在 ${DEVICE_NAME} 上的全部本地数据（本机曲库索引、下载和缓存、未同步的设置）。iCloud 上的数据不受影响。" || return 0

    ios_clean_install_confirmed
    wait_for_sync_test "$SYNC_TEST_WAIT"
    pull_ios_logs "fresh-install"
}

sync_test_baseline() {
    ensure_ios_device_selected

    echo
    echo "场景：正常冷启动（对照组），不做任何模拟。"
    sync_test_offer_build
    launch_ios_with_scenario ""
    wait_for_sync_test "$SYNC_TEST_WAIT"
    pull_ios_logs "baseline"
}

pull_logs_action() {
    select_ios_device
    pull_ios_logs "manual"
}

interactive_sync_test() {
    select_ios_device

    while true; do
        echo
        echo "iCloud 同步测试场景 —— 当前设备：${DEVICE_NAME}"
        echo "每个场景跑完都会把调试日志和诊断报告拉到 logs/，并打印本次启动的同步摘要。"
        echo "1) 模拟升级或从备份恢复后的首次同步（保留本机数据）"
        echo "2) 模拟全新安装的新设备（卸载重装，清除本机数据）"
        echo "3) 正常冷启动（对照组）"
        echo "4) 只拉取这台设备的调试日志和诊断报告"
        echo "d) 换一台设备"
        echo "q) 退出"
        echo
        printf "请选择："

        local selection
        if ! IFS= read -r selection; then
            echo
            return
        fi

        case "$selection" in
            1) sync_test_upgrade_reset ;;
            2) sync_test_fresh_install ;;
            3) sync_test_baseline ;;
            4) pull_ios_logs "manual" ;;
            d|D) select_ios_device ;;
            q|Q) return ;;
            *) echo "无效选项：${selection}" >&2 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 诊断日志模式
#
# App 只在 Debug 构建里读取 PRIMUSE_DIAGNOSTIC_LOGGING（见 FileLogger / DiagnosticLoggingPolicy）：
# 开启后有效期内日志单文件 25MB、保留 4 代，并每 10 秒记录一行 🩺 运行状态。
# 有效期存在 App 里，期间被系统或手动重启也继续记录，到期自动恢复常规。
# ---------------------------------------------------------------------------

diag_enable() {
    local hours="${1:-24}"
    ensure_ios_device_selected

    if ! [[ "$hours" =~ ^[0-9]+$ ]] || [[ "$hours" -lt 1 || "$hours" -gt 72 ]]; then
        echo "开启时长要在 1–72 小时之间：${hours}" >&2
        return 1
    fi

    echo
    echo "诊断日志模式：开启 ${hours} 小时。"
    echo "  · 日志单文件 25MB、保留 4 代（最多约 125MB），写入积压上限 20000 条；"
    echo "  · 每 10 秒记录 CPU、线程数、内存、磁盘读写、唤醒次数、主线程延迟和发热；"
    echo "    CPU 偏高时带上最忙的线程，主线程卡住 1 秒以上会单独记一行；"
    echo "  · 有效期内 App 被系统或手动重新启动也会继续记录，到期自动恢复常规；"
    echo "  · 只在 Debug 构建里生效；诊断探测本身每秒约多 2 次主线程唤醒。"
    sync_test_offer_build
    launch_ios_with_env "开启诊断日志 ${hours} 小时" "PRIMUSE_DIAGNOSTIC_LOGGING=${hours}"
    echo
    echo "已开启。照常使用 App、复现要排查的操作，结束后选「拉取日志」取回。"
}

diag_disable() {
    ensure_ios_device_selected

    launch_ios_with_env "关闭诊断日志" "PRIMUSE_DIAGNOSTIC_LOGGING=off"
    echo
    echo "已关闭。诊断期间多出来的旧日志文件会保留 72 小时，期间仍可拉取。"
}

interactive_diag() {
    select_ios_device

    while true; do
        echo
        echo "诊断日志模式 —— 当前设备：${DEVICE_NAME}（需 Debug 构建）"
        echo "1) 开启 24 小时（会重新启动 App）"
        echo "2) 开启指定小时数（1–72）"
        echo "3) 关闭（会重新启动 App）"
        echo "4) 拉取这台设备的调试日志和诊断报告"
        echo "d) 换一台设备"
        echo "q) 返回"
        echo
        printf "请选择："

        local selection hours
        if ! IFS= read -r selection; then
            echo
            return
        fi

        case "$selection" in
            1) diag_enable 24 ;;
            2)
                printf "开启多少小时（1–72）："
                hours=""
                IFS= read -r hours || true
                diag_enable "$hours" || true
                ;;
            3) diag_disable ;;
            4) pull_ios_logs "manual" ;;
            d|D) select_ios_device ;;
            q|Q) return ;;
            *) echo "无效选项：${selection}" >&2 ;;
        esac
    done
}

ios_deployment_target() {
    # 与 project.yml 里的 deploymentTarget.iOS 保持一致，低于它的模拟器装不上 App。
    sed -n 's/^    iOS: "\([0-9.]*\)"$/\1/p' "$ROOT_DIR/project.yml" 2>/dev/null | head -n 1 || true
}

version_at_least() {
    local actual_parts
    local required_parts
    IFS=. read -r -a actual_parts <<< "$1"
    IFS=. read -r -a required_parts <<< "$2"

    local index
    local actual
    local required
    for ((index = 0; index < ${#actual_parts[@]} || index < ${#required_parts[@]}; index++)); do
        actual="${actual_parts[$index]:-0}"
        required="${required_parts[$index]:-0}"
        if [[ ! "$actual" =~ ^[0-9]+$ || ! "$required" =~ ^[0-9]+$ ]]; then
            return 0
        fi
        if ((10#$actual > 10#$required)); then
            return 0
        fi
        if ((10#$actual < 10#$required)); then
            return 1
        fi
    done
    return 0
}

load_ios_simulators() {
    SIM_DEVICE_NAMES=()
    SIM_DEVICE_OSES=()
    SIM_DEVICE_UDIDS=()
    SIM_DEVICE_STATES=()
    SIM_DEVICE_READY=()
    SIM_DEVICE_REASONS=()

    echo "正在读取 iOS 模拟器列表……"

    local simctl_output
    if ! simctl_output="$(xcrun simctl list devices available 2>/dev/null)"; then
        echo "无法读取 iOS 模拟器列表。请检查 Xcode 命令行工具。" >&2
        exit 1
    fi

    local minimum_os
    minimum_os="$(ios_deployment_target)"

    local in_ios_section="false"
    local simulator_os=""
    local line
    local runtime_pattern='^-- iOS ([^[:space:]]+) --$'
    local simulator_pattern='^[[:space:]]*(.*[^[:space:]])[[:space:]]+[(]([0-9A-Fa-f-]{36})[)][[:space:]]+[(]([^()]*)[)][[:space:]]*$'
    while IFS= read -r line; do
        if [[ "$line" =~ $runtime_pattern ]]; then
            in_ios_section="true"
            simulator_os="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" == "-- "* ]]; then
            in_ios_section="false"
            continue
        fi
        if [[ "$in_ios_section" != "true" || ! "$line" =~ $simulator_pattern ]]; then
            continue
        fi

        local simulator_name="${BASH_REMATCH[1]}"
        local simulator_udid="${BASH_REMATCH[2]}"
        local simulator_state="${BASH_REMATCH[3]}"
        local simulator_ready="false"
        local simulator_reason=""
        if [[ -n "$minimum_os" ]] && ! version_at_least "$simulator_os" "$minimum_os"; then
            simulator_reason="低于 App 最低要求 iOS ${minimum_os}"
        elif [[ "$simulator_state" == "Booted" || "$simulator_state" == "Shutdown" ]]; then
            simulator_ready="true"
        else
            simulator_reason="模拟器状态：${simulator_state}"
        fi

        SIM_DEVICE_NAMES+=("$simulator_name")
        SIM_DEVICE_OSES+=("$simulator_os")
        SIM_DEVICE_UDIDS+=("$simulator_udid")
        SIM_DEVICE_STATES+=("$simulator_state")
        SIM_DEVICE_READY+=("$simulator_ready")
        SIM_DEVICE_REASONS+=("$simulator_reason")
    done <<< "$simctl_output"
}

print_ios_simulator() {
    local index="$1"
    local state="${SIM_DEVICE_STATES[$index]}"
    case "$state" in
        Booted) state="已启动" ;;
        Shutdown) state="已关机" ;;
    esac
    printf "%s — iOS %s 模拟器 — %s — %s" \
        "${SIM_DEVICE_NAMES[$index]}" \
        "${SIM_DEVICE_OSES[$index]}" \
        "$state" \
        "${SIM_DEVICE_UDIDS[$index]}"
}

select_ios_simulator_at_index() {
    local index="$1"
    DEVICE_NAME="${SIM_DEVICE_NAMES[$index]}"
    DEVICE_OS="${SIM_DEVICE_OSES[$index]}"
    DEVICE_UDID="${SIM_DEVICE_UDIDS[$index]}"
    DEVICE_STATE="${SIM_DEVICE_STATES[$index]}"
    DEVICE_KIND="simulator"
    DEVICE_CORE_ID=""

    echo "目标设备：${DEVICE_NAME} — iOS ${DEVICE_OS} 模拟器"
    echo "Xcode 构建 UDID：${DEVICE_UDID}"
}

show_ios_simulators() {
    load_ios_simulators

    if [[ ${#SIM_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现可用的 iOS 模拟器。请在 Xcode 中安装 iOS Runtime 后重试。" >&2
        return 1
    fi

    echo
    echo "已发现的 iOS 模拟器："
    local index
    for ((index = 0; index < ${#SIM_DEVICE_NAMES[@]}; index++)); do
        printf "%s" "- "
        print_ios_simulator "$index"
        if [[ "${SIM_DEVICE_READY[$index]}" == "true" ]]; then
            echo "（可用）"
        else
            printf "（不可用：%s）\n" "${SIM_DEVICE_REASONS[$index]}"
        fi
    done
}

select_ios_simulator() {
    load_ios_simulators

    if [[ ${#SIM_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现可用的 iOS 模拟器。请在 Xcode 中安装 iOS Runtime 后重试。" >&2
        exit 1
    fi

    local index
    local match_index=-1
    local match_count=0
    if [[ -n "${SIM_DEVICE_ID:-}" ]]; then
        for ((index = 0; index < ${#SIM_DEVICE_NAMES[@]}; index++)); do
            if [[ "$SIM_DEVICE_ID" == "${SIM_DEVICE_NAMES[$index]}" || \
                  "$SIM_DEVICE_ID" == "${SIM_DEVICE_UDIDS[$index]}" ]]; then
                match_index="$index"
                match_count=$((match_count + 1))
            fi
        done

        if [[ $match_count -eq 0 ]]; then
            echo "找不到 SIM_DEVICE_ID 指定的 iOS 模拟器：$SIM_DEVICE_ID" >&2
            exit 1
        fi
        if [[ $match_count -gt 1 ]]; then
            echo "模拟器名称匹配到多台（不同系统版本），请改用 UDID。" >&2
            exit 1
        fi
        if [[ "${SIM_DEVICE_READY[$match_index]}" != "true" ]]; then
            echo "目标模拟器当前不可用：${SIM_DEVICE_REASONS[$match_index]}。" >&2
            exit 1
        fi

        select_ios_simulator_at_index "$match_index"
        return
    fi

    local ready_indices=()
    for ((index = 0; index < ${#SIM_DEVICE_NAMES[@]}; index++)); do
        if [[ "${SIM_DEVICE_READY[$index]}" == "true" ]]; then
            ready_indices+=("$index")
        fi
    done

    if [[ ${#ready_indices[@]} -eq 0 ]]; then
        echo "没有可以运行 App 的 iOS 模拟器。" >&2
        for ((index = 0; index < ${#SIM_DEVICE_NAMES[@]}; index++)); do
            printf "%s" "- " >&2
            print_ios_simulator "$index" >&2
            printf "（%s）\n" "${SIM_DEVICE_REASONS[$index]}" >&2
        done
        exit 1
    fi

    if [[ ${#ready_indices[@]} -eq 1 ]]; then
        select_ios_simulator_at_index "${ready_indices[0]}"
        return
    fi

    echo
    echo "可用的 iOS 模拟器："
    local selection_number
    for ((index = 0; index < ${#ready_indices[@]}; index++)); do
        selection_number=$((index + 1))
        printf "%d) " "$selection_number"
        print_ios_simulator "${ready_indices[$index]}"
        echo
    done

    local selection
    local selected_index=-1
    local selection_match_count
    while [[ $selected_index -lt 0 ]]; do
        echo
        printf "请选择目标模拟器（输入序号、名称或 UDID，q 退出）："
        if ! IFS= read -r selection; then
            echo
            echo "未选择模拟器，操作已取消。" >&2
            exit 1
        fi

        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            echo "操作已取消。"
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [[ "$selection" -ge 1 && "$selection" -le ${#ready_indices[@]} ]]; then
                selected_index="${ready_indices[$((selection - 1))]}"
                break
            fi
        else
            selection_match_count=0
            for ((index = 0; index < ${#ready_indices[@]}; index++)); do
                local candidate_index="${ready_indices[$index]}"
                if [[ "$selection" == "${SIM_DEVICE_NAMES[$candidate_index]}" || \
                      "$selection" == "${SIM_DEVICE_UDIDS[$candidate_index]}" ]]; then
                    selected_index="$candidate_index"
                    selection_match_count=$((selection_match_count + 1))
                fi
            done

            if [[ $selection_match_count -gt 1 ]]; then
                selected_index=-1
                echo "模拟器名称匹配到多台（不同系统版本），请改用序号或 UDID。" >&2
                continue
            fi
        fi

        if [[ $selected_index -lt 0 ]]; then
            echo "无法识别模拟器：${selection}。请输入列表序号、名称或 UDID。" >&2
        fi
    done

    select_ios_simulator_at_index "$selected_index"
}

build_ios_simulator() {
    echo
    echo "正在为 ${DEVICE_NAME} 模拟器编译 App（${IOS_CONFIGURATION}）……"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$IOS_SCHEME" \
        -configuration "$IOS_CONFIGURATION" \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$IOS_DERIVED_DATA" \
        build

    if [[ ! -d "$IOS_SIMULATOR_APP_PATH" ]]; then
        echo "编译完成，但找不到 App：$IOS_SIMULATOR_APP_PATH" >&2
        exit 1
    fi
}

install_ios_simulator() {
    echo
    echo "正在安装到 ${DEVICE_NAME} 模拟器……"
    prepare_simulator
    xcrun simctl install "$DEVICE_UDID" "$IOS_SIMULATOR_APP_PATH"
}

launch_ios_simulator() {
    echo
    echo "正在启动 ${DEVICE_NAME} 模拟器上的 App……"
    prepare_simulator
    if xcrun simctl launch --terminate-running-process "$DEVICE_UDID" "$BUNDLE_ID"; then
        echo "${DEVICE_NAME} 模拟器上的 App 已安装并启动。"
        return
    fi

    echo "App 已安装，但自动启动失败。请在模拟器中手动启动，或重新运行此操作。" >&2
    return 1
}

ensure_ios_simulator_selected() {
    if [[ "$DEVICE_KIND" != "simulator" || -z "$DEVICE_UDID" ]]; then
        select_ios_simulator
    fi
}

sim_clean_install() {
    ensure_ios_simulator_selected

    confirm_delete "警告：下一步会卸载 ${BUNDLE_ID}，并删除它在 ${DEVICE_NAME} 模拟器上的全部本地数据。" || return 0

    build_ios_simulator

    echo
    echo "正在卸载旧 App 和本地数据……"
    prepare_simulator
    if xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
        xcrun simctl uninstall "$DEVICE_UDID" "$BUNDLE_ID"
    else
        echo "目标模拟器尚未安装此 App，将直接安装。"
    fi

    install_ios_simulator
    launch_ios_simulator
}

sim_overwrite_install() {
    ensure_ios_simulator_selected
    build_ios_simulator
    install_ios_simulator
    launch_ios_simulator
}

interactive_sim_install() {
    select_ios_simulator

    while true; do
        echo
        echo "请选择安装方式："
        echo "1) 覆盖安装（保留 App 本地数据）"
        echo "2) 完全重装（清除 App 本地数据）"
        echo "q) 取消"
        echo
        printf "请选择："

        local install_selection
        if ! IFS= read -r install_selection; then
            echo
            echo "未选择安装方式，操作已取消。"
            return
        fi

        case "$install_selection" in
            1)
                sim_overwrite_install
                return
                ;;
            2)
                sim_clean_install
                return
                ;;
            q|Q)
                echo "操作已取消。"
                return
                ;;
            *)
                echo "无效选项：${install_selection}" >&2
                ;;
        esac
    done
}

load_tv_devices() {
    TV_DEVICE_NAMES=()
    TV_DEVICE_MODELS=()
    TV_DEVICE_OSES=()
    TV_DEVICE_TRANSPORTS=()
    TV_DEVICE_CORE_IDS=()
    TV_DEVICE_UDIDS=()
    TV_DEVICE_KINDS=()
    TV_DEVICE_STATES=()
    TV_DEVICE_READY=()
    TV_DEVICE_REASONS=()

    echo "正在读取 tvOS 模拟器和 Apple TV 真机列表……"

    local candidate_ids=()
    local xctrace_output
    if xctrace_output="$(xcrun xctrace list devices 2>/dev/null)"; then
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
    else
        echo "暂时无法读取 Xcode 真机列表，将继续扫描 tvOS 模拟器。" >&2
    fi

    if [[ ${#candidate_ids[@]} -gt 0 ]]; then
        DEVICE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/primuse-tv-devices.XXXXXX")"
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
                echo "跳过无法读取详情的设备：${candidate_ids[$index]}" >&2
                continue
            fi

            platform="$(plist_value "result.hardwareProperties.platform")"
            reality="$(plist_value "result.hardwareProperties.reality")"
            if [[ "$platform" != "tvOS" || "$reality" != "physical" ]]; then
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

            TV_DEVICE_NAMES+=("$name")
            TV_DEVICE_MODELS+=("$model")
            TV_DEVICE_OSES+=("$os_version")
            TV_DEVICE_TRANSPORTS+=("$transport_type")
            TV_DEVICE_CORE_IDS+=("$core_id")
            TV_DEVICE_UDIDS+=("$udid")
            TV_DEVICE_KINDS+=("physical")
            TV_DEVICE_STATES+=("$tunnel_state")
            TV_DEVICE_READY+=("$ready")
            TV_DEVICE_REASONS+=("$reason")
        done

        cleanup_device_temp
    fi

    local simctl_output
    if ! simctl_output="$(xcrun simctl list devices available 2>/dev/null)"; then
        echo "暂时无法读取 tvOS 模拟器列表。" >&2
        return
    fi

    local in_tvos_section="false"
    local simulator_os=""
    local line
    local runtime_pattern='^-- tvOS ([^[:space:]]+) --$'
    local simulator_pattern='^[[:space:]]*(.*[^[:space:]])[[:space:]]+[(]([0-9A-Fa-f-]{36})[)][[:space:]]+[(]([^()]*)[)][[:space:]]*$'
    while IFS= read -r line; do
        if [[ "$line" =~ $runtime_pattern ]]; then
            in_tvos_section="true"
            simulator_os="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" == "-- "* ]]; then
            in_tvos_section="false"
            continue
        fi
        if [[ "$in_tvos_section" != "true" || ! "$line" =~ $simulator_pattern ]]; then
            continue
        fi

        local simulator_name="${BASH_REMATCH[1]}"
        local simulator_udid="${BASH_REMATCH[2]}"
        local simulator_state="${BASH_REMATCH[3]}"
        local simulator_ready="false"
        local simulator_reason=""
        if [[ "$simulator_state" == "Booted" || "$simulator_state" == "Shutdown" ]]; then
            simulator_ready="true"
        else
            simulator_reason="模拟器状态：${simulator_state}"
        fi

        TV_DEVICE_NAMES+=("$simulator_name")
        TV_DEVICE_MODELS+=("Apple TV 模拟器")
        TV_DEVICE_OSES+=("$simulator_os")
        TV_DEVICE_TRANSPORTS+=("simulator")
        TV_DEVICE_CORE_IDS+=("")
        TV_DEVICE_UDIDS+=("$simulator_udid")
        TV_DEVICE_KINDS+=("simulator")
        TV_DEVICE_STATES+=("$simulator_state")
        TV_DEVICE_READY+=("$simulator_ready")
        TV_DEVICE_REASONS+=("$simulator_reason")
    done <<< "$simctl_output"
}

print_tv_device() {
    local index="$1"
    if [[ "${TV_DEVICE_KINDS[$index]}" == "simulator" ]]; then
        local state="${TV_DEVICE_STATES[$index]}"
        case "$state" in
            Booted) state="已启动" ;;
            Shutdown) state="已关机" ;;
        esac
        printf "%s — tvOS %s 模拟器 — %s — %s" \
            "${TV_DEVICE_NAMES[$index]}" \
            "${TV_DEVICE_OSES[$index]}" \
            "$state" \
            "${TV_DEVICE_UDIDS[$index]}"
        return
    fi

    local transport="${TV_DEVICE_TRANSPORTS[$index]}"
    case "$transport" in
        wired) transport="USB" ;;
        localNetwork) transport="局域网" ;;
        "") transport="未知连接" ;;
    esac
    printf "%s — %s — tvOS %s 真机 — %s — %s" \
        "${TV_DEVICE_NAMES[$index]}" \
        "${TV_DEVICE_MODELS[$index]}" \
        "${TV_DEVICE_OSES[$index]}" \
        "$transport" \
        "${TV_DEVICE_UDIDS[$index]}"
}

select_tv_device_at_index() {
    local index="$1"
    DEVICE_NAME="${TV_DEVICE_NAMES[$index]}"
    DEVICE_MODEL="${TV_DEVICE_MODELS[$index]}"
    DEVICE_OS="${TV_DEVICE_OSES[$index]}"
    DEVICE_CORE_ID="${TV_DEVICE_CORE_IDS[$index]}"
    DEVICE_UDID="${TV_DEVICE_UDIDS[$index]}"
    DEVICE_KIND="${TV_DEVICE_KINDS[$index]}"
    DEVICE_STATE="${TV_DEVICE_STATES[$index]}"

    if [[ "$DEVICE_KIND" == "simulator" ]]; then
        echo "目标设备：${DEVICE_NAME} — tvOS ${DEVICE_OS} 模拟器"
    else
        echo "目标设备：${DEVICE_NAME} — ${DEVICE_MODEL} — tvOS ${DEVICE_OS} 真机"
        echo "CoreDevice ID：${DEVICE_CORE_ID}"
    fi
    echo "Xcode 构建 UDID：${DEVICE_UDID}"
}

show_tv_devices() {
    load_tv_devices

    if [[ ${#TV_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现可用的 tvOS 模拟器或已配对 Apple TV 真机。" >&2
        return 1
    fi

    echo
    echo "已发现的 Apple TV："
    local index
    for ((index = 0; index < ${#TV_DEVICE_NAMES[@]}; index++)); do
        printf "%s" "- "
        print_tv_device "$index"
        if [[ "${TV_DEVICE_READY[$index]}" == "true" ]]; then
            echo "（可用）"
        else
            printf "（不可用：%s）\n" "${TV_DEVICE_REASONS[$index]}"
        fi
    done
}

select_tv_device() {
    load_tv_devices

    if [[ ${#TV_DEVICE_NAMES[@]} -eq 0 ]]; then
        echo "没有发现 tvOS 模拟器或 Apple TV 真机。请安装 tvOS Runtime，或配对 Apple TV 后重试。" >&2
        exit 1
    fi

    local requested_id="${TV_DEVICE_ID:-${DEVICE_ID:-}}"
    local index
    local match_index=-1
    local match_count=0
    if [[ -n "$requested_id" ]]; then
        for ((index = 0; index < ${#TV_DEVICE_NAMES[@]}; index++)); do
            if [[ "$requested_id" == "${TV_DEVICE_NAMES[$index]}" || \
                  "$requested_id" == "${TV_DEVICE_CORE_IDS[$index]}" || \
                  "$requested_id" == "${TV_DEVICE_UDIDS[$index]}" ]]; then
                match_index="$index"
                match_count=$((match_count + 1))
            fi
        done

        if [[ $match_count -eq 0 ]]; then
            echo "找不到指定的 Apple TV：$requested_id" >&2
            exit 1
        fi
        if [[ $match_count -gt 1 ]]; then
            echo "设备名匹配到多个 Apple TV，请改用 CoreDevice ID 或 UDID。" >&2
            exit 1
        fi
        if [[ "${TV_DEVICE_READY[$match_index]}" != "true" ]]; then
            echo "目标设备当前不可用：${TV_DEVICE_REASONS[$match_index]}。" >&2
            exit 1
        fi

        select_tv_device_at_index "$match_index"
        return
    fi

    local ready_indices=()
    for ((index = 0; index < ${#TV_DEVICE_NAMES[@]}; index++)); do
        if [[ "${TV_DEVICE_READY[$index]}" == "true" ]]; then
            ready_indices+=("$index")
        fi
    done

    if [[ ${#ready_indices[@]} -eq 0 ]]; then
        echo "没有当前可用于开发的 tvOS 模拟器或 Apple TV 真机。" >&2
        for ((index = 0; index < ${#TV_DEVICE_NAMES[@]}; index++)); do
            printf "%s" "- " >&2
            print_tv_device "$index" >&2
            printf "（%s）\n" "${TV_DEVICE_REASONS[$index]}" >&2
        done
        exit 1
    fi

    if [[ ${#ready_indices[@]} -eq 1 ]]; then
        select_tv_device_at_index "${ready_indices[0]}"
        return
    fi

    echo
    echo "可用的 Apple TV："
    local selection_number
    for ((index = 0; index < ${#ready_indices[@]}; index++)); do
        selection_number=$((index + 1))
        printf "%d) " "$selection_number"
        print_tv_device "${ready_indices[$index]}"
        echo
    done

    local selection
    local selected_index=-1
    local selection_match_count
    while [[ $selected_index -lt 0 ]]; do
        echo
        printf "请选择目标设备（输入序号、设备名或 UDID，q 退出）："
        if ! IFS= read -r selection; then
            echo
            echo "未选择设备，操作已取消。" >&2
            exit 1
        fi

        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            echo "操作已取消。"
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [[ "$selection" -ge 1 && "$selection" -le ${#ready_indices[@]} ]]; then
                selected_index="${ready_indices[$((selection - 1))]}"
                break
            fi
        else
            selection_match_count=0
            for ((index = 0; index < ${#ready_indices[@]}; index++)); do
                local candidate_index="${ready_indices[$index]}"
                if [[ "$selection" == "${TV_DEVICE_NAMES[$candidate_index]}" || \
                      "$selection" == "${TV_DEVICE_CORE_IDS[$candidate_index]}" || \
                      "$selection" == "${TV_DEVICE_UDIDS[$candidate_index]}" ]]; then
                    selected_index="$candidate_index"
                    selection_match_count=$((selection_match_count + 1))
                fi
            done

            if [[ $selection_match_count -gt 1 ]]; then
                selected_index=-1
                echo "设备名匹配到多台 Apple TV，请改用序号或 UDID。" >&2
                continue
            fi
        fi

        if [[ $selected_index -lt 0 ]]; then
            echo "无法识别设备：${selection}。请输入列表序号、设备名或 UDID。" >&2
        fi
    done

    select_tv_device_at_index "$selected_index"
}

build_tv() {
    echo
    echo "正在为 ${DEVICE_NAME} 编译 tvOS App（${TV_CONFIGURATION}）……"
    local build_command=(
        xcodebuild
        -project "$PROJECT_PATH"
        -scheme "$TV_SCHEME"
        -configuration "$TV_CONFIGURATION"
        -destination "id=$DEVICE_UDID"
        -derivedDataPath "$TV_DERIVED_DATA"
    )
    if [[ "$DEVICE_KIND" == "physical" ]]; then
        build_command+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
        TV_APP_PATH="$TV_DEVICE_APP_PATH"
    else
        TV_APP_PATH="$TV_SIMULATOR_APP_PATH"
    fi
    build_command+=(build)
    "${build_command[@]}"

    if [[ ! -d "$TV_APP_PATH" ]]; then
        echo "编译完成，但找不到 tvOS App：$TV_APP_PATH" >&2
        exit 1
    fi
}

prepare_simulator() {
    if [[ "$DEVICE_KIND" != "simulator" ]]; then
        return
    fi

    if [[ "$DEVICE_STATE" != "Booted" ]]; then
        echo
        echo "正在启动 ${DEVICE_NAME} 模拟器……"
    fi
    xcrun simctl bootstatus "$DEVICE_UDID" -b
    DEVICE_STATE="Booted"
    show_simulator_window
}

show_simulator_window() {
    if [[ -n "$SIMULATOR_WINDOW_SHOWN" ]]; then
        return
    fi
    SIMULATOR_WINDOW_SHOWN="true"

    # Xcode 26 及更早用 Developer/Applications/Simulator.app；Xcode 27 起换成
    # Contents/Applications/DeviceHub.app，打开指定设备要走 devices:// 链接。
    # 窗口只是方便查看，打不开也不影响 simctl 安装和启动。
    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    local simulator_app="$developer_dir/Applications/Simulator.app"
    local device_hub_app="${developer_dir%/Developer}/Applications/DeviceHub.app"

    if [[ -n "$developer_dir" && -d "$simulator_app" ]]; then
        if /usr/bin/open -a "$simulator_app" --args -CurrentDeviceUDID "$DEVICE_UDID"; then
            return
        fi
    elif [[ -n "$developer_dir" && -d "$device_hub_app" ]]; then
        if /usr/bin/open "devices://device/open?id=$DEVICE_UDID" || /usr/bin/open -a "$device_hub_app"; then
            return
        fi
    elif /usr/bin/open -a Simulator --args -CurrentDeviceUDID "$DEVICE_UDID" 2>/dev/null; then
        return
    fi

    echo "没能打开 Simulator 或 Device Hub 窗口，继续在后台安装和启动 App。" >&2
}

install_tv() {
    echo
    echo "正在安装到 ${DEVICE_NAME}……"
    if [[ "$DEVICE_KIND" == "simulator" ]]; then
        prepare_simulator
        xcrun simctl install "$DEVICE_UDID" "$TV_APP_PATH"
    else
        xcrun devicectl device install app \
            --device "$DEVICE_CORE_ID" \
            --timeout "$DEVICE_TIMEOUT" \
            "$TV_APP_PATH"
    fi
}

launch_tv() {
    echo
    echo "正在启动 ${DEVICE_NAME} 上的 tvOS App……"
    if [[ "$DEVICE_KIND" == "simulator" ]]; then
        prepare_simulator
        if xcrun simctl launch --terminate-running-process "$DEVICE_UDID" "$TV_BUNDLE_ID"; then
            echo "${DEVICE_NAME} 模拟器上的 tvOS App 已安装并启动。"
            return
        fi
    elif xcrun devicectl device process launch \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --terminate-existing \
        "$TV_BUNDLE_ID"; then
        echo "${DEVICE_NAME} 上的 tvOS App 已安装并启动。"
        return
    fi

    echo "tvOS App 已安装，但自动启动失败。请检查目标设备后手动启动，或重新运行此操作。" >&2
    return 1
}

ensure_tv_device_selected() {
    if [[ -z "$DEVICE_KIND" || -z "$DEVICE_UDID" ]]; then
        select_tv_device
    fi
}

tv_clean_install() {
    ensure_tv_device_selected

    confirm_delete "警告：下一步会卸载 ${TV_BUNDLE_ID}，并删除它在 ${DEVICE_NAME} 上的全部本地数据。" || return 0

    build_tv

    echo
    echo "正在卸载旧 tvOS App 和本地数据……"
    if [[ "$DEVICE_KIND" == "simulator" ]]; then
        prepare_simulator
        if xcrun simctl get_app_container "$DEVICE_UDID" "$TV_BUNDLE_ID" app >/dev/null 2>&1; then
            xcrun simctl uninstall "$DEVICE_UDID" "$TV_BUNDLE_ID"
        else
            echo "目标模拟器尚未安装此 App，将直接安装。"
        fi
    elif ! xcrun devicectl device uninstall app \
        --device "$DEVICE_CORE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        "$TV_BUNDLE_ID"; then
        echo "卸载失败，已停止安装，避免把覆盖安装误当成完全重装。" >&2
        return 1
    fi

    install_tv
    launch_tv
}

tv_overwrite_install() {
    ensure_tv_device_selected
    build_tv
    install_tv
    launch_tv
}

interactive_tv_install() {
    select_tv_device

    while true; do
        echo
        echo "请选择安装方式："
        echo "1) 覆盖安装（保留 App 本地数据）"
        echo "2) 完全重装（清除 App 本地数据）"
        echo "q) 取消"
        echo
        printf "请选择："

        local install_selection
        if ! IFS= read -r install_selection; then
            echo
            echo "未选择安装方式，操作已取消。"
            return
        fi

        case "$install_selection" in
            1)
                tv_overwrite_install
                return
                ;;
            2)
                tv_clean_install
                return
                ;;
            q|Q)
                echo "操作已取消。"
                return
                ;;
            *)
                echo "无效选项：${install_selection}" >&2
                ;;
        esac
    done
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
    echo "安装与运行"
    echo "  1) iPhone/iPad：选择设备，覆盖安装或完全重装"
    echo "  2) iOS 模拟器：选择模拟器并安装"
    echo "  3) Apple TV：选择模拟器或真机并安装"
    echo "  4) macOS：编译并启动"
    echo "检查设备"
    echo "  5) iPhone/iPad 连接状态"
    echo "  6) iOS 模拟器"
    echo "  7) tvOS 模拟器和 Apple TV 真机"
    echo "诊断与测试（iPhone/iPad，需 Debug 构建）"
    echo "  8) 诊断日志模式：开启后日志更大，并定时记录 CPU、线程、内存、写盘、卡顿"
    echo "  9) iCloud 同步测试场景（跑完自动拉取日志）"
    echo "  10) 拉取调试日志和诊断报告"
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
        1) SELECTED_ACTION="install" ;;
        2) SELECTED_ACTION="sim-install" ;;
        3) SELECTED_ACTION="tv-install" ;;
        4) SELECTED_ACTION="mac" ;;
        5) SELECTED_ACTION="devices" ;;
        6) SELECTED_ACTION="sim-devices" ;;
        7) SELECTED_ACTION="tv-devices" ;;
        8) SELECTED_ACTION="diag" ;;
        9) SELECTED_ACTION="sync-test" ;;
        10) SELECTED_ACTION="pull-logs" ;;
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

    # 只有 diag-on 接受第二个参数（开启多少小时）。
    if [[ $# -gt 2 || ( $# -eq 2 && "$action" != "diag-on" ) ]]; then
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
        install)
            require_command xcrun
            require_command plutil
            interactive_ios_install
            ;;
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
        sim|sim-overwrite)
            require_command xcrun
            sim_overwrite_install
            ;;
        sim-install)
            require_command xcrun
            interactive_sim_install
            ;;
        sim-clean)
            require_command xcrun
            sim_clean_install
            ;;
        sim-devices)
            require_command xcrun
            show_ios_simulators
            ;;
        tv|tv-overwrite)
            require_command xcrun
            require_command plutil
            tv_overwrite_install
            ;;
        tv-install)
            require_command xcrun
            require_command plutil
            interactive_tv_install
            ;;
        tv-clean)
            require_command xcrun
            require_command plutil
            tv_clean_install
            ;;
        tv-devices)
            require_command xcrun
            require_command plutil
            show_tv_devices
            ;;
        mac)
            build_and_launch_mac
            ;;
        sync-test)
            require_command xcrun
            require_command plutil
            interactive_sync_test
            ;;
        pull-logs)
            require_command xcrun
            require_command plutil
            pull_logs_action
            ;;
        diag)
            require_command xcrun
            require_command plutil
            interactive_diag
            ;;
        diag-on)
            require_command xcrun
            require_command plutil
            diag_enable "${2:-24}"
            ;;
        diag-off)
            require_command xcrun
            require_command plutil
            diag_disable
            ;;
        *)
            echo "未知操作：$action" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
