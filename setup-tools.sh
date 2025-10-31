#!/usr/bin/env bash
# <michael@mattsson.net>
# Cross-platform script to install common developer tools
# Supports: Rocky Linux, Arch Linux, Ubuntu/Debian
# Enhanced version with advanced features

# Note: We don't use 'set -e' because the interactive menu uses commands
# that may return non-zero status codes during normal operation

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'
REVERSE='\033[7m'  # Reverse video (inverted colors)

# Global variables
DISTRO=""
PACKAGE_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
UNINSTALL_CMD=""
CHECK_INSTALLED_CMD=""
CHECK_UPDATES_CMD=""
SERVICE_MANAGER="systemctl"
INTERACTIVE_MODE=true
DRY_RUN_MODE=false
UNINSTALL_MODE=false
UPDATE_CHECK_MODE=false
CONTINUE_ON_ERROR=false
MAX_ITEM_WIDTH=40  # Default value, will be calculated later
LOG_FILE=""
SEARCH_FILTER=""
SHOW_HELP_FOOTER=true

# Arrays to track selected packages
declare -A SELECTED_PACKAGES
declare -A INSTALLED_PACKAGES
declare -A PACKAGE_DEPENDENCIES
declare -A PACKAGE_LONG_DESCRIPTIONS
declare -A INSTALLATION_ERRORS
declare -a ALL_ITEMS              # All items (both categories and packages)
declare -a FILTERED_ITEMS         # Filtered items for search
declare -a ITEM_TYPES             # Type: "category" or "package"
declare -a ITEM_CATEGORIES        # Category name for packages, or self for categories
declare -a ITEM_PACKAGES          # Package name (empty for categories)
declare -a ITEM_DESCRIPTIONS      # Descriptions

# Statistics
TOTAL_TO_INSTALL=0
TOTAL_INSTALLED_SUCCESS=0
TOTAL_INSTALLED_FAILED=0
TOTAL_SKIPPED=0

# Function to setup logging
setup_logging() {
    local log_dir="/var/log/dev-tools"
    mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp/dev-tools-logs"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/install-$(date +%Y%m%d-%H%M%S).log"
    
    # Write header to log
    {
        echo "========================================="
        echo "Developer Tools Installation Log"
        echo "Date: $(date)"
        echo "Distribution: $DISTRO"
        echo "Package Manager: $PACKAGE_MANAGER"
        echo "Mode: $([ "$DRY_RUN_MODE" = true ] && echo "DRY RUN" || echo "INSTALL")"
        echo "========================================="
        echo ""
    } > "$LOG_FILE"
}

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Function to check if a package is installed
is_package_installed() {
    local package=$1
    case "$DISTRO" in
        "rocky")
            rpm -q "$package" &>/dev/null
            ;;
        "arch")
            pacman -Q "$package" &>/dev/null
            ;;
        "ubuntu")
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
    esac
    return $?
}

# Function to check if package has updates available
has_package_updates() {
    local package=$1
    case "$DISTRO" in
        "rocky")
            dnf list updates "$package" 2>/dev/null | grep -q "$package"
            ;;
        "arch")
            pacman -Qu "$package" 2>/dev/null | grep -q "$package"
            ;;
        "ubuntu")
            apt list --upgradable 2>/dev/null | grep -q "^$package/"
            ;;
    esac
    return $?
}

# Function to scan installed packages
scan_installed_packages() {
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            if is_package_installed "$pkg"; then
                INSTALLED_PACKAGES[$pkg]=1
            else
                INSTALLED_PACKAGES[$pkg]=0
            fi
        fi
    done
}

# Function to calculate maximum item width for padding
calculate_max_item_width() {
    local max_width=0
    
    # Determine which indices to iterate over
    local -a indices_to_check=()
    if [[ -n "$SEARCH_FILTER" ]] && [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
        # Use filtered indices
        indices_to_check=("${FILTERED_ITEMS[@]}")
    else
        # Use all indices
        for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
            indices_to_check+=("$i")
        done
    fi
    
    for item_idx in "${indices_to_check[@]}"; do
        local item="${ALL_ITEMS[$item_idx]}"
        local type="${ITEM_TYPES[$item_idx]}"
        local desc="${ITEM_DESCRIPTIONS[$item_idx]}"
        
        local item_width=0
        if [[ "$type" == "category" ]]; then
            # For categories: item + space + desc
            item_width=$((${#item} + 1 + ${#desc}))
        else
            # For packages: just item
            item_width=${#item}
        fi
        
        if [[ $item_width -gt $max_width ]]; then
            max_width=$item_width
        fi
    done
    
    # Cap at reasonable maximum to prevent excessive padding (60 chars max)
    if [[ $max_width -gt 60 ]]; then
        max_width=60
    fi
    
    MAX_ITEM_WIDTH=$max_width
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}" 
   exit 1
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --all|-a)
            INTERACTIVE_MODE=false
            shift
            ;;
        --dry-run|-d)
            DRY_RUN_MODE=true
            shift
            ;;
        --uninstall|-u)
            UNINSTALL_MODE=true
            INTERACTIVE_MODE=true
            shift
            ;;
        --check-updates|-c)
            UPDATE_CHECK_MODE=true
            INTERACTIVE_MODE=false
            shift
            ;;
        --continue)
            CONTINUE_ON_ERROR=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, -a           Install all packages without interactive selection"
            echo "  --dry-run, -d       Show what would be installed without installing"
            echo "  --uninstall, -u     Uninstall packages interactively"
            echo "  --check-updates, -c Check for updates to installed packages"
            echo "  --continue          Continue installing even if individual packages fail"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Default behavior: Interactive mode with package selection"
            echo ""
            echo "Interactive Mode Controls:"
            echo "  ↑/↓ or k/j          Navigate up/down"
            echo "  Space               Toggle package selection"
            echo "  a                   Select all packages"
            echo "  n                   Deselect all packages"
            echo "  /                   Live search (type to filter, Enter to confirm, Esc to cancel)"
            echo "  Esc                 Clear search filter"
            echo "  i                   Install/uninstall selected packages"
            echo "  ?                   Toggle help footer"
            echo "  q                   Quit without installing"
            exit 0
            ;;
    esac
done

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
    log_message "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
    log_message "WARNING: $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
    log_message "ERROR: $1"
}

print_info() {
    echo -e "${BLUE}🛈${NC} $1"
    log_message "INFO: $1"
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
                UNINSTALL_CMD="dnf remove -y"
                CHECK_INSTALLED_CMD="rpm -q"
                CHECK_UPDATES_CMD="dnf list updates"
                ;;
            "arch"|"manjaro")
                DISTRO="arch"
                PACKAGE_MANAGER="pacman"
                UPDATE_CMD="pacman -Syu --noconfirm"
                INSTALL_CMD="pacman -S --noconfirm"
                UNINSTALL_CMD="pacman -R --noconfirm"
                CHECK_INSTALLED_CMD="pacman -Q"
                CHECK_UPDATES_CMD="pacman -Qu"
                ;;
            "ubuntu"|"debian"|"pop"|"linuxmint")
                DISTRO="ubuntu"
                PACKAGE_MANAGER="apt"
                UPDATE_CMD="apt update && apt upgrade -y"
                INSTALL_CMD="apt install -y"
                UNINSTALL_CMD="apt remove -y"
                CHECK_INSTALLED_CMD="dpkg -l"
                CHECK_UPDATES_CMD="apt list --upgradable"
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

            # Enable lazygit COPR (skip if fails to avoid hanging)
            if timeout 10 dnf copr enable dejan/lazygit -y --assumeyes 2>/dev/null; then
                print_status "Lazygit COPR repository enabled"
            else
                print_warning "Could not enable lazygit COPR repository (skipped)"
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

# Function to install Zig from official releases (Rocky Linux)
install_zig_rocky() {
    print_section "Installing Zig for Rocky Linux..."
    ZIG_VERSION=$(curl -s "https://ziglang.org/download/index.json" | grep -Po '"master":\s*{\s*"version":\s*"\K[^"]*' | head -1)
    if [[ -z "$ZIG_VERSION" ]]; then
        # Fallback to latest stable version
        ZIG_VERSION=$(curl -s "https://ziglang.org/download/index.json" | grep -Po '"[0-9]+\.[0-9]+\.[0-9]+":\s*{' | head -1 | grep -Po '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    
    if [[ -n "$ZIG_VERSION" ]]; then
        local arch=$(uname -m)
        
        print_status "downloading https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
        curl -Lo zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
        tar -xf zig.tar.xz
        local zig_dir=$(ls -d zig-${arch}-linux-* | head -1)
        if [[ -d "$zig_dir" ]]; then
            rm -rf /usr/local/zig
            mv "$zig_dir" /usr/local/zig
            ln -sf /usr/local/zig/zig /usr/local/bin/zig
            rm zig.tar.xz
            print_status "Zig $ZIG_VERSION installed from official releases"
        else
            print_warning "Could not extract Zig archive"
            rm -f zig.tar.xz
        fi
    else
        print_warning "Could not determine Zig version"
    fi
}

# Function to define packages for each distribution
define_packages() {
    case "$DISTRO" in
        "rocky")
            CPP_TOOLS=(
                "gcc" "gcc-c++" "golang" "gdb" "make" "cmake" "ninja-build"
                "pkg-config" "autoconf" "automake" "libtool" "glibc-static" "libstdc++-static"
            )
            LANG_TOOLS=("rust" "cargo")
            VCS_TOOLS=("git" "lazygit" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "iotop" "lsof" "nc"
                "screen" "tmux" "zip" "unzip" "bzip2" "p7zip" "openssh-server"
            )
            DEBUG_TOOLS=("valgrind" "strace" "ltrace" "lshw" "perf" "socat" "tcpdump")
            PYTHON_TOOLS=("python3" "python3-pip" "python3-virtualenv")
            DOC_TOOLS=("ghostscript" "ImageMagick")
            GRAPHICS_TOOLS=("mesa-libGL" "mesa-libGL-devel" "glx-utils")
            EXTRA_TOOLS=("bear" "clang-tools-extra")
            SPECIAL_INSTALLS=("zig")
            SSH_PACKAGE="openssh-server"
            ;;
        "arch")
            CPP_TOOLS=(
                "base-devel" "gcc" "gdb" "cmake" "ninja" "go"
                "pkg-config" "autoconf" "automake" "libtool"
            )
            LANG_TOOLS=("rust" "zig")
            VCS_TOOLS=("git" "lazygit" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "iotop" "lsof" "gnu-netcat"
                "screen" "tmux" "zip" "unzip" "bzip2" "p7zip"
            )
            DEBUG_TOOLS=("valgrind" "strace" "ltrace" "lshw" "perf" "socat" "tcpdump")
            PYTHON_TOOLS=("python" "python-pip" "python-virtualenv")
            DOC_TOOLS=("ghostscript" "imagemagick")
            GRAPHICS_TOOLS=("mesa" "mesa-utils")
            EXTRA_TOOLS=("bear" "clang")
            SPECIAL_INSTALLS=()
            SSH_PACKAGE="openssh"
            ;;
        "ubuntu")
            CPP_TOOLS=(
                "build-essential" "gcc" "g++" "golang" "gdb" "make" "cmake" "ninja-build"
                "pkg-config" "autoconf" "automake" "libtool"
            )
            LANG_TOOLS=("rustc" "cargo")
            VCS_TOOLS=("git" "subversion")
            EDITORS=("vim" "neovim" "nano" "emacs" "dos2unix")
            SYSTEM_UTILS=(
                "rsync" "wget" "curl" "tree" "htop" "iotop" "lsof" "netcat"
                "screen" "tmux" "zip" "unzip" "bzip2" "p7zip-full"
            )
            DEBUG_TOOLS=("valgrind" "strace" "ltrace" "lshw" "linux-tools-generic" "socat" "tcpdump")
            PYTHON_TOOLS=("python3" "python3-pip" "python3-venv")
            DOC_TOOLS=("ghostscript" "imagemagick")
            GRAPHICS_TOOLS=("mesa-utils" "libgl1-mesa-dev")
            EXTRA_TOOLS=("bear" "clangd")
            SPECIAL_INSTALLS=("zig" "lazygit")
            SSH_PACKAGE="openssh-server"
            ;;
    esac
    
    # Define package dependencies (packages that depend on others in the list)
    PACKAGE_DEPENDENCIES["cargo"]="rust rustc"
    PACKAGE_DEPENDENCIES["python3-pip"]="python3 python"
    PACKAGE_DEPENDENCIES["python-pip"]="python python3"
    PACKAGE_DEPENDENCIES["python3-virtualenv"]="python3 python3-pip"
    PACKAGE_DEPENDENCIES["python-virtualenv"]="python python-pip"
    PACKAGE_DEPENDENCIES["clang-tools-extra"]="clang"
    
    # Define detailed package descriptions
    PACKAGE_LONG_DESCRIPTIONS["gcc"]="GNU C compiler - essential for building C programs"
    PACKAGE_LONG_DESCRIPTIONS["gcc-c++"]="GNU C++ compiler - required for C++ development"
    PACKAGE_LONG_DESCRIPTIONS["g++"]="GNU C++ compiler - required for C++ development"
    PACKAGE_LONG_DESCRIPTIONS["gdb"]="GNU debugger - powerful debugging tool for C/C++"
    PACKAGE_LONG_DESCRIPTIONS["cmake"]="Cross-platform build system generator"
    PACKAGE_LONG_DESCRIPTIONS["make"]="GNU Make - automates building of programs"
    PACKAGE_LONG_DESCRIPTIONS["ninja-build"]="Fast build system, alternative to Make"
    PACKAGE_LONG_DESCRIPTIONS["rust"]="Rust programming language compiler"
    PACKAGE_LONG_DESCRIPTIONS["rustc"]="Rust programming language compiler"
    PACKAGE_LONG_DESCRIPTIONS["cargo"]="Rust package manager and build tool"
    PACKAGE_LONG_DESCRIPTIONS["golang"]="Go programming language compiler"
    PACKAGE_LONG_DESCRIPTIONS["go"]="Go programming language compiler"
    PACKAGE_LONG_DESCRIPTIONS["zig"]="Zig programming language - modern systems programming"
    PACKAGE_LONG_DESCRIPTIONS["git"]="Distributed version control system"
    PACKAGE_LONG_DESCRIPTIONS["lazygit"]="Terminal UI for git - visual git operations"
    PACKAGE_LONG_DESCRIPTIONS["subversion"]="Centralized version control system (SVN)"
    PACKAGE_LONG_DESCRIPTIONS["vim"]="Powerful terminal-based text editor"
    PACKAGE_LONG_DESCRIPTIONS["neovim"]="Modern Vim fork with better defaults"
    PACKAGE_LONG_DESCRIPTIONS["nano"]="Simple, easy-to-use text editor"
    PACKAGE_LONG_DESCRIPTIONS["emacs"]="Extensible, customizable text editor"
    PACKAGE_LONG_DESCRIPTIONS["valgrind"]="Memory debugging and profiling tool"
    PACKAGE_LONG_DESCRIPTIONS["strace"]="System call tracer for debugging"
    PACKAGE_LONG_DESCRIPTIONS["ltrace"]="Library call tracer"
    PACKAGE_LONG_DESCRIPTIONS["htop"]="Interactive process viewer"
    PACKAGE_LONG_DESCRIPTIONS["tmux"]="Terminal multiplexer - multiple terminals in one"
    PACKAGE_LONG_DESCRIPTIONS["screen"]="Terminal multiplexer"
    PACKAGE_LONG_DESCRIPTIONS["python3"]="Python 3 programming language"
    PACKAGE_LONG_DESCRIPTIONS["python"]="Python programming language"
    PACKAGE_LONG_DESCRIPTIONS["build-essential"]="Essential build tools for Ubuntu/Debian"
    PACKAGE_LONG_DESCRIPTIONS["base-devel"]="Essential build tools for Arch Linux"
}

# Function to install lazygit on Ubuntu
install_lazygit_ubuntu() {
    print_section "Installing lazygit for Ubuntu..."
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    if [[ -n "$LAZYGIT_VERSION" ]]; then
        curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xf lazygit.tar.gz lazygit
        install lazygit /usr/local/bin
        rm lazygit lazygit.tar.gz
        print_status "lazygit installed from GitHub releases"
    else
        print_warning "Could not determine lazygit version"
    fi
}

# Function to install Zig on Ubuntu
install_zig_ubuntu() {
    print_section "Installing Zig for Ubuntu..."
    ZIG_VERSION=$(curl -s "https://ziglang.org/download/index.json" | grep -Po '"master":\s*{\s*"version":\s*"\K[^"]*' | head -1)
    if [[ -z "$ZIG_VERSION" ]]; then
        # Fallback to latest stable version
        ZIG_VERSION=$(curl -s "https://ziglang.org/download/index.json" | grep -Po '"[0-9]+\.[0-9]+\.[0-9]+":\s*{' | head -1 | grep -Po '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    
    if [[ -n "$ZIG_VERSION" ]]; then
        local arch=$(uname -m)
        curl -Lo zig.tar.xz "https://ziglang.org/builds/zig-linux-${arch}-${ZIG_VERSION}.tar.xz"
        tar -xf zig.tar.xz
        local zig_dir=$(ls -d zig-linux-${arch}-* | head -1)
        if [[ -d "$zig_dir" ]]; then
            rm -rf /usr/local/zig
            mv "$zig_dir" /usr/local/zig
            ln -sf /usr/local/zig/zig /usr/local/bin/zig
            rm zig.tar.xz
            print_status "Zig $ZIG_VERSION installed from official releases"
        else
            print_warning "Could not extract Zig archive"
            rm -f zig.tar.xz
        fi
    else
        print_warning "Could not determine Zig version"
    fi
}

# Helper functions for package list management
add_category() {
    local name="$1"
    local desc="$2"
    ALL_ITEMS+=("$name")
    ITEM_TYPES+=("category")
    ITEM_CATEGORIES+=("$name")
    ITEM_PACKAGES+=("")
    ITEM_DESCRIPTIONS+=("$desc")
}

add_package() {
    local name="$1"
    local category="$2"
    local desc="${3:-}"
    ALL_ITEMS+=("$name")
    ITEM_TYPES+=("package")
    ITEM_CATEGORIES+=("$category")
    ITEM_PACKAGES+=("$name")
    ITEM_DESCRIPTIONS+=("$desc")
    
    # Initialize package as unselected
    SELECTED_PACKAGES[$name]=0
}

# Function to populate package list
populate_package_list() {
    # Development Tools
    add_category "Development Tools" "Core build tools"
    for pkg in "${CPP_TOOLS[@]}"; do
        add_package "$pkg" "C++ Compiler Tools"
    done
    
    # Programming Languages
    if [[ ${#LANG_TOOLS[@]} -gt 0 ]] || [[ " ${SPECIAL_INSTALLS[@]} " =~ " zig " ]]; then
        add_category "Programming Languages" "Rust, Zig, etc."
        for pkg in "${LANG_TOOLS[@]}"; do
            add_package "$pkg" "Programming Languages"
        done
        # Add zig if it's in SPECIAL_INSTALLS (Rocky/Ubuntu)
        if [[ " ${SPECIAL_INSTALLS[@]} " =~ " zig " ]]; then
            add_package "zig" "Programming Languages"
        fi
    fi
    
    # Version Control
    add_category "Version Control" "Git, SVN, etc."
    for pkg in "${VCS_TOOLS[@]}"; do
        add_package "$pkg" "Version Control"
    done
    # Add lazygit if it's in SPECIAL_INSTALLS (Ubuntu)
    if [[ " ${SPECIAL_INSTALLS[@]} " =~ " lazygit " ]] && [[ ! " ${VCS_TOOLS[@]} " =~ " lazygit " ]]; then
        add_package "lazygit" "Version Control"
    fi
    
    # Text Editors
    add_category "Text Editors" "Vim, Neovim, Emacs"
    for pkg in "${EDITORS[@]}"; do
        add_package "$pkg" "Text Editors"
    done
    
    # System Utilities
    add_category "System Utilities" "Essential CLI tools"
    for pkg in "${SYSTEM_UTILS[@]}"; do
        add_package "$pkg" "System Utilities"
    done
    
    # Debugging Tools
    add_category "Debugging & Analysis" "Valgrind, strace, etc."
    for pkg in "${DEBUG_TOOLS[@]}"; do
        add_package "$pkg" "Debugging & Analysis"
    done
    
    # Python Development
    add_category "Python Development" "Python3 & tools"
    for pkg in "${PYTHON_TOOLS[@]}"; do
        add_package "$pkg" "Python Development"
    done
    
    # Document Processing
    add_category "Document Processing" "Ghostscript, ImageMagick"
    for pkg in "${DOC_TOOLS[@]}"; do
        add_package "$pkg" "Document Processing"
    done
    
    # Graphics & Mesa
    add_category "Graphics & Mesa" "OpenGL utilities"
    for pkg in "${GRAPHICS_TOOLS[@]}"; do
        add_package "$pkg" "Graphics & Mesa"
    done
    
    # Extra Tools
    add_category "Extra Tools" "Optional development tools"
    for pkg in "${EXTRA_TOOLS[@]}"; do
        add_package "$pkg" "Extra Tools"
    done
}

# Function to apply search filter
apply_search_filter() {
    FILTERED_ITEMS=()
    
    # Debug output
    echo "DEBUG: apply_search_filter called, SEARCH_FILTER='$SEARCH_FILTER'" >> /tmp/search_debug.log
    
    if [[ -z "$SEARCH_FILTER" ]]; then
        # No filter, show all items
        for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
            FILTERED_ITEMS+=("$i")
        done
        echo "DEBUG: No filter, returning all ${#FILTERED_ITEMS[@]} items" >> /tmp/search_debug.log
        return
    fi
    
    # Convert search to lowercase for case-insensitive matching
    local search_lower=$(echo "$SEARCH_FILTER" | tr '[:upper:]' '[:lower:]')
    echo "DEBUG: search_lower='$search_lower'" >> /tmp/search_debug.log
    
    # Track which categories have matching packages
    declare -A matching_categories
    
    # First pass: find matching packages and track their categories
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        local item="${ALL_ITEMS[$i]}"
        local type="${ITEM_TYPES[$i]}"
        local item_lower=$(echo "$item" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$type" == "package" ]] && [[ "$item_lower" == *"$search_lower"* ]]; then
            local category="${ITEM_CATEGORIES[$i]}"
            matching_categories[$category]=1
            echo "DEBUG: Found match: $item (cat: $category)" >> /tmp/search_debug.log
        fi
    done
    
    # Second pass: add categories and their matching packages
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        local item="${ALL_ITEMS[$i]}"
        local type="${ITEM_TYPES[$i]}"
        local category="${ITEM_CATEGORIES[$i]}"
        local item_lower=$(echo "$item" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$type" == "category" ]]; then
            # Add category if it has matching packages
            if [[ ${matching_categories[$item]} -eq 1 ]]; then
                FILTERED_ITEMS+=("$i")
                echo "DEBUG: Added category $i: $item" >> /tmp/search_debug.log
            fi
        else
            # Add package if it matches
            if [[ "$item_lower" == *"$search_lower"* ]]; then
                FILTERED_ITEMS+=("$i")
                echo "DEBUG: Added package $i: $item" >> /tmp/search_debug.log
            fi
        fi
    done
    
    echo "DEBUG: Filtered to ${#FILTERED_ITEMS[@]} items" >> /tmp/search_debug.log
}

# Function to resolve dependencies
resolve_dependencies() {
    local package=$1
    local -a deps=()
    
    # Check if package has dependencies defined
    if [[ -n "${PACKAGE_DEPENDENCIES[$package]}" ]]; then
        read -ra deps <<< "${PACKAGE_DEPENDENCIES[$package]}"
        
        for dep in "${deps[@]}"; do
            # Check if dependency exists in our package list
            for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                if [[ "${ITEM_TYPES[$i]}" == "package" ]] && [[ "${ITEM_PACKAGES[$i]}" == "$dep" ]]; then
                    # Auto-select the dependency
                    if [[ ${SELECTED_PACKAGES[$dep]} -eq 0 ]]; then
                        SELECTED_PACKAGES[$dep]=1
                        print_info "Auto-selected dependency: $dep (required by $package)"
                    fi
                    break
                fi
            done
        done
    fi
}

# Function to get category selection state
# Returns: 0 = none selected, 1 = all selected, 2 = some selected
get_category_selection_state() {
    local category=$1
    local total=0
    local selected=0
    
    for ((j=0; j<${#ALL_ITEMS[@]}; j++)); do
        if [[ "${ITEM_TYPES[$j]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$j]}" == "$category" ]]; then
            ((total++))
            local pkg="${ITEM_PACKAGES[$j]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((selected++))
            fi
        fi
    done
    
    if [[ $total -eq 0 ]]; then
        echo 0
    elif [[ $selected -eq 0 ]]; then
        echo 0
    elif [[ $selected -eq $total ]]; then
        echo 1
    else
        echo 2
    fi
}

# Function to draw the interactive menu
draw_menu() {
    local selected_index=$1
    local scroll_offset=$2
    local terminal_height=$(tput lines)
    # Calculate overhead:
    # - Header: 4 lines (box with title and distro)
    # - After header blank: 1 line
    # - Search line (if active): 0-1 line
    # - Selected count: 1 line
    # - Before items blank: 1 line
    # - Scroll indicators: 3 lines
    # - Description section: 2 lines (blank + description)
    # - Footer (if shown): 5 lines
    # Total: 12 base + 2 description = 14 (no footer) or 19 (with footer)
    local search_lines=$([[ -n "$SEARCH_FILTER" ]] && echo 1 || echo 0)
    local overhead=$([[ "$SHOW_HELP_FOOTER" == true ]] && echo $((19 + search_lines)) || echo $((14 + search_lines)))
    local visible_lines=$((terminal_height - overhead))
    
    # Move cursor to top instead of clearing screen (prevents flicker)
    tput cup 0 0
    
    # Clear from cursor to end of screen
    tput ed
    
    # Box width (inner content should be 68 chars)
    local box_width=68
    
    # Header
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    
    # Line 1: Title (centered)
    local mode_text="Interactive Mode"
    if [[ "$UNINSTALL_MODE" == true ]]; then
        mode_text="Uninstall Mode"
    elif [[ "$DRY_RUN_MODE" == true ]]; then
        mode_text="Dry Run Mode"
    fi
    
    local title="Developer Tools Installation - $mode_text"
    local title_len=${#title}
    local left_pad=$(( (box_width - title_len) / 2 ))
    local right_pad=$(( box_width - title_len - left_pad ))
    printf "${BOLD}${BLUE}║${NC}"
    printf "%*s" $left_pad ""
    printf "${BOLD}%s${NC}" "$title"
    printf "%*s" $right_pad ""
    printf "${BOLD}${BLUE}║${NC}\n"
    
    # Line 2: Distribution (centered)
    local dist_plain="Distribution: ${DISTRO} (${PACKAGE_MANAGER})"
    local dist_len=${#dist_plain}
    local left_pad=$(( (box_width - dist_len) / 2 ))
    local right_pad=$(( box_width - dist_len - left_pad ))
    printf "${BOLD}${BLUE}║${NC}"
    printf "%*s" $left_pad ""
    printf "Distribution: ${CYAN}%s${NC} (%s)" "$DISTRO" "$PACKAGE_MANAGER"
    printf "%*s" $right_pad ""
    printf "${BOLD}${BLUE}║${NC}\n"
    
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Show search filter if active
    if [[ -n "$SEARCH_FILTER" ]]; then
        echo -e "${YELLOW}Search: ${BOLD}$SEARCH_FILTER${NC} ${DIM}(updating live, Esc to clear)${NC} ${DIM}[showing ${#FILTERED_ITEMS[@]} of ${#ALL_ITEMS[@]} items]${NC}"
    fi
    
    # Count selected packages (not categories)
    local selected_count=0
    local total_packages=0
    local installed_count=0
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            ((total_packages++)) || true
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((selected_count++)) || true
            fi
            if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((installed_count++)) || true
            fi
        fi
    done
    
    echo -e "${DIM}Selected: ${BOLD}$selected_count${NC}${DIM} / $total_packages packages${NC} ${DIM}(${GREEN}$installed_count installed${NC}${DIM})${NC}"
    echo ""
    
    # Determine which items to display (filtered or all)
    local -a indices_to_display=()
    
    if [[ -n "$SEARCH_FILTER" ]]; then
        # Search is active - use filtered items (even if empty)
        indices_to_display=("${FILTERED_ITEMS[@]}")
    else
        # No search - show all items
        for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
            indices_to_display+=("$i")
        done
    fi
    
    # Display items
    local start_idx=$scroll_offset
    local end_idx=$((scroll_offset + visible_lines))
    
    if [[ $end_idx -gt ${#indices_to_display[@]} ]]; then
        end_idx=${#indices_to_display[@]}
    fi
    
    for ((display_idx=start_idx; display_idx<end_idx; display_idx++)); do
        local i=${indices_to_display[$display_idx]}
        local item="${ALL_ITEMS[$i]}"
        local type="${ITEM_TYPES[$i]}"
        local category="${ITEM_CATEGORIES[$i]}"
        local pkg="${ITEM_PACKAGES[$i]}"
        local desc="${ITEM_DESCRIPTIONS[$i]}"
        
        local indicator="  "
        if [[ $display_idx -eq $selected_index ]]; then
            indicator="▶ "
        fi
        
        if [[ "$type" == "category" ]]; then
            # Category header - check selection state
            local state=$(get_category_selection_state "$category")
            local checkbox="[ ]"
            
            case $state in
                0) checkbox="[ ]" ;;
                1) checkbox="${GREEN}[✓]${NC}" ;;
                2) checkbox="${YELLOW}[○]${NC}" ;;
            esac
            
            # Highlight selected line
            if [[ $display_idx -eq $selected_index ]]; then
                # Calculate padding for inverted bar
                local content_len=$((${#item} + 1 + ${#desc}))
                local padding=$((MAX_ITEM_WIDTH - content_len))
                
                if [[ $padding -lt 0 ]]; then
                    padding=0
                elif [[ $padding -gt 100 ]]; then
                    padding=100
                fi
                
                local pad_str=$(printf '%*s' $padding '')
                
                echo -e "$indicator$checkbox ${REVERSE}$item $desc$pad_str${NC}"
            else
                echo -e "$indicator$checkbox ${BOLD}${CYAN}$item${NC} ${DIM}$desc${NC}"
            fi
        else
            # Package item
            local checkbox="[ ]"
            local install_marker=""
            
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                checkbox="${GREEN}[✓]${NC}"
            fi
            
            # Show if already installed
            if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                install_marker=" ${DIM}${GREEN}(installed)${NC}"
            fi
            
            # Highlight selected line
            if [[ $display_idx -eq $selected_index ]]; then
                local content_len=$((${#item} + ${#install_marker}))
                local padding=$((MAX_ITEM_WIDTH - content_len))
                
                if [[ $padding -lt 0 ]]; then
                    padding=0
                elif [[ $padding -gt 100 ]]; then
                    padding=100
                fi
                
                local pad_str=$(printf '%*s' $padding '')
                
                echo -e "    $indicator$checkbox ${REVERSE}$item$install_marker$pad_str${NC}"
            else
                echo -e "    $indicator$checkbox $item$install_marker"
            fi
        fi
    done
    
    # Clear any remaining lines in the display area
    local lines_drawn=$((end_idx - start_idx))
    local lines_to_clear=$((visible_lines - lines_drawn))
    for ((i=0; i<lines_to_clear; i++)); do
        echo ""
    done
    
    # Show scroll indicators
    if [[ $scroll_offset -gt 0 ]]; then
        echo ""
        echo -e "${DIM}        ▲ More items above ▲${NC}"
    else
        echo ""
        echo ""
    fi
    
    if [[ $end_idx -lt ${#indices_to_display[@]} ]]; then
        echo -e "${DIM}        ▼ More items below ▼${NC}"
    else
        echo ""
    fi
    
    # Show detailed description for selected item
    local selected_actual_idx=${indices_to_display[$selected_index]}
    local selected_pkg="${ITEM_PACKAGES[$selected_actual_idx]}"
    if [[ -n "$selected_pkg" ]] && [[ -n "${PACKAGE_LONG_DESCRIPTIONS[$selected_pkg]}" ]]; then
        echo ""
        echo -e "${DIM}${PACKAGE_LONG_DESCRIPTIONS[$selected_pkg]}${NC}"
    else
        echo ""
    fi
    
    # Footer with controls (only if enabled)
    if [[ "$SHOW_HELP_FOOTER" == true ]]; then
        echo ""
        echo -e "${BOLD}${BLUE}────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${BOLD}Controls:${NC} ${DIM}[↑/↓ k/j]${NC} Nav  ${DIM}[Space]${NC} Toggle  ${DIM}[a]${NC} All  ${DIM}[n]${NC} None  ${DIM}[/]${NC} Search"
        echo -e "          ${DIM}[i]${NC} ${GREEN}Install${NC}  ${DIM}[?]${NC} Help  ${DIM}[q]${NC} Quit"
        echo -e "${BOLD}${BLUE}────────────────────────────────────────────────────────────────────${NC}"
    fi
}

# Function to draw a single menu line (for efficient updates)
draw_single_line() {
    local display_index=$1
    local is_selected=$2
    local screen_line=$3
    
    # Get actual item index from filtered/all list
    local -a indices_to_use=()
    if [[ -n "$SEARCH_FILTER" ]] && [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
        indices_to_use=("${FILTERED_ITEMS[@]}")
    else
        for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
            indices_to_use+=("$i")
        done
    fi
    
    local index=${indices_to_use[$display_index]}
    local item="${ALL_ITEMS[$index]}"
    local type="${ITEM_TYPES[$index]}"
    local category="${ITEM_CATEGORIES[$index]}"
    local pkg="${ITEM_PACKAGES[$index]}"
    local desc="${ITEM_DESCRIPTIONS[$index]}"
    
    # Position cursor at the correct screen line
    # Overhead from top of screen to start of items:
    # - Header: 4, blank: 1, search (if active): 0-1, selected count: 1, blank: 1
    local search_lines=$([[ -n "$SEARCH_FILTER" ]] && echo 1 || echo 0)
    local overhead=$((7 + search_lines))
    tput cup $((overhead + screen_line)) 0
    
    # Build the line content
    local line_content=""
    local indicator="  "
    
    if [[ $is_selected -eq 1 ]]; then
        indicator="▶ "
    fi
    
    if [[ "$type" == "category" ]]; then
        # Category header
        local state=$(get_category_selection_state "$category")
        local checkbox="[ ]"
        
        case $state in
            0) checkbox="[ ]" ;;
            1) checkbox="${GREEN}[✓]${NC}" ;;
            2) checkbox="${YELLOW}[○]${NC}" ;;
        esac
        
        if [[ $is_selected -eq 1 ]]; then
            local content_len=$((${#item} + 1 + ${#desc}))
            local padding=$((MAX_ITEM_WIDTH - content_len))
            
            if [[ $padding -lt 0 ]]; then
                padding=0
            elif [[ $padding -gt 100 ]]; then
                padding=100
            fi
            
            local pad_str=$(printf '%*s' $padding '')
            line_content="$indicator$checkbox ${REVERSE}$item $desc$pad_str${NC}"
        else
            line_content="$indicator$checkbox ${BOLD}${CYAN}$item${NC} ${DIM}$desc${NC}"
        fi
    else
        # Package item
        local checkbox="[ ]"
        local install_marker=""
        
        if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
            checkbox="${GREEN}[✓]${NC}"
        fi
        
        if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
            install_marker=" ${DIM}${GREEN}(installed)${NC}"
        fi
        
        if [[ $is_selected -eq 1 ]]; then
            local content_len=$((${#item} + ${#install_marker}))
            local padding=$((MAX_ITEM_WIDTH - content_len))
            
            if [[ $padding -lt 0 ]]; then
                padding=0
            elif [[ $padding -gt 100 ]]; then
                padding=100
            fi
            
            local pad_str=$(printf '%*s' $padding '')
            line_content="    $indicator$checkbox ${REVERSE}$item$install_marker$pad_str${NC}"
        else
            line_content="    $indicator$checkbox $item$install_marker"
        fi
    fi
    
    # Clear to end of line and write content
    printf "%b\033[K" "$line_content"
}

# Function to update scroll indicators
update_scroll_indicators() {
    local scroll_offset=$1
    local terminal_height=$(tput lines)
    
    # Calculate overhead (same as draw_menu)
    local search_lines=$([[ -n "$SEARCH_FILTER" ]] && echo 1 || echo 0)
    local overhead=$([[ "$SHOW_HELP_FOOTER" == true ]] && echo $((19 + search_lines)) || echo $((14 + search_lines)))
    local visible_lines=$((terminal_height - overhead))
    
    # Determine which items we're displaying
    local total_items
    if [[ -n "$SEARCH_FILTER" ]] && [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
        total_items=${#FILTERED_ITEMS[@]}
    else
        total_items=${#ALL_ITEMS[@]}
    fi
    
    local end_idx=$((scroll_offset + visible_lines))
    
    # Base line is where items start (same as draw_single_line)
    local base_line=$((7 + search_lines))
    
    # Line for "more above" indicator
    tput cup $((base_line + visible_lines + 1)) 0
    tput el
    if [[ $scroll_offset -gt 0 ]]; then
        echo -e "${DIM}        ▲ More items above ▲${NC}"
    fi
    
    # Line for "more below" indicator
    tput cup $((base_line + visible_lines + 2)) 0
    tput el
    if [[ $end_idx -lt $total_items ]]; then
        echo -e "${DIM}        ▼ More items below ▼${NC}"
    fi
}

# Function to update the selected count display
update_selected_count() {
    local selected_count=0
    local total_packages=0
    local installed_count=0
    
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            ((total_packages++)) || true
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((selected_count++)) || true
            fi
            if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((installed_count++)) || true
            fi
        fi
    done
    
    # Position cursor at the count line
    # Line 5 if no search, line 6 if search is active
    local count_line=$([[ -n "$SEARCH_FILTER" ]] && echo 6 || echo 5)
    tput cup $count_line 0
    tput el
    echo -e "${DIM}Selected: ${BOLD}$selected_count${NC}${DIM} / $total_packages packages${NC} ${DIM}(${GREEN}$installed_count installed${NC}${DIM})${NC}"
}

# Function to handle live search (updates as you type)
live_search() {
    local search_input=""
    local prev_search=""
    
    # Show search prompt at bottom of screen
    local terminal_height=$(tput lines)
    tput cup $((terminal_height - 1)) 0
    tput el
    echo -ne "${YELLOW}Search:${NC} "
    
    # Show cursor for typing
    tput cnorm
    
    while true; do
        # Read single character
        read -rsn1 char
        
        # Handle special keys
        if [[ $char == $'\x7f' ]] || [[ $char == $'\x08' ]]; then
            # Backspace
            if [[ ${#search_input} -gt 0 ]]; then
                search_input="${search_input:0:-1}"
            fi
        elif [[ $char == $'\x1b' ]]; then
            # Check if it's an escape sequence
            read -rsn2 -t 0.01 rest
            if [[ -z "$rest" ]]; then
                # Pure Esc - cancel search
                SEARCH_FILTER=""
                tput civis
                return 1
            fi
            # Ignore other escape sequences during search
            continue
        elif [[ $char == "" ]]; then
            # Enter key - finish search
            SEARCH_FILTER="$search_input"
            tput civis
            return 0
        elif [[ -n "$char" ]]; then
            # Regular character
            search_input="${search_input}${char}"
        else
            continue
        fi
        
        # Update search only if it changed
        if [[ "$search_input" != "$prev_search" ]]; then
            SEARCH_FILTER="$search_input"
            apply_search_filter
            calculate_max_item_width
            
            # Reset to first item after search change
            selected_index=0
            scroll_offset=0
            
            # Redraw the entire menu
            draw_menu $selected_index $scroll_offset
            
            # Redraw search prompt
            tput cup $((terminal_height - 1)) 0
            tput el
            echo -ne "${YELLOW}Search:${NC} $search_input"
            
            prev_search="$search_input"
        fi
    done
}

# Function to run interactive menu
run_interactive_menu() {
    # Safety check
    if [[ ${#ALL_ITEMS[@]} -eq 0 ]]; then
        echo "ERROR: No items to display!"
        exit 1
    fi
    
    # Initialize filtered items (show all initially)
    apply_search_filter
    
    local selected_index=0
    local scroll_offset=0
    local terminal_height=$(tput lines)
    # Initial overhead (no search filter at start)
    # With footer: 19, without: 14
    local overhead=$([[ "$SHOW_HELP_FOOTER" == true ]] && echo 19 || echo 14)
    local visible_lines=$((terminal_height - overhead))
    
    # Hide cursor
    tput civis
    
    # Trap to restore cursor on exit
    trap 'tput cnorm' INT TERM EXIT
    
    # Check if we have a terminal
    if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]]; then
            exec < /dev/tty
        else
            echo "ERROR: No terminal available for interactive mode!"
            tput cnorm
            exit 1
        fi
    fi
    
    # Initial draw
    draw_menu $selected_index $scroll_offset
    
    local prev_selected_index=$selected_index
    
    while true; do
        # Read single character input
        read -rsn1 key
        
        # Handle empty input - treat as spacebar
        if [[ -z "$key" ]]; then
            key=" "
        fi
        
        # Handle escape sequences
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key
            if [[ -z "$key" ]]; then
                # Pure Esc key - clear search filter
                if [[ -n "$SEARCH_FILTER" ]]; then
                    SEARCH_FILTER=""
                    apply_search_filter
                    calculate_max_item_width
                    selected_index=0
                    scroll_offset=0
                    draw_menu $selected_index $scroll_offset
                fi
                continue
            fi
        fi
        
        # Track changes
        local changed=0
        local full_redraw=0
        
        # Get current total items (filtered or all)
        local total_items
        if [[ -n "$SEARCH_FILTER" ]] && [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
            total_items=${#FILTERED_ITEMS[@]}
        else
            total_items=${#ALL_ITEMS[@]}
        fi
        
        case "$key" in
            '[A'|'k')  # Up arrow or k
                if [[ $selected_index -gt 0 ]]; then
                    prev_selected_index=$selected_index
                    ((selected_index--)) || true
                    
                    if [[ $selected_index -lt $scroll_offset ]]; then
                        ((scroll_offset--)) || true
                        full_redraw=1
                    else
                        local old_screen_line=$((prev_selected_index - scroll_offset))
                        local new_screen_line=$((selected_index - scroll_offset))
                        draw_single_line $prev_selected_index 0 $old_screen_line
                        draw_single_line $selected_index 1 $new_screen_line
                    fi
                    changed=1
                fi
                ;;
            '[B'|'j')  # Down arrow or j
                if [[ $selected_index -lt $((total_items - 1)) ]]; then
                    prev_selected_index=$selected_index
                    ((selected_index++)) || true
                    
                    if [[ $selected_index -ge $((scroll_offset + visible_lines)) ]]; then
                        ((scroll_offset++)) || true
                        full_redraw=1
                    else
                        local old_screen_line=$((prev_selected_index - scroll_offset))
                        local new_screen_line=$((selected_index - scroll_offset))
                        draw_single_line $prev_selected_index 0 $old_screen_line
                        draw_single_line $selected_index 1 $new_screen_line
                    fi
                    changed=1
                fi
                ;;
            ' ')  # Space - toggle selection
                # Get actual item index
                local -a indices_to_use=()
                if [[ -n "$SEARCH_FILTER" ]] && [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
                    indices_to_use=("${FILTERED_ITEMS[@]}")
                else
                    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                        indices_to_use+=("$i")
                    done
                fi
                
                local actual_idx=${indices_to_use[$selected_index]}
                local type="${ITEM_TYPES[$actual_idx]}"
                local category="${ITEM_CATEGORIES[$actual_idx]}"
                local pkg="${ITEM_PACKAGES[$actual_idx]}"
                
                if [[ "$type" == "category" ]]; then
                    # Toggle all packages in category
                    local state=$(get_category_selection_state "$category")
                    local new_state=$([[ $state -eq 1 ]] && echo 0 || echo 1)
                    
                    for ((j=0; j<${#ALL_ITEMS[@]}; j++)); do
                        if [[ "${ITEM_TYPES[$j]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$j]}" == "$category" ]]; then
                            local cat_pkg="${ITEM_PACKAGES[$j]}"
                            SELECTED_PACKAGES[$cat_pkg]=$new_state
                            
                            # Resolve dependencies if selecting
                            if [[ $new_state -eq 1 ]]; then
                                resolve_dependencies "$cat_pkg"
                            fi
                        fi
                    done
                    full_redraw=1
                else
                    # Toggle package
                    if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                        SELECTED_PACKAGES[$pkg]=0
                    else
                        SELECTED_PACKAGES[$pkg]=1
                        resolve_dependencies "$pkg"
                    fi
                    
                    local screen_line=$((selected_index - scroll_offset))
                    draw_single_line $selected_index 1 $screen_line
                fi
                
                update_selected_count
                changed=1
                ;;
            'a')  # Select all
                for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                    if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
                        local pkg="${ITEM_PACKAGES[$i]}"
                        SELECTED_PACKAGES[$pkg]=1
                    fi
                done
                full_redraw=1
                update_selected_count
                ;;
            'n')  # Deselect all
                for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                    if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
                        local pkg="${ITEM_PACKAGES[$i]}"
                        SELECTED_PACKAGES[$pkg]=0
                    fi
                done
                full_redraw=1
                update_selected_count
                ;;
            '/')  # Search
                # Start live search - it will update as user types
                if live_search; then
                    # Search completed (Enter pressed)
                    selected_index=0
                    scroll_offset=0
                    full_redraw=1
                else
                    # Search cancelled (Esc pressed)
                    apply_search_filter
                    calculate_max_item_width
                    selected_index=0
                    scroll_offset=0
                    full_redraw=1
                fi
                ;;
            '?')  # Toggle help footer
                SHOW_HELP_FOOTER=$([[ "$SHOW_HELP_FOOTER" == true ]] && echo false || echo true)
                full_redraw=1
                ;;
            'i')  # Install
                tput cnorm
                return 0
                ;;
            'q')  # Quit
                echo -e "\n\n\n"
                tput cnorm
                print_info "Installation cancelled"
                exit 0
                ;;
        esac
        
        # Redraw if needed
        if [[ $full_redraw -eq 1 ]]; then
            draw_menu $selected_index $scroll_offset
        elif [[ $changed -eq 1 ]]; then
            update_scroll_indicators $scroll_offset
        fi
    done
}

# Function to install selected packages with progress
install_selected_packages() {
    # Count selected packages
    TOTAL_TO_INSTALL=0
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                # Skip if already installed (unless in uninstall mode)
                if [[ "$UNINSTALL_MODE" == true ]] || [[ ${INSTALLED_PACKAGES[$pkg]} -eq 0 ]]; then
                    ((TOTAL_TO_INSTALL++)) || true
                fi
            fi
        fi
    done
    
    if [[ $TOTAL_TO_INSTALL -eq 0 ]]; then
        print_warning "No packages selected or all selected packages are already installed"
        return
    fi
    
    if [[ "$DRY_RUN_MODE" == true ]]; then
        print_header "Dry Run - Packages that would be installed:"
        for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
            if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
                local pkg="${ITEM_PACKAGES[$i]}"
                if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                    if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                        echo -e "  ${DIM}$pkg (already installed, would skip)${NC}"
                    else
                        echo -e "  $pkg"
                    fi
                fi
            fi
        done
        return
    fi
    
    if [[ "$UNINSTALL_MODE" == true ]]; then
        print_header "Uninstalling Packages"
        print_warning "This will remove the selected packages"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Uninstall cancelled"
            return
        fi
    else
        print_header "Installing Packages"
    fi
    
    local current=0
    
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                # Skip SPECIAL_INSTALLS packages - they're handled separately
                if [[ " ${SPECIAL_INSTALLS[@]} " =~ " $pkg " ]]; then
                    continue
                fi
                
                # Skip if already installed (unless uninstalling)
                if [[ "$UNINSTALL_MODE" == false ]] && [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                    ((TOTAL_SKIPPED++)) || true
                    continue
                fi
                
                ((current++)) || true
                
                local progress="[$current/$TOTAL_TO_INSTALL]"
                
                if [[ "$UNINSTALL_MODE" == true ]]; then
                    echo -ne "${progress} Uninstalling ${BOLD}$pkg${NC}... "
                    log_message "Uninstalling: $pkg"
                    
                    if eval "$UNINSTALL_CMD $pkg" >> "$LOG_FILE" 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                        ((TOTAL_INSTALLED_SUCCESS++)) || true
                        log_message "SUCCESS: Uninstalled $pkg"
                    else
                        echo -e "${RED}✗ Failed${NC}"
                        ((TOTAL_INSTALLED_FAILED++)) || true
                        
                        # Capture error
                        local error=$(eval "$UNINSTALL_CMD $pkg" 2>&1 | tail -5)
                        INSTALLATION_ERRORS[$pkg]="$error"
                        log_message "ERROR: Failed to uninstall $pkg"
                        log_message "Error details: $error"
                        
                        if [[ "$CONTINUE_ON_ERROR" == false ]]; then
                            print_error "Installation failed. Check log: $LOG_FILE"
                            return 1
                        fi
                    fi
                else
                    echo -ne "${progress} Installing ${BOLD}$pkg${NC}... "
                    log_message "Installing: $pkg"
                    
                    if eval "$INSTALL_CMD $pkg" >> "$LOG_FILE" 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                        ((TOTAL_INSTALLED_SUCCESS++)) || true
                        log_message "SUCCESS: Installed $pkg"
                    else
                        echo -e "${RED}✗ Failed${NC}"
                        ((TOTAL_INSTALLED_FAILED++)) || true
                        
                        # Capture error
                        local error=$(eval "$INSTALL_CMD $pkg" 2>&1 | tail -5)
                        INSTALLATION_ERRORS[$pkg]="$error"
                        log_message "ERROR: Failed to install $pkg"
                        log_message "Error details: $error"
                        
                        if [[ "$CONTINUE_ON_ERROR" == false ]]; then
                            print_error "Installation failed. Check log: $LOG_FILE"
                            return 1
                        fi
                    fi
                fi
            fi
        fi
    done
    
    # Handle special installs (only if not in uninstall mode)
    if [[ "$UNINSTALL_MODE" == false ]] && [[ ${#SPECIAL_INSTALLS[@]} -gt 0 ]]; then
        for package in "${SPECIAL_INSTALLS[@]}"; do
            if [[ ${SELECTED_PACKAGES[$package]} -eq 1 ]]; then
                case "$package" in
                    "zig")
                        if [[ "$DISTRO" == "ubuntu" ]]; then
                            install_zig_ubuntu
                        elif [[ "$DISTRO" == "rocky" ]]; then
                            install_zig_rocky
                        fi
                        ;;
                    "lazygit")
                        if [[ "$DISTRO" == "ubuntu" ]]; then
                            install_lazygit_ubuntu
                        fi
                        ;;
                esac
            fi
        done
    fi
    
    # Print summary
    print_section "Installation Summary"
    echo -e "${GREEN}✓${NC} Successful: $TOTAL_INSTALLED_SUCCESS"
    
    if [[ $TOTAL_SKIPPED -gt 0 ]]; then
        echo -e "${YELLOW}○${NC} Skipped (already installed): $TOTAL_SKIPPED"
    fi
    
    if [[ $TOTAL_INSTALLED_FAILED -gt 0 ]]; then
        echo -e "${RED}✗${NC} Failed: $TOTAL_INSTALLED_FAILED"
        echo ""
        echo -e "${YELLOW}Failed packages:${NC}"
        for pkg in "${!INSTALLATION_ERRORS[@]}"; do
            echo -e "  ${RED}•${NC} $pkg"
            # Show first line of error
            local error_line=$(echo "${INSTALLATION_ERRORS[$pkg]}" | head -1)
            echo -e "    ${DIM}$error_line${NC}"
        done
        echo ""
        echo -e "${DIM}Full error details in log: $LOG_FILE${NC}"
    fi
    
    log_message "Installation complete: $TOTAL_INSTALLED_SUCCESS success, $TOTAL_INSTALLED_FAILED failed, $TOTAL_SKIPPED skipped"
}

# Function to check for updates
check_for_updates() {
    print_header "Checking for Updates"
    
    local updates_available=0
    local packages_checked=0
    
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            
            # Only check installed packages
            if [[ ${INSTALLED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((packages_checked++)) || true
                
                if has_package_updates "$pkg"; then
                    echo -e "${YELLOW}⟳${NC} Update available: ${BOLD}$pkg${NC}"
                    ((updates_available++)) || true
                fi
            fi
        fi
    done
    
    echo ""
    if [[ $updates_available -eq 0 ]]; then
        print_status "All installed packages are up to date ($packages_checked checked)"
    else
        print_warning "$updates_available package(s) have updates available"
        echo ""
        echo -e "Run ${BOLD}$UPDATE_CMD${NC} to update packages"
    fi
}

# Function to install all packages (non-interactive mode)
install_all_packages() {
    print_header "Installing All Packages"
    
    # Select all packages
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            SELECTED_PACKAGES[$pkg]=1
        fi
    done
    
    install_selected_packages
}

# Verification function
verify_installation() {
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
        echo -e "${YELLOW}⚠  Not running${NC}"
    fi
}

# Print summary
print_summary() {
    print_header "Installation Complete!"
    
    echo -e "\n${YELLOW}Installation Log:${NC} $LOG_FILE"
    
    echo -e "\n${YELLOW}Statistics:${NC}"
    echo -e "• Successful: ${GREEN}$TOTAL_INSTALLED_SUCCESS${NC}"
    if [[ $TOTAL_SKIPPED -gt 0 ]]; then
        echo -e "• Skipped: ${YELLOW}$TOTAL_SKIPPED${NC}"
    fi
    if [[ $TOTAL_INSTALLED_FAILED -gt 0 ]]; then
        echo -e "• Failed: ${RED}$TOTAL_INSTALLED_FAILED${NC}"
    fi
    
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo -e "• Configure Git: ${BLUE}git config --global user.name 'Your Name'${NC}"
    echo -e "• Configure Git: ${BLUE}git config --global user.email 'your@email.com'${NC}"
    
    # Check if Rust and Zig were installed
    if command -v rustc &>/dev/null || command -v cargo &>/dev/null; then
        echo -e "• Verify Rust: ${BLUE}rustc --version && cargo --version${NC}"
    fi
    if command -v zig &>/dev/null; then
        echo -e "• Verify Zig: ${BLUE}zig version${NC}"
    fi
    
    echo -e "• Review log for any errors: ${BLUE}cat $LOG_FILE${NC}"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Detect distribution
detect_distro

# Setup logging
setup_logging

if [[ "$UPDATE_CHECK_MODE" == true ]]; then
    # Update check mode
    define_packages
    populate_package_list
    scan_installed_packages
    check_for_updates
    exit 0
fi

if [[ "$INTERACTIVE_MODE" == true ]]; then
    # Interactive mode (default or uninstall)
    define_packages
    
    if [[ "$UNINSTALL_MODE" == false ]]; then
        print_header "Interactive Installation Mode"
    else
        print_header "Interactive Uninstall Mode"
    fi
    
    print_info "Loading package list..."
    populate_package_list
    
    print_info "Scanning installed packages..."
    scan_installed_packages
    
    calculate_max_item_width
    
    if [[ ${#ALL_ITEMS[@]} -eq 0 ]]; then
        print_error "No items found!"
        exit 1
    fi
    
    run_interactive_menu
    
    # Only set up repositories if installing (not uninstalling)
    if [[ "$UNINSTALL_MODE" == false ]]; then
        echo -e "\n\n\n\n\n"
        setup_repositories
        
        # Update system before installing
        if [[ "$DRY_RUN_MODE" == false ]]; then
            print_section "Updating system packages..."
            eval "$UPDATE_CMD" >> "$LOG_FILE" 2>&1
            print_status "System updated"
        fi
    fi
    
    install_selected_packages
    
    if [[ "$DRY_RUN_MODE" == false ]] && [[ "$UNINSTALL_MODE" == false ]]; then
        verify_installation
    fi
    
    print_summary
else
    # Non-interactive mode (--all flag)
    setup_repositories
    define_packages
    populate_package_list
    scan_installed_packages
    
    # Update system
    print_section "Updating system packages..."
    eval "$UPDATE_CMD" >> "$LOG_FILE" 2>&1
    print_status "System updated"
    
    install_all_packages
    verify_installation
    print_summary
fi

print_info "All operations complete. Log saved to: $LOG_FILE"