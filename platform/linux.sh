#!/usr/bin/env bash
# Linux 平台专属配置与依赖安装
# 由 backup.sh source，不独立运行

# ---------- 依赖安装 ----------
install_deps_linux() {
    # 优先检查非标准路径（二进制直接放在 ~/bin 或项目内），其次 apt/dnf
    # 二进制在 PATH 中即可用，不需要 apt-get 重复装
    for bin in borg rclone; do
        if command -v "$bin" >/dev/null 2>&1; then
            continue
        fi
        for extra in "$HOME/bin" "$HOME/bin/$bin"* "$HOME/.local/bin"; do
            [[ -x "$extra" ]] && continue 2
        done
        # 确实缺失，尝试 apt 安装
        echo "[Linux] 安装缺失依赖: $bin"
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y "$bin" 2>/dev/null || true
        fi
    done
}

# ---------- 调度设置 ----------
setup_scheduler_linux() {
    local script="$1"; local hour="${2:-02}"; local min="${3:-34}"
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"

    cat > "$unit_dir/partiverse-backup.timer" <<TIMER
[Unit]
Description=Partiverse Backup (config/files/system, every 6h)
[Timer]
OnCalendar=*-*-* 00/6:${min}:00
Persistent=true
RandomizedDelaySec=10m
[Install]
WantedBy=timers.target
TIMER

    cat > "$unit_dir/partiverse-backup.service" <<SVC
[Unit]
Description=Partiverse Backup
After=network-online.target
[Service]
Type=oneshot
ExecStart=$script
EnvironmentFile=%h/.config/partiverse-backup/secrets.env
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.local/share %h/.config/partiverse-backup $BACKUP_BASE
SVC

    systemctl --user daemon-reload
    systemctl --user enable --now partiverse-backup.timer
}

# ---------- 元数据收集 ----------
collect_meta_linux() {
    local meta_dir="$HOME/.local/share/partiverse-backup/system-meta"
    mkdir -p "$meta_dir"
    {
        echo "# System Meta — $(date -Iseconds)"
        . /etc/os-release; echo "OS=$PRETTY_NAME"
        echo "HOSTNAME=$(hostname)"; echo "KERNEL=$(uname -r)"
        dpkg --get-selections 2>/dev/null | grep -v deinstall | awk '{print $1}' > "$meta_dir/packages.txt"
        flatpak list 2>/dev/null | awk -F'\t' '{print $2}' > "$meta_dir/flatpak.txt" || true
        lsblk -f -o NAME,FSTYPE,SIZE,UUID,MOUNTPOINT > "$meta_dir/block-devices.txt" 2>/dev/null || true
        findmnt -rn -o SOURCE,TARGET,FSTYPE > "$meta_dir/mounts.txt" 2>/dev/null || true
        cat /etc/fstab > "$meta_dir/fstab.txt" 2>/dev/null || true
        efibootmgr -v 2>/dev/null > "$meta_dir/efiboot.txt" || true
        crontab -l 2>/dev/null > "$meta_dir/crontab.txt" || true
        echo "Done: $(date -Iseconds)"
    } > "$meta_dir/manifest.txt" 2>&1 || true
}

# 首次调用自动安装
install_deps_linux
