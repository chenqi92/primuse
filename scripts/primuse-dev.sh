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

IOS_DERIVED_DATA="${IOS_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/iOS}"
MAC_DERIVED_DATA="${MAC_DERIVED_DATA:-$ROOT_DIR/build/DeveloperWorkflow/macOS}"
IOS_APP_PATH="${IOS_APP_PATH:-$IOS_DERIVED_DATA/Build/Products/$IOS_CONFIGURATION-iphoneos/Primuse.app}"
MAC_APP_PATH="${MAC_APP_PATH:-$MAC_DERIVED_DATA/Build/Products/$MAC_CONFIGURATION/Primuse.app}"

usage() {
    cat <<'EOF'
用法：
  scripts/primuse-dev.sh
  scripts/primuse-dev.sh iphone-clean
  scripts/primuse-dev.sh iphone-overwrite
  scripts/primuse-dev.sh mac

操作：
  iphone-clean      编译后卸载并重新安装到 iPhone，会清除 App 本地数据
  iphone-overwrite  编译后直接覆盖安装到 iPhone，保留 App 本地数据
  mac               编译并启动 macOS App

可选环境变量：
  DEVICE_ID               目标 iPhone 的 Identifier；未设置时会交互输入
  IOS_CONFIGURATION       iOS 构建配置，默认 Debug
  MAC_CONFIGURATION       macOS 构建配置，默认 Debug
  IOS_DERIVED_DATA        iOS DerivedData 路径
  MAC_DERIVED_DATA        macOS DerivedData 路径
  DEVICE_TIMEOUT          devicectl 超时秒数，默认 120
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

choose_device() {
    if [[ -n "${DEVICE_ID:-}" ]]; then
        echo "目标 iPhone：$DEVICE_ID"
        return
    fi

    echo "正在读取 Apple 设备列表……"
    xcrun devicectl list devices
    echo
    echo "请确认目标 iPhone 已连接、已解锁并信任此 Mac。"
    printf "请输入设备列表中的 Identifier："
    if ! IFS= read -r DEVICE_ID; then
        echo
        echo "未读取到设备 Identifier，操作已取消。" >&2
        exit 1
    fi

    if [[ -z "$DEVICE_ID" ]]; then
        echo "未输入设备 Identifier，操作已取消。" >&2
        exit 1
    fi
}

build_ios() {
    echo
    echo "正在编译 iPhone App（${IOS_CONFIGURATION}）……"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$IOS_SCHEME" \
        -configuration "$IOS_CONFIGURATION" \
        -destination "id=$DEVICE_ID" \
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
    echo "正在安装到 iPhone……"
    xcrun devicectl device install app \
        --device "$DEVICE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        "$IOS_APP_PATH"
}

launch_ios() {
    echo
    echo "正在启动 iPhone App……"
    if xcrun devicectl device process launch \
        --device "$DEVICE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        --terminate-existing \
        "$BUNDLE_ID"; then
        echo "iPhone App 已安装并启动。"
        return
    fi

    echo "App 已安装，但自动启动失败。请解锁 iPhone 后手动启动，或重新运行此操作。" >&2
    return 1
}

iphone_clean_install() {
    choose_device
    build_ios

    echo
    echo "警告：下一步会卸载 ${BUNDLE_ID}，并删除它在该 iPhone 上的全部本地数据。"
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

    echo
    echo "正在卸载旧 App 和本地数据……"
    if ! xcrun devicectl device uninstall app \
        --device "$DEVICE_ID" \
        --timeout "$DEVICE_TIMEOUT" \
        "$BUNDLE_ID"; then
        echo "卸载失败，已停止安装，避免把覆盖安装误当成完全重装。" >&2
        return 1
    fi

    install_ios
    launch_ios
}

iphone_overwrite_install() {
    choose_device
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
    echo "1) 完全重装到 iPhone（清除 App 本地数据）"
    echo "2) 覆盖安装到 iPhone（保留 App 本地数据）"
    echo "3) 编译并启动 macOS"
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
        1) SELECTED_ACTION="iphone-clean" ;;
        2) SELECTED_ACTION="iphone-overwrite" ;;
        3) SELECTED_ACTION="mac" ;;
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
        iphone-clean)
            require_command xcrun
            iphone_clean_install
            ;;
        iphone-overwrite)
            require_command xcrun
            iphone_overwrite_install
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
