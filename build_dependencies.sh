echo "=========================================="
echo "Gonerino Build Dependencies Setup Script"
echo "=========================================="
echo ""

echo "[Step 1/5] Installing Homebrew..."
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

echo ""
echo "[Step 2/5] Configuring Homebrew..."
if [ -f "/opt/homebrew/bin/brew" ]; then
    BREW_PATH="/opt/homebrew/bin/brew"
    echo "   Detected Apple Silicon Homebrew installation"
elif [ -f "/usr/local/bin/brew" ]; then
    BREW_PATH="/usr/local/bin/brew"
    echo "   Detected Intel Homebrew installation"
else
    BREW_PATH=$(which brew)
    if [ -z "$BREW_PATH" ]; then
        echo "Error: Could not find Homebrew installation"
        exit 1
    fi
    echo "   Found Homebrew in PATH: $BREW_PATH"
fi

if [ -f "$HOME/.zprofile" ]; then
    PROFILE="$HOME/.zprofile"
elif [ -f "$HOME/.zshrc" ]; then
    PROFILE="$HOME/.zshrc"
elif [ -f "$HOME/.bash_profile" ]; then
    PROFILE="$HOME/.bash_profile"
else
    PROFILE="$HOME/.zprofile"
fi
echo "   Using shell profile: $PROFILE"

echo >> "$PROFILE"
echo "eval \"\$($BREW_PATH shellenv)\"" >> "$PROFILE"
eval "$($BREW_PATH shellenv)"
echo "   Homebrew version: $(brew --version | head -n1)"

echo ""
echo "[Step 3/5] Installing build tools (make, ldid)..."
brew install make ldid

echo 'export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"' >> "$PROFILE"
source "$PROFILE"

echo ""
echo "[Step 4/5] Setting up Theos..."
THEOS_DIR="$HOME/theos"
echo "   Creating Theos directory: $THEOS_DIR"
mkdir -p "$THEOS_DIR"
cd "$THEOS_DIR"
echo "   Cloning Theos repository (this may take a moment)..."
git clone --recursive https://github.com/theos/theos.git .
echo "export THEOS=\"$THEOS_DIR\"" >> "$PROFILE"
echo 'export PATH=$THEOS/bin:$PATH' >> "$PROFILE"
export THEOS="$THEOS_DIR"
echo "   Theos installed at: $THEOS"

echo ""
echo "[Step 5/5] Downloading iOS SDKs..."
cd "$THEOS_DIR"
rm -rf sdks
mkdir -p sdks

echo "   [1/3] iPhoneOS16.5.sdk (theos/sdks)..."
(
    tmp=$(mktemp -d)
    cd "$tmp"
    git clone --quiet -n --depth=1 --filter=tree:0 https://github.com/theos/sdks/
    cd sdks
    git sparse-checkout set --no-cone iPhoneOS16.5.sdk
    git checkout
    mv *.sdk "$THEOS_DIR/sdks/"
    rm -rf "$tmp"
)

echo "   [2/3] iPhoneOS17.5.sdk (Tonwalter888/iOS-SDKs)..."
(
    tmp=$(mktemp -d)
    cd "$tmp"
    git clone --quiet --no-tags --single-branch --depth=1 -n --filter=tree:0 https://github.com/Tonwalter888/iOS-SDKs
    cd iOS-SDKs
    git sparse-checkout set --no-cone iPhoneOS17.5.sdk
    git checkout
    mv *.sdk "$THEOS_DIR/sdks/"
    rm -rf "$tmp"
)

echo "   [3/3] iPhoneOS18.6.sdk (Tonwalter888/iOS-SDKs)..."
(
    tmp=$(mktemp -d)
    cd "$tmp"
    git clone --quiet --no-tags --single-branch --depth=1 -n --filter=tree:0 https://github.com/Tonwalter888/iOS-SDKs
    cd iOS-SDKs
    git sparse-checkout set --no-cone iPhoneOS18.6.sdk
    git checkout
    mv *.sdk "$THEOS_DIR/sdks/"
    rm -rf "$tmp"
)
echo "   Done! Installed $(ls "$THEOS_DIR/sdks/" | wc -l | xargs) SDK(s)"

echo ""
echo "Cloning YouTubeHeader..."
mkdir -p "$THEOS/include"
if [ -d "$THEOS/include/YouTubeHeader" ]; then
    echo "   YouTubeHeader exists. Pulling latest changes..."
    cd "$THEOS/include/YouTubeHeader"
    git pull --quiet
else
    echo "   Cloning YouTubeHeader..."
    cd "$THEOS/include"
    git clone --quiet --depth=1 https://github.com/PoomSmart/YouTubeHeader.git
fi

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo "Run 'make package FINALPACKAGE=1' from the repo root to build."
echo "You may need to restart your terminal or run 'source $PROFILE'"
echo "for all changes to take effect."
echo ""
