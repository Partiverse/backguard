#!/usr/bin/env bash
# Linux 平台专属配置与依赖安装
# 由 backup.sh source，不独立运行

# ---------- 依赖安装 ----------
install_deps_linux() {
    local pkgs=(borgbackup rclone fuse)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    echo "[Linux] 安装缺失依赖: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm "${missing[@]}"
    else
        echo "FATAL: 不支持的包管理器，请手动安装: ${missing[*]}"
        return 1
    fi
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
