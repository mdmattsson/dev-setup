#!/bin/bash
# <michael@mattsson.net>
# Cross-platform script to install common developer tools
# Supports: Rocky Linux, Arch Linux, Ubuntu/Debian
# Usage: sudo ./setup-tools.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
DISTRO=""
PACKAGE_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
SERVICE_MANAGER="systemctl"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}" 
   exit 1
fi

# Function to print status
print_header() {
    echo -e "\n${BLUE}=========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

print_section() {
    echo -e "\n${CYAN}$1${NC}"
}

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Function to detect distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            "rocky"|"rhel"|"centos"|"fedora")
                DISTRO="rocky"
                PACKAGE_MANAGER="dnf"
                UPDATE_CMD="dnf update -y"
                INSTALL_CMD="dnf install -y"
                ;;
            "arch"|"manjaro")
                DISTRO="arch"
                PACKAGE_MANAGER="pacman"
                UPDATE_CMD="pacman -Syu --noconfirm"
                INSTALL_CMD="pacman -S --noconfirm"
                ;;
            "ubuntu"|"debian"|"pop"|"linuxmint")
                DISTRO="ubuntu"
                PACKAGE_MANAGER="apt"
                UPDATE_CMD="apt update && apt upgrade -y"
                INSTALL_CMD="apt install -y"
                ;;
            *)
                print_error "Unsupported distribution: $ID"
                print_info "Supported distributions: Rocky Linux, Arch Linux, Ubuntu/Debian"
                exit 1
                ;;
        esac
    else
        print_error "Cannot detect distribution (missing /etc/os-release)"
        exit 1
    fi
    
    print_info "Detected distribution: $DISTRO ($PACKAGE_MANAGER)"
}

# Function to install packages with distribution-specific handling
install_packages() {
    local category="$1"
    shift
    local -n packages_ref=$1

    print_section "Installing $category..."

    for package in "${packages_ref[@]}"; do
        echo -n "Installing $package... "
        if eval "$INSTALL_CMD $package" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
    done
}

# Function to enable additional repositories
setup_repositories() {
    case "$DISTRO" in
        "rocky")
            print_section "Setting up additional repositories..."
            
            # Enable CRB repository
            if dnf config-manager --set-enabled crb &>/dev/null; then
                print_status "CRB repository enabled"
            else
                print_warning "Could not enable CRB repository"
            fi
            
            # Install EPEL
            if dnf install -y epel-release &>/dev/null; then
                print_status "EPEL repository installed"
            else
                print_warning "Could not install EPEL repository"
            fi

            # Enable lazygit COPR
            if dnf copr enable dejan/lazygit -y &>/dev/null; then
                print_status "Lazygit COPR repository enabled"
            else
                print_warning "Could not enable lazygit COPR repository"
            fi
            ;;
        "arch")
            print_section "Updating package databases..."
            pacman -Sy --noconfirm &>/dev/null
            print_status "Package databases updated"
            ;;
        "ubuntu")
            print_section "Setting up additional repositories..."
            
            # Add universe repository
            if add-apt-repository universe -y &>/dev/null; then
                print_status "Universe repository enabled"
            else
                print_warning "Could not enable universe repository"
            fi
            
            # Update package list
            apt update &>/dev/null
            print_status "Package lists updated"
            ;;
    esac
}

# Function to define packages for each distribution
define_packages() {
    case "$DISTRO" in
        "rocky")
            DEV_TOOLS=(
                "gcc" "gcc-c++" "golang" "gdb" "make" "cmake" "ninja-build"
                "pkg-config" "autoconf" "automake" "libtool" "glibc-static" "libstdc++-static"
            )
            VCS_TOOLS=("git" "lazygit" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "screen" "tmux" "xz" "unzip" "zip" "net-tools"
            )
            DEBUG_TOOLS=("gdb" "valgrind" "strace" "ltrace" "socat" "tcpdump" "wireshark-cli")
            PYTHON_TOOLS=("python3" "python3-pip" "python3-devel")
            DOC_TOOLS=("ghostscript" "ImageMagick")
            GRAPHICS_TOOLS=("mesa-libGL" "mesa-libGL-devel" "mesa-dri-drivers")
            EXTRA_TOOLS=("neofetch" "bat" "fd-find" "python3-virtualenv" "glx-utils")
            SSH_PACKAGE="openssh-server"
            ;;
        "arch")
            DEV_TOOLS=(
                "gcc" "go" "gdb" "make" "cmake" "ninja" "pkgconf" "autoconf" "automake" "libtool"
            )
            VCS_TOOLS=("git" "lazygit" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "screen" "tmux" "xz" "unzip" "zip" "net-tools"
            )
            DEBUG_TOOLS=("gdb" "valgrind" "strace" "ltrace" "socat" "tcpdump" "wireshark-cli")
            PYTHON_TOOLS=("python" "python-pip")
            DOC_TOOLS=("ghostscript" "imagemagick" "bison" "poppler-utils" "flex")
            GRAPHICS_TOOLS=("mesa" "mesa-utils")
            EXTRA_TOOLS=("neofetch" "bat" "fd" "python-virtualenv")
            SSH_PACKAGE="openssh"
            ;;
        "ubuntu")
            DEV_TOOLS=(
                "gcc" "g++" "golang-go" "gdb" "make" "cmake" "ninja-build"
                "pkg-config" "autoconf" "automake" "libtool"
            )
            VCS_TOOLS=("git" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "screen" "tmux" "xz-utils" "unzip" "zip" "net-tools"
            )
            DEBUG_TOOLS=("gdb" "valgrind" "strace" "ltrace" "socat" "tcpdump" "tshark")
            PYTHON_TOOLS=("python3" "python3-pip" "python3-dev")
            DOC_TOOLS=("ghostscript" "imagemagick")
            GRAPHICS_TOOLS=("mesa-utils" "mesa-utils-extra")
            EXTRA_TOOLS=("neofetch" "bat" "fd-find" "python3-virtualenv")
            SSH_PACKAGE="openssh-server"
            
            # Install lazygit from GitHub releases for Ubuntu
            install_lazygit_ubuntu() {
                print_section "Installing lazygit for Ubuntu..."
                LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
                if [[ -n "$LAZYGIT_VERSION" ]]; then
                    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
                    tar xf lazygit.tar.gz lazygit
                    install lazygit /usr/local/bin
                    rm lazygit lazygit.tar.gz
                    print_status "Lazygit installed from GitHub releases"
                else
                    print_warning "Could not determine lazygit version"
                fi
            }
            ;;
    esac
}

print_header "Installing Developer Tools for $DISTRO"

# Detect distribution
detect_distro

# Set up repositories
setup_repositories

# Define packages for detected distribution
define_packages

# Update system first
print_section "Updating system packages..."
eval "$UPDATE_CMD" &>/dev/null
print_status "System updated"

# Install package categories
install_packages "Development Tools & Compilers" DEV_TOOLS
install_packages "Version Control" VCS_TOOLS
install_packages "Text Editors" EDITORS
install_packages "System Utilities" SYSTEM_UTILS
install_packages "Debugging & Analysis Tools" DEBUG_TOOLS
install_packages "Python Development" PYTHON_TOOLS
install_packages "Document Processing" DOC_TOOLS
install_packages "Graphics & Mesa" GRAPHICS_TOOLS

# Install extra tools (may not be available on all distributions)
print_section "Installing additional tools..."
for tool in "${EXTRA_TOOLS[@]}"; do
    echo -n "Installing $tool... "
    if eval "$INSTALL_CMD $tool" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}⚠ Skipped${NC}"
    fi
done

# Special handling for Ubuntu lazygit
if [[ "$DISTRO" == "ubuntu" ]]; then
    install_lazygit_ubuntu
fi

# Install and configure SSH
print_section "Setting up SSH Server..."
if eval "$INSTALL_CMD $SSH_PACKAGE" &>/dev/null; then
    print_status "SSH Server installed"

    # Enable SSH
    systemctl enable sshd &>/dev/null || systemctl enable ssh &>/dev/null
    print_status "SSH service enabled for startup"

    # Start SSH
    if systemctl start sshd &>/dev/null || systemctl start ssh &>/dev/null; then
        print_status "SSH service started"
    else
        print_error "Failed to start SSH service"
        print_info "Check SSH configuration: systemctl status sshd"
    fi
else
    print_error "Failed to install SSH Server"
fi

# Verification
print_header "Verification"

print_section "Checking installed tools..."

# Check key tools
TOOLS_TO_CHECK=(
    "gcc --version"
    "gdb --version"
    "cmake --version"
    "git --version"
    "python3 --version"
)

# Add g++ check for distributions that have it
if [[ "$DISTRO" != "arch" ]]; then
    TOOLS_TO_CHECK+=("g++ --version")
fi

# Add SSH version check
case "$DISTRO" in
    "rocky"|"arch")
        TOOLS_TO_CHECK+=("ssh -V")
        ;;
    "ubuntu")
        TOOLS_TO_CHECK+=("ssh -V")
        ;;
esac

for tool_cmd in "${TOOLS_TO_CHECK[@]}"; do
    tool_name=$(echo "$tool_cmd" | cut -d' ' -f1)
    echo -n "Checking $tool_name... "
    if command -v "$tool_name" &>/dev/null; then
        version=$(eval "$tool_cmd" 2>&1 | head -1)
        echo -e "${GREEN}✓${NC} ($version)"
    else
        echo -e "${RED}✗ Not found${NC}"
    fi
done

# Check services
print_section "Checking services..."
echo -n "SSH service status... "
if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
    echo -e "${GREEN}✓ Running${NC}"
else
    echo -e "${YELLOW}⚠ Not running${NC}"
fi

# Summary
print_header "Installation Complete!"

echo -e "\n${YELLOW}Installed Categories:${NC}"
echo -e "• ${CYAN}Development Tools:${NC} gcc, gdb, cmake, make, ninja-build"
echo -e "• ${CYAN}Version Control:${NC} git, subversion"
if [[ "$DISTRO" != "ubuntu" ]] || command -v lazygit &>/dev/null; then
    echo -e "• ${CYAN}Enhanced Git:${NC} lazygit"
fi
echo -e "• ${CYAN}Text Editors:${NC} vim, neovim, nano, emacs"
echo -e "• ${CYAN}System Utilities:${NC} rsync, wget, curl, tree, htop, screen, tmux"
echo -e "• ${CYAN}Debugging Tools:${NC} valgrind, strace, ltrace, socat, tcpdump"
echo -e "• ${CYAN}Python Development:${NC} python3, pip, virtualenv"
echo -e "• ${CYAN}Document Processing:${NC} ghostscript, imagemagick"
echo -e "• ${CYAN}Graphics & Mesa:${NC} mesa utilities"
echo -e "• ${CYAN}Network Services:${NC} SSH server (enabled and started)"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "• Configure Git: ${BLUE}git config --global user.name 'Your Name'${NC}"
echo -e "• Configure Git: ${BLUE}git config --global user.email 'your@email.com'${NC}"
echo -e "• Configure SSH keys if needed"
echo -e "• Install additional language-specific tools as needed"

echo -e "\n${YELLOW}SSH Access:${NC}"
if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
    echo -e "• SSH server is running and enabled"
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
    if [[ -n "$IP_ADDR" ]]; then
        echo -e "• Connect with: ${BLUE}ssh username@$IP_ADDR${NC}"
    else
        echo -e "• Connect with: ${BLUE}ssh username@SERVER_IP${NC}"
    fi
else
    echo -e "• SSH server not running - may need manual configuration"
fi

# Distribution-specific firewall notes
case "$DISTRO" in
    "rocky"|"ubuntu")
        echo -e "• Configure firewall if needed: ${BLUE}sudo firewall-cmd --permanent --add-service=ssh${NC} (Rocky)"
        echo -e "  or ${BLUE}sudo ufw allow ssh${NC} (Ubuntu)"
        ;;
    "arch")
        echo -e "• Configure firewall if needed (iptables/ufw/firewalld)"
        ;;
esac

print_header "All developer tools installed successfully!"