#!/bin/bash

# BJORN Installation Script
# Supports first install (interactive), update, and reinstall workflows.
# Author: infinition
# Version: 2.0 - 260323

set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging configuration
LOG_DIR="/var/log/bjorn_install"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/bjorn_install_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=false

# Global variables
BJORN_USER="bjorn"
BJORN_PATH="/home/${BJORN_USER}/Bjorn"
CONFIG_FILE_REL="config/shared_config.json"
CURRENT_STEP=0
TOTAL_STEPS=8

# Mode and flags
MODE="interactive" # interactive|update|reinstall
FULL_SYSTEM=false
AUTO_YES=false
REPO_URL="https://github.com/ashin115/Bjorn.git"
BRANCH="main"
EPD_VERSION=""

# Runtime paths
BACKUP_DIR="/tmp/bjorn_install_${RANDOM}_$$"
CONFIG_BACKUP_FILE="${BACKUP_DIR}/shared_config.json.bak"

# Function to display progress
show_progress() {
    echo -e "${BLUE}Step $CURRENT_STEP of $TOTAL_STEPS: $1${NC}"
}

# Logging function
log() {
    local level=$1
    shift
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$message" >> "$LOG_FILE"
    if [ "$VERBOSE" = true ] || [ "$level" != "DEBUG" ]; then
        case $level in
            "ERROR") echo -e "${RED}$message${NC}" ;;
            "SUCCESS") echo -e "${GREEN}$message${NC}" ;;
            "WARNING") echo -e "${YELLOW}$message${NC}" ;;
            "INFO") echo -e "${BLUE}$message${NC}" ;;
            *) echo -e "$message" ;;
        esac
    fi
}

print_help() {
    cat << EOF
Usage:
  sudo ./install_bjorn.sh                         # Interactive first install (existing behavior)
  sudo ./install_bjorn.sh --update [options]      # Day-2 update
  sudo ./install_bjorn.sh --reinstall [options]   # Day-2 reinstall with rollback

Options:
  --update               Update existing installation (preserves config)
  --reinstall            Reinstall code directory (preserves config, rollback on clone failure)
  --full-system          Re-run system-level setup (deps, limits, interfaces, USB gadget)
    --repo <url>           Git repository URL (default: https://github.com/ashin115/Bjorn.git)
  --branch <name>        Git branch to deploy (default: main)
  --yes                  Non-interactive mode (assume yes)
  --epd <value>          E-paper value (epd2in13, epd2in13_V2, epd2in13_V3, epd2in13_V4, epd2in7)
  --help                 Show this help

Examples:
  sudo ./install_bjorn.sh
  sudo ./install_bjorn.sh --update --yes
  sudo ./install_bjorn.sh --reinstall --repo https://github.com/<you>/Bjorn.git --branch main --yes
  sudo ./install_bjorn.sh --update --full-system --yes --epd epd2in13_V4
EOF
}

# Error handling function
handle_error() {
    local error_code=$?
    local error_message=$1
    log "ERROR" "An error occurred during: $error_message (Error code: $error_code)"
    log "ERROR" "Check the log file for details: $LOG_FILE"

    if [ "$AUTO_YES" = true ] || [ "$MODE" != "interactive" ]; then
        clean_exit 1
    fi

    echo -e "\n${RED}Would you like to:"
    echo "1. Retry this step"
    echo "2. Skip this step (not recommended)"
    echo "3. Exit installation${NC}"
    read -r choice

    case $choice in
        1) return 1 ;;
        2) return 0 ;;
        3) clean_exit 1 ;;
        *) handle_error "$error_message" ;;
    esac
}

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        log "SUCCESS" "$1"
        return 0
    else
        handle_error "$1"
        return $?
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Please use 'sudo'."
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1"
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    while true; do
        read -r -p "$prompt (y/n): " response
        case "$response" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

ensure_line_in_file() {
    local file="$1"
    local line="$2"

    [ -f "$file" ] || touch "$file"
    if ! grep -Fqx "$line" "$file"; then
        echo "$line" >> "$file"
    fi
}

set_key_value_line() {
    local file="$1"
    local key="$2"
    local value="$3"

    [ -f "$file" ] || touch "$file"
    if grep -Eq "^#?${key}=" "$file"; then
        sed -i "s|^#\?${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

backup_shared_config() {
    local config_path="${BJORN_PATH}/${CONFIG_FILE_REL}"
    mkdir -p "$BACKUP_DIR"

    if [ -f "$config_path" ]; then
        cp "$config_path" "$CONFIG_BACKUP_FILE"
        check_success "Backed up shared config"
    else
        log "WARNING" "No existing shared config found to back up"
    fi
}

restore_shared_config() {
    local config_path="${BJORN_PATH}/${CONFIG_FILE_REL}"

    if [ -f "$CONFIG_BACKUP_FILE" ]; then
        mkdir -p "$(dirname "$config_path")"
        cp "$CONFIG_BACKUP_FILE" "$config_path"
        check_success "Restored shared config"
    fi

    if [ -n "$EPD_VERSION" ] && [ -f "$config_path" ]; then
        sed -i "s/\"epd_type\": \"[^\"]*\"/\"epd_type\": \"$EPD_VERSION\"/" "$config_path"
        check_success "Applied E-Paper display configuration: $EPD_VERSION"
    fi
}

ensure_bjorn_user() {
    if ! id -u "$BJORN_USER" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "$BJORN_USER"
        check_success "Created BJORN user"
    fi
}

stop_bjorn_runtime() {
    log "INFO" "Stopping BJORN runtime if active..."

    if systemctl list-unit-files | grep -q '^bjorn\.service'; then
        systemctl stop bjorn.service >/dev/null 2>&1 || true
    fi

    pkill -f "python3 /home/bjorn/Bjorn/Bjorn.py" >/dev/null 2>&1 || true
    check_success "Stopped BJORN runtime"
}

clone_repo_to_path() {
    local target_path="$1"
    git clone --branch "$BRANCH" "$REPO_URL" "$target_path"
}

refresh_repo_from_git() {
    if [ ! -d "${BJORN_PATH}/.git" ]; then
        return 1
    fi

    git -C "$BJORN_PATH" remote set-url origin "$REPO_URL"
    git -C "$BJORN_PATH" fetch --prune origin "$BRANCH"
    git -C "$BJORN_PATH" checkout -B "$BRANCH" "origin/$BRANCH"
}

reclone_with_rollback() {
    local rollback_path="${BJORN_PATH}.rollback.$(date +%s)"

    if [ -d "$BJORN_PATH" ]; then
        mv "$BJORN_PATH" "$rollback_path"
        check_success "Moved current Bjorn directory to rollback path"
    fi

    if clone_repo_to_path "$BJORN_PATH"; then
        rm -rf "$rollback_path"
        log "SUCCESS" "Repository cloned successfully"
        return 0
    fi

    log "ERROR" "Clone failed, attempting rollback"
    rm -rf "$BJORN_PATH"

    if [ -d "$rollback_path" ]; then
        mv "$rollback_path" "$BJORN_PATH"
        check_success "Rollback restored previous Bjorn directory"
    fi

    return 1
}

prepare_repo_install_mode() {
    cd "/home/$BJORN_USER" || return 1

    if [ -d "$BJORN_PATH" ]; then
        log "INFO" "Using existing BJORN directory"
        return 0
    fi

    clone_repo_to_path "$BJORN_PATH"
    check_success "Cloned BJORN repository"
}

prepare_repo_update_mode() {
    if [ ! -d "$BJORN_PATH" ]; then
        log "WARNING" "Bjorn directory not found, cloning from scratch"
        clone_repo_to_path "$BJORN_PATH"
        check_success "Cloned BJORN repository"
        return 0
    fi

    if refresh_repo_from_git; then
        check_success "Updated repository from git"
        return 0
    fi

    log "WARNING" "Git metadata missing or refresh failed, falling back to rollback-safe reclone"
    reclone_with_rollback
    check_success "Recloned repository with rollback safety"
}

prepare_repo_reinstall_mode() {
    reclone_with_rollback
    check_success "Reinstalled repository with rollback safety"
}

# Check system compatibility
check_system_compatibility() {
    log "INFO" "Checking system compatibility..."
    local should_ask_confirmation=false

    if ! grep -q "Raspberry Pi" /proc/cpuinfo; then
        log "WARNING" "This system might not be a Raspberry Pi"
        should_ask_confirmation=true
    fi

    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt 410 ]; then
        log "WARNING" "Low RAM detected. Required: 512MB (410 With OS Running), Found: ${total_ram}MB"
        should_ask_confirmation=true
    else
        log "SUCCESS" "RAM check passed: ${total_ram}MB available"
    fi

    available_space=$(df -m /home | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 2048 ]; then
        log "WARNING" "Low disk space. Recommended: 1GB, Found: ${available_space}MB"
        should_ask_confirmation=true
    else
        log "SUCCESS" "Disk space check passed: ${available_space}MB available"
    fi

    if [ -f "/etc/os-release" ]; then
        # shellcheck source=/dev/null
        source /etc/os-release

        if [ "$NAME" != "Raspbian GNU/Linux" ]; then
            log "WARNING" "Different OS detected. Recommended: Raspbian GNU/Linux, Found: ${NAME}"
            should_ask_confirmation=true
        fi

        expected_version="12"
        if [ "$VERSION_ID" != "$expected_version" ]; then
            log "WARNING" "Different OS version detected"
            should_ask_confirmation=true
        else
            log "SUCCESS" "OS version check passed: ${PRETTY_NAME}"
        fi
    else
        log "WARNING" "Could not determine OS version (/etc/os-release not found)"
        should_ask_confirmation=true
    fi

    architecture=$(dpkg --print-architecture)
    if [ "$architecture" != "armhf" ]; then
        log "WARNING" "Different architecture detected. Expected: armhf, Found: ${architecture}"
        should_ask_confirmation=true
    fi

    if ! (grep -q "Pi Zero" /proc/cpuinfo || grep -q "BCM2835" /proc/cpuinfo); then
        log "WARNING" "Could not confirm if this is a Raspberry Pi Zero"
        should_ask_confirmation=true
    else
        log "SUCCESS" "Raspberry Pi Zero detected"
    fi

    if [ "$should_ask_confirmation" = true ] && [ "$AUTO_YES" = false ]; then
        echo -e "\n${YELLOW}Some system compatibility warnings were detected.${NC}"
        if ! ask_yes_no "Do you want to continue anyway?"; then
            log "INFO" "Installation aborted by user after compatibility warnings"
            clean_exit 1
        fi
    fi

    log "INFO" "System compatibility check completed"
    return 0
}

# Install system dependencies
install_dependencies() {
    log "INFO" "Installing system dependencies..."

    apt-get update

    packages=(
        "python3-pip"
        "wget"
        "lsof"
        "git"
        "libopenjp2-7"
        "nmap"
        "libopenblas-dev"
        "bluez-tools"
        "bluez"
        "dhcpcd5"
        "bridge-utils"
        "python3-pil"
        "libjpeg-dev"
        "zlib1g-dev"
        "libpng-dev"
        "python3-dev"
        "libffi-dev"
        "libssl-dev"
        "libgpiod-dev"
        "libi2c-dev"
        "libatlas-base-dev"
        "build-essential"
    )

    for package in "${packages[@]}"; do
        log "INFO" "Installing $package..."
        apt-get install -y "$package"
        check_success "Installed $package"
    done

    nmap --script-updatedb
    check_success "Dependencies installation completed"
}

# Configure system limits (idempotent)
configure_system_limits() {
    log "INFO" "Configuring system limits..."

    ensure_line_in_file /etc/security/limits.conf "* soft nofile 65535"
    ensure_line_in_file /etc/security/limits.conf "* hard nofile 65535"
    ensure_line_in_file /etc/security/limits.conf "root soft nofile 65535"
    ensure_line_in_file /etc/security/limits.conf "root hard nofile 65535"

    set_key_value_line /etc/systemd/system.conf "DefaultLimitNOFILE" "65535"
    set_key_value_line /etc/systemd/user.conf "DefaultLimitNOFILE" "65535"

    cat > /etc/security/limits.d/90-nofile.conf << EOF
root soft nofile 65535
root hard nofile 65535
EOF

    set_key_value_line /etc/sysctl.conf "fs.file-max" "2097152"
    sysctl -p

    check_success "System limits configuration completed"
}

# Configure SPI and I2C
configure_interfaces() {
    log "INFO" "Configuring SPI and I2C interfaces..."

    raspi-config nonint do_spi 0
    raspi-config nonint do_i2c 0

    check_success "Interface configuration completed"
}

# Setup BJORN app files
setup_bjorn_app() {
    log "INFO" "Setting up BJORN application..."

    ensure_bjorn_user

    case "$MODE" in
        interactive)
            prepare_repo_install_mode
            ;;
        update)
            prepare_repo_update_mode
            ;;
        reinstall)
            prepare_repo_reinstall_mode
            ;;
    esac

    restore_shared_config

    cd "$BJORN_PATH" || return 1

    log "INFO" "Installing Python requirements..."
    pip3 install -r requirements.txt --break-system-packages
    check_success "Installed Python requirements"

    chown -R "$BJORN_USER:$BJORN_USER" "$BJORN_PATH"
    chmod -R 755 "$BJORN_PATH"

    usermod -a -G spi,gpio,i2c "$BJORN_USER"
    check_success "Added bjorn user to required groups"
}

# Configure services (idempotent)
setup_services() {
    log "INFO" "Setting up system services..."

    cat > "$BJORN_PATH/kill_port_8000.sh" << 'EOF'
#!/bin/bash
PORT=8000
PIDS=$(lsof -t -i:$PORT)
if [ -n "$PIDS" ]; then
    echo "Killing PIDs using port $PORT: $PIDS"
    kill -9 $PIDS
fi
EOF
    chmod +x "$BJORN_PATH/kill_port_8000.sh"

    cat > /etc/systemd/system/bjorn.service << EOF
[Unit]
Description=Bjorn Service
DefaultDependencies=no
Before=basic.target
After=local-fs.target

[Service]
ExecStartPre=/home/bjorn/Bjorn/kill_port_8000.sh
ExecStart=/usr/bin/python3 /home/bjorn/Bjorn/Bjorn.py
WorkingDirectory=/home/bjorn/Bjorn
StandardOutput=inherit
StandardError=inherit
Restart=always
User=root

# Check open files and restart if it reached the limit (ulimit -n buffer of 1000)
ExecStartPost=/bin/bash -c 'FILE_LIMIT=\$(ulimit -n); THRESHOLD=\$(( FILE_LIMIT - 1000 )); while :; do TOTAL_OPEN_FILES=\$(lsof | wc -l); if [ "\$TOTAL_OPEN_FILES" -ge "\$THRESHOLD" ]; then echo "File descriptor threshold reached: \$TOTAL_OPEN_FILES (threshold: \$THRESHOLD). Restarting service."; systemctl restart bjorn.service; exit 0; fi; sleep 10; done &'

[Install]
WantedBy=multi-user.target
EOF

    ensure_line_in_file /etc/pam.d/common-session "session required pam_limits.so"
    ensure_line_in_file /etc/pam.d/common-session-noninteractive "session required pam_limits.so"

    systemctl daemon-reload
    systemctl enable bjorn.service
    systemctl restart bjorn.service

    check_success "Services setup completed"
}

# Configure USB Gadget (idempotent)
configure_usb_gadget() {
    log "INFO" "Configuring USB Gadget..."

    if [ -f /boot/firmware/cmdline.txt ] && ! grep -q 'modules-load=dwc2,g_ether' /boot/firmware/cmdline.txt; then
        sed -i 's/rootwait/rootwait modules-load=dwc2,g_ether/' /boot/firmware/cmdline.txt
    fi

    ensure_line_in_file /boot/firmware/config.txt "dtoverlay=dwc2"

    cat > /usr/local/bin/usb-gadget.sh << 'EOF'
#!/bin/bash
set -e

modprobe libcomposite
cd /sys/kernel/config/usb_gadget/
mkdir -p g1
cd g1

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "Pi Zero USB" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Config 1: ECM network" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/ecm.usb0

if [ -L configs/c.1/ecm.usb0 ]; then
    rm configs/c.1/ecm.usb0
fi
ln -s functions/ecm.usb0 configs/c.1/

max_retries=10
retry_count=0

while ! ls /sys/class/udc > UDC 2>/dev/null; do
    if [ $retry_count -ge $max_retries ]; then
        echo "Error: Device or resource busy after $max_retries attempts."
        exit 1
    fi
    retry_count=$((retry_count + 1))
    sleep 1
done

if ! ip addr show usb0 | grep -q "172.20.2.1"; then
    ifconfig usb0 172.20.2.1 netmask 255.255.255.0
else
    echo "Interface usb0 already configured."
fi
EOF

    chmod +x /usr/local/bin/usb-gadget.sh

    cat > /etc/systemd/system/usb-gadget.service << EOF
[Unit]
Description=USB Gadget Service
After=network.target

[Service]
ExecStartPre=/sbin/modprobe libcomposite
ExecStart=/usr/local/bin/usb-gadget.sh
Type=simple
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if ! grep -q '^allow-hotplug usb0$' /etc/network/interfaces; then
        cat >> /etc/network/interfaces << EOF

allow-hotplug usb0
iface usb0 inet static
    address 172.20.2.1
    netmask 255.255.255.0
EOF
    fi

    systemctl daemon-reload
    systemctl enable systemd-networkd
    systemctl enable usb-gadget
    systemctl start systemd-networkd
    systemctl start usb-gadget

    check_success "USB Gadget configuration completed"
}

# Verify installation
verify_installation() {
    log "INFO" "Verifying installation..."

    if ! systemctl is-active --quiet bjorn.service; then
        log "WARNING" "BJORN service is not running"
    else
        log "SUCCESS" "BJORN service is running"
    fi

    sleep 5
    if curl -s http://localhost:8000 >/dev/null; then
        log "SUCCESS" "Web interface is accessible"
    else
        log "WARNING" "Web interface is not responding"
    fi
}

# Clean exit function
clean_exit() {
    local exit_code=$1

    rm -rf "$BACKUP_DIR"

    if [ $exit_code -eq 0 ]; then
        log "SUCCESS" "BJORN installation completed successfully!"
        log "INFO" "Log file available at: $LOG_FILE"
    else
        log "ERROR" "BJORN installation failed!"
        log "ERROR" "Check the log file for details: $LOG_FILE"
    fi

    exit $exit_code
}

choose_epd_interactive() {
    echo -e "\n${BLUE}Please select your E-Paper Display version:${NC}"
    echo "1. epd2in13"
    echo "2. epd2in13_V2"
    echo "3. epd2in13_V3"
    echo "4. epd2in13_V4"
    echo "5. epd2in7"

    while true; do
        read -r -p "Enter your choice (1-5): " epd_choice
        case $epd_choice in
            1) EPD_VERSION="epd2in13"; break ;;
            2) EPD_VERSION="epd2in13_V2"; break ;;
            3) EPD_VERSION="epd2in13_V3"; break ;;
            4) EPD_VERSION="epd2in13_V4"; break ;;
            5) EPD_VERSION="epd2in7"; break ;;
            *) echo -e "${RED}Invalid choice. Please select 1-5.${NC}" ;;
        esac
    done

    log "INFO" "Selected E-Paper Display version: $EPD_VERSION"
}

parse_args() {
    if [ $# -eq 0 ]; then
        MODE="interactive"
        return 0
    fi

    MODE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                print_help
                exit 0
                ;;
            --update)
                MODE="update"
                ;;
            --reinstall)
                MODE="reinstall"
                ;;
            --full-system)
                FULL_SYSTEM=true
                ;;
            --repo)
                shift
                [ $# -gt 0 ] || { echo "Missing value for --repo"; exit 1; }
                REPO_URL="$1"
                ;;
            --branch)
                shift
                [ $# -gt 0 ] || { echo "Missing value for --branch"; exit 1; }
                BRANCH="$1"
                ;;
            --yes)
                AUTO_YES=true
                ;;
            --epd)
                shift
                [ $# -gt 0 ] || { echo "Missing value for --epd"; exit 1; }
                EPD_VERSION="$1"
                ;;
            *)
                echo "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
        shift
    done

    if [ -z "$MODE" ]; then
        echo "Non-interactive mode requires --update or --reinstall."
        print_help
        exit 1
    fi
}

run_full_system_stack() {
    CURRENT_STEP=$((CURRENT_STEP + 1)); show_progress "Checking system compatibility"
    check_system_compatibility

    CURRENT_STEP=$((CURRENT_STEP + 1)); show_progress "Installing system dependencies"
    install_dependencies

    CURRENT_STEP=$((CURRENT_STEP + 1)); show_progress "Configuring system limits"
    configure_system_limits

    CURRENT_STEP=$((CURRENT_STEP + 1)); show_progress "Configuring interfaces"
    configure_interfaces

    CURRENT_STEP=$((CURRENT_STEP + 1)); show_progress "Configuring USB Gadget"
    configure_usb_gadget
}

run_interactive_install() {
    echo -e "${BLUE}BJORN Installation Options:${NC}"
    echo "1. Full installation (recommended)"
    echo "2. Custom installation"
    read -r -p "Choose an option (1/2): " install_option

    choose_epd_interactive

    case $install_option in
        1)
            MODE="interactive"
            TOTAL_STEPS=8
            CURRENT_STEP=0

            run_full_system_stack

            CURRENT_STEP=6; show_progress "Setting up BJORN"
            backup_shared_config
            setup_bjorn_app

            CURRENT_STEP=7; show_progress "Setting up services"
            setup_services

            CURRENT_STEP=8; show_progress "Verifying installation"
            verify_installation
            ;;
        2)
            echo "Custom installation - select components to install:"
            read -r -p "Install dependencies? (y/n): " deps
            read -r -p "Configure system limits? (y/n): " limits
            read -r -p "Configure interfaces? (y/n): " interfaces
            read -r -p "Setup BJORN? (y/n): " bjorn
            read -r -p "Configure USB Gadget? (y/n): " usb_gadget
            read -r -p "Setup services? (y/n): " services

            [ "$deps" = "y" ] && install_dependencies
            [ "$limits" = "y" ] && configure_system_limits
            [ "$interfaces" = "y" ] && configure_interfaces
            if [ "$bjorn" = "y" ]; then
                backup_shared_config
                setup_bjorn_app
            fi
            [ "$usb_gadget" = "y" ] && configure_usb_gadget
            [ "$services" = "y" ] && setup_services
            verify_installation
            ;;
        *)
            log "ERROR" "Invalid option selected"
            clean_exit 1
            ;;
    esac
}

run_day2_mode() {
    TOTAL_STEPS=7
    CURRENT_STEP=1; show_progress "Stopping BJORN service"
    stop_bjorn_runtime

    CURRENT_STEP=2; show_progress "Backing up shared config"
    backup_shared_config

    CURRENT_STEP=3; show_progress "Preparing repository"
    setup_bjorn_app

    if [ "$FULL_SYSTEM" = true ]; then
        TOTAL_STEPS=11
        CURRENT_STEP=3
        run_full_system_stack
    fi

    CURRENT_STEP=$((TOTAL_STEPS - 1)); show_progress "Setting up services"
    setup_services

    CURRENT_STEP=$TOTAL_STEPS; show_progress "Verifying installation"
    verify_installation
}

prompt_reboot_if_interactive() {
    if [ "$AUTO_YES" = true ] || [ "$MODE" != "interactive" ]; then
        log "INFO" "Skipping reboot prompt in non-interactive flow"
        return 0
    fi

    if ask_yes_no "Would you like to reboot now?"; then
        if reboot; then
            log "INFO" "System reboot initiated."
        else
            log "ERROR" "Failed to initiate reboot."
            clean_exit 1
        fi
    else
        echo -e "${YELLOW}Reboot your system to apply all changes and run Bjorn service.${NC}"
    fi
}

# Main installation process
main() {
    log "INFO" "Starting BJORN installation..."

    require_root
    parse_args "$@"

    if [ "$MODE" = "interactive" ]; then
        run_interactive_install
    else
        log "INFO" "Running mode: $MODE"
        log "INFO" "Repository: $REPO_URL (branch: $BRANCH)"
        run_day2_mode
    fi

    log "SUCCESS" "BJORN installation completed"
    echo -e "\n${GREEN}Installation completed successfully!${NC}"
    echo -e "${YELLOW}Important notes:${NC}"
    echo "1. If configuring Windows PC for USB gadget connection:"
    echo "   - Set static IP: 172.20.2.2"
    echo "   - Subnet Mask: 255.255.255.0"
    echo "   - Default Gateway: 172.20.2.1"
    echo "   - DNS Servers: 8.8.8.8, 8.8.4.4"
    echo "2. Web interface will be available at: http://[device-ip]:8000"
    echo "3. Make sure your e-Paper HAT (2.13-inch) is properly connected"

    prompt_reboot_if_interactive
    clean_exit 0
}

main "$@"
