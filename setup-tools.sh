#!/bin/bash
# <michael@mattsson.net>
# Cross-platform script to install common developer tools
# Supports: Rocky Linux, Arch Linux, Ubuntu/Debian
# Usage: sudo ./setup-tools.sh [--all|-a]

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
SERVICE_MANAGER="systemctl"
INTERACTIVE_MODE=true
MAX_ITEM_WIDTH=40  # Default value, will be calculated later

# Arrays to track selected packages
declare -A SELECTED_PACKAGES
declare -a ALL_ITEMS              # All items (both categories and packages)
declare -a ITEM_TYPES             # Type: "category" or "package"
declare -a ITEM_CATEGORIES        # Category name for packages, or self for categories
declare -a ITEM_PACKAGES          # Package name (empty for categories)
declare -a ITEM_DESCRIPTIONS      # Descriptions

# Function to calculate maximum item width for padding
calculate_max_item_width() {
    local max_width=0
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        local item="${ALL_ITEMS[$i]}"
        local type="${ITEM_TYPES[$i]}"
        local desc="${ITEM_DESCRIPTIONS[$i]}"
        
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
for arg in "$@"; do
    case $arg in
        --all|-a)
            INTERACTIVE_MODE=false
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, -a           Install all packages without interactive selection"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Default behavior: Interactive mode with package selection"
            echo ""
            echo "Interactive Mode Controls:"
            echo "  ↑/↓ or k/j          Navigate up/down"
            echo "  Space               Toggle package selection"
            echo "  a                   Select all packages"
            echo "  n                   Deselect all packages"
            echo "  i                   Install selected packages"
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

# Function to define packages for each distribution
define_packages() {
    case "$DISTRO" in
        "rocky")
            DEV_TOOLS=(
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
            DEV_TOOLS=(
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
            DEV_TOOLS=(
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
    ALL_ITEMS+=("$name")
    ITEM_TYPES+=("package")
    ITEM_CATEGORIES+=("$category")
    ITEM_PACKAGES+=("$name")
    ITEM_DESCRIPTIONS+=("")
    
    # Initialize package as unselected
    SELECTED_PACKAGES[$name]=0
}

# Function to populate package list
populate_package_list() {
    # Development Tools
    add_category "Development Tools" "Core build tools"
    for pkg in "${DEV_TOOLS[@]}"; do
        add_package "$pkg" "Development Tools"
    done
    
    # Programming Languages
    if [[ ${#LANG_TOOLS[@]} -gt 0 ]]; then
        add_category "Programming Languages" "Rust, Zig, etc."
        for pkg in "${LANG_TOOLS[@]}"; do
            add_package "$pkg" "Programming Languages"
        done
    fi
    
    # Version Control
    add_category "Version Control" "Git, SVN, etc."
    for pkg in "${VCS_TOOLS[@]}"; do
        add_package "$pkg" "Version Control"
    done
    
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
    if [[ ${#EXTRA_TOOLS[@]} -gt 0 ]]; then
        add_category "Extra Tools" "Optional enhancements"
        for pkg in "${EXTRA_TOOLS[@]}"; do
            add_package "$pkg" "Extra Tools"
        done
    fi
    
    # Special Installs
    if [[ ${#SPECIAL_INSTALLS[@]} -gt 0 ]]; then
        add_category "Special Installs" "From source/releases"
        for pkg in "${SPECIAL_INSTALLS[@]}"; do
            add_package "$pkg" "Special Installs"
        done
    fi
    
    # Network Services
    add_category "Network Services" "SSH server"
    add_package "$SSH_PACKAGE" "Network Services"
}

# Function to draw the interactive menu
draw_menu() {
    local selected_index=$1
    local scroll_offset=$2
    local terminal_height=$(tput lines)
    # Header: 7 lines, Scroll indicators: 3 lines, Footer: 5 lines, Blank before footer: 1 line, Buffer: 1 line = 17 total overhead
    local visible_lines=$((terminal_height - 17))
    
    # Move cursor to top instead of clearing screen (prevents flicker)
    tput cup 0 0
    
    # Clear from cursor to end of screen
    tput ed
    
    # Box width (inner content should be 68 chars)
    local box_width=68
    
    # Header
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    
    # Line 1: Title (centered)
    local title="Developer Tools Installation - Interactive Mode"
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
    
    # Count selected packages (not categories)
    local selected_count=0
    local total_packages=0
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            ((total_packages++)) || true
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((selected_count++)) || true
            fi
        fi
    done
    
    echo -e "${DIM}Selected: ${BOLD}$selected_count${NC}${DIM} / $total_packages packages${NC}"
    echo ""
    
    # Display items
    local start_idx=$scroll_offset
    local end_idx=$((scroll_offset + visible_lines))
    
    if [[ $end_idx -gt ${#ALL_ITEMS[@]} ]]; then
        end_idx=${#ALL_ITEMS[@]}
    fi
    
    for ((i=start_idx; i<end_idx; i++)); do
        local item="${ALL_ITEMS[$i]}"
        local type="${ITEM_TYPES[$i]}"
        local category="${ITEM_CATEGORIES[$i]}"
        local pkg="${ITEM_PACKAGES[$i]}"
        local desc="${ITEM_DESCRIPTIONS[$i]}"
        
        local indicator="  "
        if [[ $i -eq $selected_index ]]; then
            indicator="▶ "
        fi
        
        if [[ "$type" == "category" ]]; then
            # Category header - check if all packages in this category are selected
            local all_selected=1
            local has_packages=0
            for ((j=0; j<${#ALL_ITEMS[@]}; j++)); do
                if [[ "${ITEM_TYPES[$j]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$j]}" == "$category" ]]; then
                    has_packages=1
                    local cat_pkg="${ITEM_PACKAGES[$j]}"
                    if [[ ${SELECTED_PACKAGES[$cat_pkg]} -eq 0 ]]; then
                        all_selected=0
                        break
                    fi
                fi
            done
            
            local checkbox="[ ]"
            if [[ $has_packages -eq 1 ]] && [[ $all_selected -eq 1 ]]; then
                checkbox="${GREEN}[✓]${NC}"
            fi
            
            # Highlight selected line
            if [[ $i -eq $selected_index ]]; then
                # Calculate padding for inverted bar - with bounds checking
                local content_len=$((${#item} + 1 + ${#desc}))
                local padding=$((MAX_ITEM_WIDTH - content_len))
                
                # Ensure padding is reasonable (0 to 100 characters)
                if [[ $padding -lt 0 ]]; then
                    padding=0
                elif [[ $padding -gt 100 ]]; then
                    padding=100
                fi
                
                local pad_str=$(printf '%*s' $padding '')
                
                # Use simpler formatting when selected to avoid color code conflicts
                echo -e "$indicator$checkbox ${REVERSE}$item $desc$pad_str${NC}"
            else
                echo -e "$indicator$checkbox ${BOLD}${CYAN}$item${NC} ${DIM}$desc${NC}"
            fi
        else
            # Package item
            local checkbox="[ ]"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                checkbox="${GREEN}[✓]${NC}"
            fi
            
            # Highlight selected line
            if [[ $i -eq $selected_index ]]; then
                # Calculate padding for inverted bar - with bounds checking
                local content_len=${#item}
                local padding=$((MAX_ITEM_WIDTH - content_len))
                
                # Ensure padding is reasonable (0 to 100 characters)
                if [[ $padding -lt 0 ]]; then
                    padding=0
                elif [[ $padding -gt 100 ]]; then
                    padding=100
                fi
                
                local pad_str=$(printf '%*s' $padding '')
                
                echo -e "    $indicator$checkbox ${REVERSE}$item$pad_str${NC}"
            else
                echo -e "    $indicator$checkbox $item"
            fi
        fi
    done
    
    # Clear any remaining lines in the display area
    local lines_drawn=$((end_idx - start_idx))
    local lines_to_clear=$((visible_lines - lines_drawn))
    for ((i=0; i<lines_to_clear; i++)); do
        echo ""
    done
    
    # Show scroll indicators - always use exactly 2 lines
    if [[ $scroll_offset -gt 0 ]]; then
        echo ""
        echo -e "${DIM}        ▲ More items above ▲${NC}"
    else
        echo ""
        echo ""
    fi
    
    if [[ $end_idx -lt ${#ALL_ITEMS[@]} ]]; then
        echo -e "${DIM}        ▼ More items below ▼${NC}"
    else
        echo ""
    fi
    
    # Footer with controls
    echo ""
    echo -e "${BOLD}${BLUE}────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}Controls:${NC} ${DIM}[↑/↓ or k/j]${NC} Navigate  ${DIM}[Space]${NC} Toggle  ${DIM}[a]${NC} Select All  ${DIM}[n]${NC} Deselect All"
    echo -e "          ${DIM}[i]${NC} ${GREEN}Install Selected${NC}  ${DIM}[q]${NC} Quit"
    echo -e "${BOLD}${BLUE}────────────────────────────────────────────────────────────────────${NC}"
}

# Function to draw a single menu line (for efficient updates)
draw_single_line() {
    local index=$1
    local is_selected=$2
    local screen_line=$3  # Which line on screen (0-based from start of items area)
    
    local item="${ALL_ITEMS[$index]}"
    local type="${ITEM_TYPES[$index]}"
    local category="${ITEM_CATEGORIES[$index]}"
    local pkg="${ITEM_PACKAGES[$index]}"
    local desc="${ITEM_DESCRIPTIONS[$index]}"
    
    # Position cursor at the correct screen line (7 lines for header + screen_line)
    tput cup $((7 + screen_line)) 0
    
    # Build the line content
    local line_content=""
    local indicator="  "
    
    if [[ $is_selected -eq 1 ]]; then
        indicator="▶ "
    fi
    
    if [[ "$type" == "category" ]]; then
        # Category header - check if all packages in this category are selected
        local all_selected=1
        local has_packages=0
        for ((j=0; j<${#ALL_ITEMS[@]}; j++)); do
            if [[ "${ITEM_TYPES[$j]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$j]}" == "$category" ]]; then
                has_packages=1
                local cat_pkg="${ITEM_PACKAGES[$j]}"
                if [[ ${SELECTED_PACKAGES[$cat_pkg]} -eq 0 ]]; then
                    all_selected=0
                    break
                fi
            fi
        done
        
        local checkbox="[ ]"
        if [[ $has_packages -eq 1 ]] && [[ $all_selected -eq 1 ]]; then
            checkbox="${GREEN}[✓]${NC}"
        fi
        
        # Build line with or without highlight
        if [[ $is_selected -eq 1 ]]; then
            # Calculate padding for inverted bar - with bounds checking
            local content_len=$((${#item} + 1 + ${#desc}))
            local padding=$((MAX_ITEM_WIDTH - content_len))
            
            # Ensure padding is reasonable (0 to 100 characters)
            if [[ $padding -lt 0 ]]; then
                padding=0
            elif [[ $padding -gt 100 ]]; then
                padding=100
            fi
            
            local pad_str=$(printf '%*s' $padding '')
            
            # Use simpler formatting when selected to avoid color code conflicts
            line_content="$indicator$checkbox ${REVERSE}$item $desc$pad_str${NC}"
        else
            line_content="$indicator$checkbox ${BOLD}${CYAN}$item${NC} ${DIM}$desc${NC}"
        fi
    else
        # Package item
        local checkbox="[ ]"
        if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
            checkbox="${GREEN}[✓]${NC}"
        fi
        
        # Build line with or without highlight
        if [[ $is_selected -eq 1 ]]; then
            # Calculate padding for inverted bar - with bounds checking
            local content_len=${#item}
            local padding=$((MAX_ITEM_WIDTH - content_len))
            
            # Ensure padding is reasonable (0 to 100 characters)
            if [[ $padding -lt 0 ]]; then
                padding=0
            elif [[ $padding -gt 100 ]]; then
                padding=100
            fi
            
            local pad_str=$(printf '%*s' $padding '')
            
            line_content="    $indicator$checkbox ${REVERSE}$item$pad_str${NC}"
        else
            line_content="    $indicator$checkbox $item"
        fi
    fi
    
    # Clear to end of line and write content in one operation
    printf "%b\033[K" "$line_content"
}

# Function to update scroll indicators
update_scroll_indicators() {
    local scroll_offset=$1
    local terminal_height=$(tput lines)
    local visible_lines=$((terminal_height - 17))
    local end_idx=$((scroll_offset + visible_lines))
    
    # Line for "more above" indicator (after visible items + cleared space)
    tput cup $((7 + visible_lines + 1)) 0
    tput el
    if [[ $scroll_offset -gt 0 ]]; then
        echo -e "${DIM}        ▲ More items above ▲${NC}"
    fi
    
    # Line for "more below" indicator
    tput cup $((7 + visible_lines + 2)) 0
    tput el
    if [[ $end_idx -lt ${#ALL_ITEMS[@]} ]]; then
        echo -e "${DIM}        ▼ More items below ▼${NC}"
    fi
}

# Function to update the selected count display
update_selected_count() {
    local selected_count=0
    local total_packages=0
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            ((total_packages++)) || true
            local pkg="${ITEM_PACKAGES[$i]}"
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                ((selected_count++)) || true
            fi
        fi
    done
    
    # Position cursor at line 5 (where the count is)
    tput cup 5 0
    tput el
    echo -e "${DIM}Selected: ${BOLD}$selected_count${NC}${DIM} / $total_packages packages${NC}"
}

# Function to run interactive menu
run_interactive_menu() {
    # Safety check
    if [[ ${#ALL_ITEMS[@]} -eq 0 ]]; then
        echo "ERROR: No items to display!"
        exit 1
    fi
    
    local selected_index=0
    local scroll_offset=0
    local terminal_height=$(tput lines)
    # Header: 7 lines, Scroll indicators: 3 lines, Footer: 5 lines, Blank before footer: 1 line, Buffer: 1 line = 17 total overhead
    local visible_lines=$((terminal_height - 17))
    
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
            echo "Make sure you're running this script from a terminal, not via pipe or redirect."
            tput cnorm
            exit 1
        fi
    fi
    
    # Initial draw
    draw_menu $selected_index $scroll_offset
    
    # Track previous selected index
    local prev_selected_index=$selected_index
    
    while true; do
        # Read single character input
        read -rsn1 key
        
        # Handle empty input - treat as spacebar
        if [[ -z "$key" ]]; then
            key=" "
        fi
        
        # Handle escape sequences for arrow keys
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
        fi
        
        # Track if we made a change that needs redrawing
        local changed=0
        local full_redraw=0
        
        case "$key" in
            '[A'|'k')  # Up arrow or k
                if [[ $selected_index -gt 0 ]]; then
                    prev_selected_index=$selected_index
                    ((selected_index--)) || true
                    
                    # Check if we need to scroll
                    if [[ $selected_index -lt $scroll_offset ]]; then
                        # Need to scroll up
                        ((scroll_offset--)) || true
                        
                        # Redraw all visible lines
                        local start_idx=$scroll_offset
                        local end_idx=$((scroll_offset + visible_lines))
                        if [[ $end_idx -gt ${#ALL_ITEMS[@]} ]]; then
                            end_idx=${#ALL_ITEMS[@]}
                        fi
                        
                        for ((i=start_idx; i<end_idx; i++)); do
                            local screen_line=$((i - scroll_offset))
                            local is_selected=0
                            if [[ $i -eq $selected_index ]]; then
                                is_selected=1
                            fi
                            draw_single_line $i $is_selected $screen_line
                        done
                        
                        # Update scroll indicators
                        update_scroll_indicators $scroll_offset
                    else
                        # Just redraw the two affected lines
                        local old_screen_line=$((prev_selected_index - scroll_offset))
                        local new_screen_line=$((selected_index - scroll_offset))
                        draw_single_line $prev_selected_index 0 $old_screen_line
                        draw_single_line $selected_index 1 $new_screen_line
                    fi
                    changed=1
                fi
                ;;
            '[B'|'j')  # Down arrow or j
                if [[ $selected_index -lt $((${#ALL_ITEMS[@]} - 1)) ]]; then
                    prev_selected_index=$selected_index
                    ((selected_index++)) || true
                    
                    # Check if we need to scroll
                    if [[ $selected_index -ge $((scroll_offset + visible_lines)) ]]; then
                        # Need to scroll down
                        ((scroll_offset++)) || true
                        
                        # Redraw all visible lines
                        local start_idx=$scroll_offset
                        local end_idx=$((scroll_offset + visible_lines))
                        if [[ $end_idx -gt ${#ALL_ITEMS[@]} ]]; then
                            end_idx=${#ALL_ITEMS[@]}
                        fi
                        
                        for ((i=start_idx; i<end_idx; i++)); do
                            local screen_line=$((i - scroll_offset))
                            local is_selected=0
                            if [[ $i -eq $selected_index ]]; then
                                is_selected=1
                            fi
                            draw_single_line $i $is_selected $screen_line
                        done
                        
                        # Update scroll indicators
                        update_scroll_indicators $scroll_offset
                    else
                        # Just redraw the two affected lines
                        local old_screen_line=$((prev_selected_index - scroll_offset))
                        local new_screen_line=$((selected_index - scroll_offset))
                        draw_single_line $prev_selected_index 0 $old_screen_line
                        draw_single_line $selected_index 1 $new_screen_line
                    fi
                    changed=1
                fi
                ;;
            ' '|$'\x20'|$'\040')  # Spacebar - toggle selection
                local item_type="${ITEM_TYPES[$selected_index]}"
                
                if [[ "$item_type" == "category" ]]; then
                    # Toggle all packages in this category
                    local category="${ITEM_CATEGORIES[$selected_index]}"
                    
                    # First check if all are selected to determine toggle direction
                    local all_selected=1
                    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                        if [[ "${ITEM_TYPES[$i]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$i]}" == "$category" ]]; then
                            local pkg="${ITEM_PACKAGES[$i]}"
                            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 0 ]]; then
                                all_selected=0
                                break
                            fi
                        fi
                    done
                    
                    # Toggle all packages in category
                    local new_state=0
                    if [[ $all_selected -eq 1 ]]; then
                        new_state=0  # Deselect all
                    else
                        new_state=1  # Select all
                    fi
                    
                    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                        if [[ "${ITEM_TYPES[$i]}" == "package" ]] && [[ "${ITEM_CATEGORIES[$i]}" == "$category" ]]; then
                            local pkg="${ITEM_PACKAGES[$i]}"
                            SELECTED_PACKAGES[$pkg]=$new_state
                        fi
                    done
                    
                    full_redraw=1  # Need to redraw all visible items
                else
                    # Toggle individual package
                    local pkg="${ITEM_PACKAGES[$selected_index]}"
                    if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                        SELECTED_PACKAGES[$pkg]=0
                    else
                        SELECTED_PACKAGES[$pkg]=1
                    fi
                    
                    # Just redraw this line and update count
                    local screen_line=$((selected_index - scroll_offset))
                    draw_single_line $selected_index 1 $screen_line
                    update_selected_count
                fi
                changed=1
                ;;
            'a'|'A')  # Select all
                for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                    if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
                        local pkg="${ITEM_PACKAGES[$i]}"
                        SELECTED_PACKAGES[$pkg]=1
                    fi
                done
                full_redraw=1
                changed=1
                ;;
            'n'|'N')  # Deselect all
                for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
                    if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
                        local pkg="${ITEM_PACKAGES[$i]}"
                        SELECTED_PACKAGES[$pkg]=0
                    fi
                done
                full_redraw=1
                changed=1
                ;;
            'i'|'I')  # Install
                tput cnorm  # Restore cursor
                clear
                return 0  # Proceed with installation
                ;;
            'q'|'Q')  # Quit
                tput cnorm  # Restore cursor
                clear
                echo -e "${YELLOW}Installation cancelled.${NC}"
                exit 0
                ;;
        esac
        
        # Only redraw if something changed
        if [[ $changed -eq 1 ]] && [[ $full_redraw -eq 1 ]]; then
            draw_menu $selected_index $scroll_offset
        fi
    done
}

# Function to install selected packages from interactive mode
install_selected_packages() {
    print_header "Installing Selected Packages"
    
    # Group selected packages by category
    declare -A category_map
    
    for ((i=0; i<${#ALL_ITEMS[@]}; i++)); do
        if [[ "${ITEM_TYPES[$i]}" == "package" ]]; then
            local pkg="${ITEM_PACKAGES[$i]}"
            local cat="${ITEM_CATEGORIES[$i]}"
            
            if [[ ${SELECTED_PACKAGES[$pkg]} -eq 1 ]]; then
                if [[ -z "${category_map[$cat]}" ]]; then
                    category_map[$cat]="$pkg"
                else
                    category_map[$cat]="${category_map[$cat]} $pkg"
                fi
            fi
        fi
    done
    
    # Install packages by category (exclude special installs)
    for category in "${!category_map[@]}"; do
        if [[ "$category" == "Special Installs" ]]; then
            continue  # Skip special installs for now
        fi
        
        print_section "Installing $category..."
        for pkg in ${category_map[$category]}; do
            echo -n "Installing $pkg... "
            if eval "$INSTALL_CMD $pkg" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗ Failed${NC}"
            fi
        done
    done
    
    # Handle special installs if selected
    if [[ -n "${category_map["Special Installs"]}" ]]; then
        for package in ${category_map["Special Installs"]}; do
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
        done
    fi
    
    # Install and configure SSH if selected
    if [[ -n "${category_map["Network Services"]}" ]]; then
        print_section "Setting up SSH Server..."
        if systemctl enable sshd &>/dev/null || systemctl enable ssh &>/dev/null; then
            print_status "SSH service enabled for startup"
        fi
        
        if systemctl start sshd &>/dev/null || systemctl start ssh &>/dev/null; then
            print_status "SSH service started"
        else
            print_error "Failed to start SSH service"
        fi
    fi
}

# Function to install all packages (non-interactive mode)
install_all_packages() {
    print_header "Installing All Packages"
    
    # Update system
    print_section "Updating system packages..."
    eval "$UPDATE_CMD" &>/dev/null
    print_status "System updated"
    
    # Install core development tools
    install_packages "Development Tools" DEV_TOOLS
    
    # Install language tools if available
    if [[ ${#LANG_TOOLS[@]} -gt 0 ]]; then
        install_packages "Programming Languages" LANG_TOOLS
    fi
    
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
            echo -e "${YELLOW}⚠  Skipped${NC}"
        fi
    done
    
    # Handle special installs
    if [[ ${#SPECIAL_INSTALLS[@]} -gt 0 ]]; then
        for package in "${SPECIAL_INSTALLS[@]}"; do
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
        done
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
    
    echo -e "\n${YELLOW}Installed Categories:${NC}"
    echo -e "• ${CYAN}Development Tools:${NC} gcc, gdb, cmake, make, ninja-build"
    
    # Check if Rust and Zig were installed
    local has_rust=false
    local has_zig=false
    if command -v rustc &>/dev/null || command -v cargo &>/dev/null; then
        has_rust=true
    fi
    if command -v zig &>/dev/null; then
        has_zig=true
    fi
    
    if [[ "$has_rust" == true ]] || [[ "$has_zig" == true ]]; then
        local langs=""
        [[ "$has_rust" == true ]] && langs="rust, cargo"
        [[ "$has_zig" == true ]] && langs="${langs:+$langs, }zig"
        echo -e "• ${CYAN}Programming Languages:${NC} $langs"
    fi
    
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
    if [[ "$has_rust" == true ]]; then
        echo -e "• Verify Rust: ${BLUE}rustc --version && cargo --version${NC}"
    fi
    if [[ "$has_zig" == true ]]; then
        echo -e "• Verify Zig: ${BLUE}zig version${NC}"
    fi
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
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Detect distribution
detect_distro

if [[ "$INTERACTIVE_MODE" == true ]]; then
    # Interactive mode (default)
    # Skip repository setup until after selection to show menu quickly
    
    # Define packages for detected distribution
    define_packages
    
    print_header "Interactive Installation Mode"
    print_info "Loading package list..."
    
    populate_package_list
    
    # Calculate maximum item width for padding
    calculate_max_item_width
    
    # Check if items were loaded
    if [[ ${#ALL_ITEMS[@]} -eq 0 ]]; then
        print_error "No items found! This is a bug."
        print_info "Please report this issue."
        exit 1
    fi
    
    run_interactive_menu
    
    # Now set up repositories before installing
    setup_repositories
    
    # Update system before installing selected packages
    print_section "Updating system packages..."
    eval "$UPDATE_CMD" &>/dev/null
    print_status "System updated"
    
    install_selected_packages
    verify_installation
    print_summary
else
    # Non-interactive mode (--all flag) - install everything
    # Set up repositories first
    setup_repositories
    
    # Define packages for detected distribution
    define_packages
    
    install_all_packages
    verify_installation
    print_summary
fi