#!/usr/bin/env bash
# macOS 平台专属配置与依赖安装
# 由 backup.sh source，不独立运行

# ---------- 依赖安装 ----------
install_deps_macos() {
    local missing=()
    command -v borg >/dev/null 2>&1 || missing+=(borg)
    command -v rclone >/dev/null 2>&1 || missing+=(rclone)

    [[ ${#missing[@]} -eq 0 ]] && return 0

    if ! command -v brew >/dev/null 2>&1; then
        echo "[macOS] Homebrew 未找到，请先安装: https://brew.sh"
        return 1
    fi

    echo "[macOS] 安装: ${missing[*]}"
    brew install "${missing[@]}"
}

# ---------- 调度设置 (launchd) ----------
setup_scheduler_macos() {
    local script="$1"; local hour="${2:-02}"; local min="${3:-34}"
    local plist_dir="$HOME/Library/LaunchAgents"
    mkdir -p "$plist_dir"

    cat > "$plist_dir/com.partiverse.backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.partiverse.backup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$script</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BORG_PASSPHRASE</key>
        <string>$(grep BORG_PASSPHRASE "$HOME/.config/partiverse-backup/secrets.env" | cut -d= -f2- | tr -d "'")</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$hour</integer>
        <key>Minute</key><integer>$min</integer>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key>
    <string>$HOME/.local/share/partiverse-backup/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.local/share/partiverse-backup/launchd.err</string>
</dict>
</plist>
PLIST

    launchctl load "$plist_dir/com.partiverse.backup.plist" 2>/dev/null || \
        echo "[macOS] launchd 加载失败，手动执行: launchctl load $plist_dir/com.partiverse.backup.plist"
}

# ---------- macOS 系统元数据 ----------
collect_meta_macos() {
    local meta_dir="$HOME/.local/share/partiverse-backup/system-meta"
    mkdir -p "$meta_dir"
    {
        echo "# System Meta (macOS) — $(date -Iseconds)"
        sw_vers > "$meta_dir/os-version.txt"
        system_profiler SPHardwareDataType > "$meta_dir/hardware.txt" 2>/dev/null || true
        brew list --versions > "$meta_dir/brew-packages.txt" 2>/dev/null || true
        crontab -l > "$meta_dir/crontab.txt" 2>/dev/null || true
        echo "Done: $(date -Iseconds)"
    } > "$meta_dir/manifest.txt" 2>&1 || true
}

install_deps_macos
