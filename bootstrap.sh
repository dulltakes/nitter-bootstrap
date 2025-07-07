#!/bin/bash


set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Configuration
NITTER_REPO="https://github.com/zedeus/nitter"
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/zedeus/nitter/refs/heads/master/docker-compose.yml"
NITTER_CONF_URL="https://raw.githubusercontent.com/zedeus/nitter/refs/heads/master/nitter.example.conf"
WORK_DIR="$(pwd)"
NITTER_DIR="nitter"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo "${RED}[ERROR]${NC} $1"
}

# Check if required commands exist
check_dependencies() {
    local missing_deps=()

    for cmd in curl git docker python3 pip; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install them before running this script"
        exit 1
    fi
}

# Detect architecture for Docker image
detect_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "zedeus/nitter:latest"
            ;;
        arm64|aarch64)
            echo "zedeus/nitter:latest-arm64"
            ;;
        *)
            log_warn "Unknown architecture: $arch, defaulting to x86_64 image"
            echo "zedeus/nitter:latest"
            ;;
    esac
}

# Download and configure docker-compose.yml
setup_docker_compose() {
    log_info "Setting up Docker Compose configuration..."

    local nitter_image
    nitter_image=$(detect_architecture)

    if ! curl -fsSL "$DOCKER_COMPOSE_URL" | sed "s|zedeus/nitter:latest|$nitter_image|g" > docker-compose.yml; then
        log_error "Failed to download docker-compose.yml"
        exit 1
    fi

    log_info "Docker Compose configuration created with image: $nitter_image"
}

# Download and configure nitter.conf
setup_nitter_config() {
    log_info "Setting up Nitter configuration..."

    if ! curl -fsSL "$NITTER_CONF_URL" | sed 's/redisHost = "localhost"/redisHost = "nitter-redis"/' > nitter.conf; then
        log_error "Failed to download nitter.conf"
        exit 1
    fi

    log_info "Nitter configuration created"
}

# Clone or update Nitter repository
setup_nitter_repo() {
    if [ -d "$NITTER_DIR" ]; then
        if [ "$(ls -A "$NITTER_DIR" 2>/dev/null)" ]; then
            log_info "Directory '$NITTER_DIR' exists and is not empty, skipping clone"
            return 0
        else
            log_info "Directory '$NITTER_DIR' exists but is empty, removing and cloning"
            rm -rf "$NITTER_DIR"
        fi
    fi

    log_info "Cloning Nitter repository..."
    if ! git clone "$NITTER_REPO" "$NITTER_DIR"; then
        log_error "Failed to clone Nitter repository"
        exit 1
    fi
}

# Validate environment variables
validate_env_vars() {
    local missing_vars=()

    if [ -z "${TWITTER_ACCOUNT_NAME:-}" ]; then
        missing_vars+=("TWITTER_ACCOUNT_NAME")
    fi

    if [ -z "${TWITTER_ACCOUNT_PASSWORD:-}" ]; then
        missing_vars+=("TWITTER_ACCOUNT_PASSWORD")
    fi

    if [ -z "${TWITTER_AUTH_BASE64:-}" ]; then
        missing_vars+=("TWITTER_AUTH_BASE64")
    fi

    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        log_error "Please set these variables before running the script:"
        for var in "${missing_vars[@]}"; do
            echo "  export $var='your_value'"
        done
        exit 1
    fi
}

# Setup Twitter sessions
setup_twitter_sessions() {
    log_info "Setting up Twitter sessions..."

    local tools_dir="$NITTER_DIR/tools"

    if [ ! -d "$tools_dir" ]; then
        log_error "Tools directory not found: $tools_dir"
        exit 1
    fi

    # Change to tools directory
    if ! pushd "$tools_dir" > /dev/null; then
        log_error "Failed to change to tools directory"
        exit 1
    fi

    # Install Python dependencies
    log_info "Installing Python dependencies..."
    if ! pip install pyotp requests; then
        log_error "Failed to install Python dependencies"
        popd > /dev/null || true
        exit 1
    fi

    # Generate sessions
    log_info "Generating Twitter sessions..."
    if ! python3 get_session.py "$TWITTER_ACCOUNT_NAME" "$TWITTER_ACCOUNT_PASSWORD" "$TWITTER_AUTH_BASE64" ../sessions.jsonl; then
        log_error "Failed to generate Twitter sessions"
        popd > /dev/null || true
        exit 1
    fi

    # Return to original directory
    popd > /dev/null || exit 1

    # Copy sessions file to work directory
    if [ -f "$NITTER_DIR/sessions.jsonl" ]; then
        if ! cp "$NITTER_DIR/sessions.jsonl" "$WORK_DIR/"; then
            log_error "Failed to copy sessions.jsonl to work directory"
            exit 1
        fi
        log_info "Sessions file copied successfully"
    else
        log_error "Sessions file not found: $NITTER_DIR/sessions.jsonl"
        exit 1
    fi
}

# Verify final setup
verify_setup() {
    log_info "Verifying setup..."

    local required_files=("docker-compose.yml" "nitter.conf" "sessions.jsonl")
    local missing_files=()

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            missing_files+=("$file")
        fi
    done

    if [ ${#missing_files[@]} -ne 0 ]; then
        log_error "Missing required files: ${missing_files[*]}"
        exit 1
    fi

    log_info "All required files are present"
}

setup_ntscraper() {
  log_info "Installing ntscraper"
  pip install ntscraper
  cat > "$WORK_DIR/scrape.py" <<EOF
from ntscraper import Nitter

scraper = Nitter(log_level=1, skip_instance_check=False, instances="http://0.0.0.0:8080/")

# Example usage
tweet = scraper.get_tweet_by_id("x", "1935807158379073823")
print(tweet)
EOF
log_info "Boilerplate scrape.py file created"
log_info "To use the scraper, run ${GREEN}python scrape.py${NC}"
}

# Cleanup function
cleanup() {
    if [ -d "$NITTER_DIR" ]; then
        log_info "Cleaning up temporary Nitter directory..."
        rm -rf "$NITTER_DIR"
    fi
}

# Main execution
main() {
    log_info "Starting Nitter bootstrap process..."

    # Check dependencies
    check_dependencies

    # Validate environment variables
    validate_env_vars

    # Setup Docker Compose
    setup_docker_compose

    # Setup Nitter configuration
    setup_nitter_config

    # Setup Nitter repository
    setup_nitter_repo

    # Setup Twitter sessions
    setup_twitter_sessions

    # Setup ntscraper
    setup_ntscraper

    # Cleanup temporary files
    cleanup

    # Verify final setup
    verify_setup

    log_info "Bootstrap completed successfully!"
    log_info "To start Nitter, run: ${GREEN}docker compose up -d${NC}"
}

# Handle script interruption
trap cleanup EXIT

# Run main function
main "$@"
