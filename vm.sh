#!/bin/bash
set -euo pipefail

# =============================
# Hester Multi-VM Manager
# =============================

display_header() {
    clear
    cat << "EOF"
========================================================================
  _    _  ______  _____ _______ ______ _____  
 | |  | ||  ____|/ ____|__   __|  ____|  __ \ 
 | |__| || |__  | (___    | |  | |__  | |__) |
 |  __  ||  __|  \___ \   | |  |  __| |  _  / 
 | |  | || |____ ____) |  | |  | |____| | \ \ 
 |_|  |_||______|_____/   |_|  |______|_|  \_\

                    POWERED BY HESTER
========================================================================
EOF
    echo
}

print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"; return 1
            fi ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"; return 1
            fi ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"; return 1
            fi ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Name can only contain letters, numbers, hyphens, underscores"; return 1
            fi ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with letter/underscore, letters/numbers/hyphens only"; return 1
            fi ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then missing+=("$dep"); fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing: ${missing[*]}"
        print_status "INFO" "Run: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

cleanup() {
    [ -f "user-data" ] && rm -f "user-data"
    [ -f "meta-data" ] && rm -f "meta-data"
}

get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Config for '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Config saved to $config_file"
}

create_new_vm() {
    print_status "INFO" "Creating a new VM"
    echo ""
    print_status "INFO" "Select an OS to set up:"

    local os_keys=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_keys[$i]="$os"
        ((i++))
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_keys[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Enter password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then break
        else print_status "ERROR" "Password cannot be empty"; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then break
        else print_status "ERROR" "Please answer y or n"; fi
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config

    # ── AUTO-START IN BACKGROUND ──────────────────────────────────────
    print_status "INFO" "Auto-starting VM '$VM_NAME' in background..."
    start_vm_background "$VM_NAME"
}

setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$VM_DIR"

    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image already exists. Skipping download."
    else
        print_status "INFO" "Downloading from $IMG_URL ..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Download failed"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Resize failed — creating fresh image..."
        rm -f "$IMG_FILE"
        qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
    fi

    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi

    print_status "SUCCESS" "VM '$VM_NAME' image ready."
}

# ── Start VM in BACKGROUND (never blocks, never kills other VMs) ──────
start_vm_background() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM '$vm_name' is already running."
        return 0
    fi

    [[ ! -f "$IMG_FILE" ]] && { print_status "ERROR" "Image not found: $IMG_FILE"; return 1; }
    [[ ! -f "$SEED_FILE" ]] && { print_status "WARN" "Seed missing, recreating..."; setup_vm_image; }

    local port_fwd="hostfwd=tcp::${SSH_PORT}-:22"
    if [[ -n "$PORT_FORWARDS" ]]; then
        IFS=',' read -ra fwds <<< "$PORT_FORWARDS"
        for f in "${fwds[@]}"; do
            port_fwd="$port_fwd,hostfwd=tcp::$f"
        done
    fi

    local display_opt="-nographic -serial null -monitor none"
    [[ "$GUI_MODE" == true ]] && display_opt="-vga virtio -display gtk,gl=on"

    # Run fully detached — nohup + disown so closing terminal never kills it
    nohup qemu-system-x86_64 \
        -enable-kvm \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -cpu host \
        -drive "file=$IMG_FILE,format=qcow2,if=virtio" \
        -drive "file=$SEED_FILE,format=raw,if=virtio" \
        -boot order=c \
        -device virtio-net-pci,netdev=n0 \
        -netdev "user,id=n0,$port_fwd" \
        -device virtio-balloon-pci \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0 \
        $display_opt \
        > "$VM_DIR/$vm_name.log" 2>&1 &

    local pid=$!
    disown $pid
    echo "$pid" > "$VM_DIR/$vm_name.pid"

    print_status "SUCCESS" "VM '$vm_name' started in background (PID: $pid)"
    print_status "INFO"    "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    print_status "INFO"    "Password: $PASSWORD"
    print_status "INFO"    "Log: $VM_DIR/$vm_name.log"
}

# ── Interactive start (used from menu) ────────────────────────────────
start_vm() {
    local vm_name=$1
    start_vm_background "$vm_name"
}

stop_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "INFO" "Stopping VM: $vm_name"
        pkill -f "qemu-system-x86_64.*$IMG_FILE" 2>/dev/null || true
        sleep 2
        if is_vm_running "$vm_name"; then
            pkill -9 -f "qemu-system-x86_64.*$IMG_FILE" 2>/dev/null || true
        fi
        rm -f "$VM_DIR/$vm_name.pid"
        print_status "SUCCESS" "VM $vm_name stopped"
    else
        print_status "INFO" "VM $vm_name is not running"
    fi
}

restart_vm() {
    local vm_name=$1
    print_status "INFO" "Restarting VM: $vm_name"
    stop_vm "$vm_name"
    sleep 2
    start_vm_background "$vm_name"
}

delete_vm() {
    local vm_name=$1
    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        stop_vm "$vm_name" 2>/dev/null || true
        load_vm_config "$vm_name" && rm -f "$IMG_FILE" "$SEED_FILE"
        rm -f "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name.pid" "$VM_DIR/$vm_name.log"
        print_status "SUCCESS" "VM '$vm_name' deleted"
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

show_vm_info() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1
    local running="No"
    is_vm_running "$vm_name" && running="Yes"
    echo ""
    print_status "INFO" "VM Information: $vm_name"
    echo "=========================================="
    echo "OS:            $OS_TYPE"
    echo "Hostname:      $HOSTNAME"
    echo "Username:      $USERNAME"
    echo "Password:      $PASSWORD"
    echo "SSH Port:      $SSH_PORT"
    echo "Memory:        $MEMORY MB"
    echo "CPUs:          $CPUS"
    echo "Disk:          $DISK_SIZE"
    echo "GUI Mode:      $GUI_MODE"
    echo "Port Forwards: ${PORT_FORWARDS:-None}"
    echo "Running:       $running"
    echo "Created:       $CREATED"
    echo "=========================================="
    echo ""
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

is_vm_running() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then return 0; fi
    fi
    return 1
}

edit_vm_config() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1
    print_status "INFO" "Editing VM: $vm_name"

    while true; do
        echo "What would you like to edit?"
        echo "  1) Hostname   2) Username   3) Password"
        echo "  4) SSH Port   5) GUI Mode   6) Port Forwards"
        echo "  7) Memory     8) CPU Count  9) Disk Size"
        echo "  0) Back"
        read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice

        case $edit_choice in
            1) read -p "$(print_status "INPUT" "New hostname (current: $HOSTNAME): ")" v; HOSTNAME="${v:-$HOSTNAME}" ;;
            2) read -p "$(print_status "INPUT" "New username (current: $USERNAME): ")" v; USERNAME="${v:-$USERNAME}" ;;
            3) read -s -p "$(print_status "INPUT" "New password: ")" v; echo; PASSWORD="${v:-$PASSWORD}" ;;
            4) read -p "$(print_status "INPUT" "New SSH port (current: $SSH_PORT): ")" v; SSH_PORT="${v:-$SSH_PORT}" ;;
            5) read -p "$(print_status "INPUT" "GUI mode y/n (current: $GUI_MODE): ")" v
               [[ "$v" =~ ^[Yy]$ ]] && GUI_MODE=true || GUI_MODE=false ;;
            6) read -p "$(print_status "INPUT" "Port forwards (current: ${PORT_FORWARDS:-None}): ")" v; PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            7) read -p "$(print_status "INPUT" "Memory MB (current: $MEMORY): ")" v; MEMORY="${v:-$MEMORY}" ;;
            8) read -p "$(print_status "INPUT" "CPUs (current: $CPUS): ")" v; CPUS="${v:-$CPUS}" ;;
            9) read -p "$(print_status "INPUT" "Disk size (current: $DISK_SIZE): ")" v; DISK_SIZE="${v:-$DISK_SIZE}" ;;
            0) return 0 ;;
            *) print_status "ERROR" "Invalid"; continue ;;
        esac

        [[ "$edit_choice" =~ ^[123]$ ]] && { print_status "INFO" "Updating cloud-init..."; setup_vm_image; }
        save_vm_config

        read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
        [[ ! "$cont" =~ ^[Yy]$ ]] && break
    done
}

resize_vm_disk() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1
    print_status "INFO" "Current disk size: $DISK_SIZE"

    while true; do
        read -p "$(print_status "INPUT" "New disk size (e.g., 50G): ")" new_size
        if validate_input "size" "$new_size"; then
            print_status "INFO" "Resizing to $new_size..."
            if qemu-img resize "$IMG_FILE" "$new_size"; then
                DISK_SIZE="$new_size"
                save_vm_config
                print_status "SUCCESS" "Disk resized to $new_size"
            else
                print_status "ERROR" "Resize failed"
            fi
            break
        fi
    done
}

show_vm_performance() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        local pid
        pid=$(cat "$VM_DIR/$vm_name.pid")
        print_status "INFO" "Performance: $vm_name (PID $pid)"
        echo "=========================================="
        ps -p "$pid" -o pid,%cpu,%mem,rss,etime --no-headers 2>/dev/null
        echo ""
        free -h
        echo ""
        du -h "$IMG_FILE" 2>/dev/null
        echo "=========================================="
    else
        print_status "INFO" "VM $vm_name is not running"
        echo "  Memory: $MEMORY MB | CPUs: $CPUS | Disk: $DISK_SIZE"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# ── Keep-alive watchdog: restarts any VM that has died ────────────────
watchdog() {
    while true; do
        sleep 30
        for conf in "$VM_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local vm_name
            vm_name=$(basename "$conf" .conf)
            if ! is_vm_running "$vm_name"; then
                print_status "WARN" "Watchdog: '$vm_name' is down — restarting..."
                start_vm_background "$vm_name" 2>/dev/null || true
            fi
        done
    done
}

main_menu() {
    # Start watchdog in background so all VMs auto-restart if they die
    watchdog &
    WATCHDOG_PID=$!
    disown $WATCHDOG_PID

    while true; do
        display_header

        local vms=()
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local status="⛔ Stopped"
                is_vm_running "${vms[$i]}" && status="✅ Running"
                printf "  %2d) %s  [%s]\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo ""
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Restart a VM"
            echo "  5) Show VM info"
            echo "  6) Edit VM configuration"
            echo "  7) Delete a VM"
            echo "  8) Resize VM disk"
            echo "  9) Show VM performance"
        fi
        echo "  0) Exit"
        echo ""

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        pick_vm() {
            local action=$1
            read -p "$(print_status "INPUT" "Enter VM number to $action: ")" vm_num
            if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                echo "${vms[$((vm_num-1))]}"
            else
                print_status "ERROR" "Invalid selection"
                echo ""
            fi
        }

        case $choice in
            1) create_new_vm ;;
            2) [ $vm_count -gt 0 ] && { vm=$(pick_vm "start"); [ -n "$vm" ] && start_vm "$vm"; } ;;
            3) [ $vm_count -gt 0 ] && { vm=$(pick_vm "stop"); [ -n "$vm" ] && stop_vm "$vm"; } ;;
            4) [ $vm_count -gt 0 ] && { vm=$(pick_vm "restart"); [ -n "$vm" ] && restart_vm "$vm"; } ;;
            5) [ $vm_count -gt 0 ] && { vm=$(pick_vm "show info for"); [ -n "$vm" ] && show_vm_info "$vm"; } ;;
            6) [ $vm_count -gt 0 ] && { vm=$(pick_vm "edit"); [ -n "$vm" ] && edit_vm_config "$vm"; } ;;
            7) [ $vm_count -gt 0 ] && { vm=$(pick_vm "delete"); [ -n "$vm" ] && delete_vm "$vm"; } ;;
            8) [ $vm_count -gt 0 ] && { vm=$(pick_vm "resize"); [ -n "$vm" ] && resize_vm_disk "$vm"; } ;;
            9) [ $vm_count -gt 0 ] && { vm=$(pick_vm "check performance of"); [ -n "$vm" ] && show_vm_performance "$vm"; } ;;
            0) print_status "INFO" "Goodbye!"; kill $WATCHDOG_PID 2>/dev/null; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

trap cleanup EXIT
check_dependencies

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

main_menu
