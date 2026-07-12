#!/bin/bash
set -e

# Unified build script for UniLab

# --- Platform Detection ---
PLATFORM="unknown"
case "$(uname -s)" in
    Linux*)     PLATFORM="linux";;
    Darwin*)    PLATFORM="macos";;
    MINGW*)     PLATFORM="windows";;
    *)          echo "Unsupported platform: $(uname -s)"; exit 1;;
esac

echo "🚀 Starting UniLab build for $PLATFORM..."

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." &> /dev/null && pwd)"
PKG_NAME="unilab"
PKG_VERSION="0.1.0"


if [ "$PLATFORM" == "linux" ]; then
    PKG_ARCH=$(dpkg --print-architecture)
    BUILD_DIR="$PROJECT_ROOT/build_release"

    echo "🛠️ Creating .deb package for $PKG_NAME version $PKG_VERSION ($PKG_ARCH)..."
    echo "📂 Project Root: $PROJECT_ROOT"

    # 1. Cleanup and Prepare Directories
    echo "🧹 Cleaning up and preparing directories..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/opt/unilab"
    mkdir -p "$BUILD_DIR/usr/bin"
    mkdir -p "$BUILD_DIR/usr/share/applications"
    mkdir -p "$BUILD_DIR/usr/share/icons/hicolor/256x256/apps"
    mkdir -p "$BUILD_DIR/DEBIAN"

    # 2. Setup Standalone Python
    echo "📦 Downloading and bundling standalone Python interpreter..."
    if [ "$PKG_ARCH" == "arm64" ] || [ "$(uname -m)" == "aarch64" ]; then
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.12.1+20240107-aarch64-unknown-linux-gnu-install_only.tar.gz"
    else
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.12.1+20240107-x86_64-unknown-linux-gnu-install_only.tar.gz"
    fi
    mkdir -p "$BUILD_DIR/temp_python"
    wget -q -O "$BUILD_DIR/temp_python/python.tar.gz" "$PYTHON_URL"
    tar -xzf "$BUILD_DIR/temp_python/python.tar.gz" -C "$BUILD_DIR/opt/unilab/"
    rm -rf "$BUILD_DIR/temp_python"

    # Set path to the new python for the build
    export PYO3_PYTHON="$BUILD_DIR/opt/unilab/python/bin/python3"
    export RUSTFLAGS="-L $BUILD_DIR/opt/unilab/python/lib -C link-arg=-Wl,-rpath,'/opt/unilab/python/lib'"

    # 3. Build Backend
    echo "🐍 Building backend..."
    DEB_HOST_MULTIARCH=$(dpkg-architecture -q DEB_HOST_MULTIARCH)

    ## 3.1 Build Rust Components
    echo "🦀 Building Rust components with bundled python..."
    cd "$PROJECT_ROOT/backend"
    cargo build --release
    cd "$PROJECT_ROOT"

    ## 3.2 Copy Backend Files
    echo "📂 Copying backend files..."
    mkdir -p "$BUILD_DIR/opt/unilab/backend"
    rsync -aL --exclude="__pycache__" --exclude="target" \
        "$PROJECT_ROOT/backend/core" \
        "$PROJECT_ROOT/backend/api" \
        "$PROJECT_ROOT/backend/utils" \
        "$PROJECT_ROOT/backend/stdlib" \
        "$PROJECT_ROOT/backend/UniLab.py" \
        "$BUILD_DIR/opt/unilab/backend/"

    cp "$PROJECT_ROOT/backend/target/release/libunilab_core.so" "$BUILD_DIR/opt/unilab/backend/core/unilab_rust_core.so"
    mkdir -p "$BUILD_DIR/opt/unilab/bin"
    cp "$PROJECT_ROOT/backend/target/release/unilab_cli" "$BUILD_DIR/opt/unilab/bin/unilab-cli"

    echo "🔬 Analyzing library dependencies..."
    ldd "$PROJECT_ROOT/backend/target/release/libunilab_core.so" || echo "ldd command failed"
    readelf -d "$PROJECT_ROOT/backend/target/release/libunilab_core.so" | grep 'RUNPATH' || echo "No RUNPATH found"


    ## 3.3 Setup Virtualenv
    echo "🐍 Creating virtualenv..."
    "$BUILD_DIR/opt/unilab/python/bin/python3" -m venv "$BUILD_DIR/opt/unilab/venv"
    "$BUILD_DIR/opt/unilab/venv/bin/pip" install --upgrade pip

    cat <<EOF > "$BUILD_DIR/requirements.txt"
numpy==2.4.4
scipy>=1.10.0
matplotlib==3.10.9
pandas>=2.0.0
sympy
Pillow
scikit-learn>=1.2.0
lark==1.3.1
fastapi
uvicorn[standard]
gunicorn
pydantic
python-dotenv
python-multipart
httpx
pytest-asyncio
aiofiles
EOF

    echo "📦 Installing Python dependencies..."
    "$BUILD_DIR/opt/unilab/venv/bin/pip" install --ignore-installed -r "$BUILD_DIR/requirements.txt"
    rm "$BUILD_DIR/requirements.txt"

    # Patch pyvenv.cfg to point to target machine path /opt/unilab/python
    cat <<EOF > "$BUILD_DIR/opt/unilab/venv/pyvenv.cfg"
home = /opt/unilab/python/bin
include-system-site-packages = false
version = 3.12.1
executable = /opt/unilab/python/bin/python3
EOF

    ## 3.4 Fix Paths and Shebangs
    echo "🩹 Fixing virtualenv shebangs and paths..."
    find "$BUILD_DIR/opt/unilab/venv/bin" -type f -executable -exec sed -i "1s|^#!.*python.*|#!/opt/unilab/venv/bin/python3|" {} +

    cd "$BUILD_DIR/opt/unilab/venv/bin"
    ln -sf ../../python/bin/python3 python3
    ln -sf python3 python
    ln -sf python3 python3.12
    cd "$PROJECT_ROOT"

    echo "✅ Backend build complete."

    # 4. Build Frontend
    echo "🚀 Building frontend..."
    ./script/build_bridge.sh

    cd "$PROJECT_ROOT/frontend"
    flutter build linux --release
    cd "$PROJECT_ROOT"

    echo "📂 Copying frontend files..."
    mkdir -p "$BUILD_DIR/opt/unilab/gui"
    if [ -d "$PROJECT_ROOT/frontend/build/linux/arm64/release/bundle/" ]; then
        FLUTTER_BUNDLE_DIR="$PROJECT_ROOT/frontend/build/linux/arm64/release/bundle/"
    else
        FLUTTER_BUNDLE_DIR="$PROJECT_ROOT/frontend/build/linux/x64/release/bundle/"
    fi
    cp -r "$FLUTTER_BUNDLE_DIR"* "$BUILD_DIR/opt/unilab/gui/"

    echo "✅ Frontend build complete."

    # 4. Assemble Debian Package
    echo "📦 Assembling Debian package..."
    echo "🖼️ Copying icon..."
    cp "$PROJECT_ROOT/frontend/assets/logo.png" "$BUILD_DIR/usr/share/icons/hicolor/256x256/apps/unilab.png"

    echo "📝 Creating control file..."
    cat <<EOF > "$BUILD_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: $PKG_VERSION
Section: science
Priority: optional
Architecture: $PKG_ARCH
Depends: libblas3, liblapack3, libstdc++6, libc6, libgl1, libfontconfig1, libx11-6, libgtk-3-0
Maintainer: UniLab Team <contact@unilab.dev>
Description: UniLab - Computational Intelligence and Simulation Environment
 A professional, high-fidelity scientific computing environment with a MATLAB-inspired GUI.
 Includes a full backend and a Flutter-based frontend.
EOF

    echo "📜 Creating post-install script..."
    cat <<EOF > "$BUILD_DIR/DEBIAN/postinst"
#!/bin/bash
set -e
# Ensure workspace directory exists and is writable
mkdir -p /var/lib/unilab/workspaces
chmod 777 /var/lib/unilab/workspaces
exit 0
EOF
    chmod 755 "$BUILD_DIR/DEBIAN/postinst"

    echo "✅ Debian package assembly complete."

    # 5. Create Wrapper Scripts
    echo "📜 Creating wrapper scripts..."

    # Main Desktop App
    cat <<EOF > "$BUILD_DIR/usr/bin/unilab"
#!/bin/bash
export LD_LIBRARY_PATH="/opt/unilab/python/lib:/opt/unilab/gui/lib:\$LD_LIBRARY_PATH"

# Add virtualenv site-packages to PYTHONPATH dynamically
for site_pkg in /opt/unilab/venv/lib/python*/site-packages; do
    if [ -d "\$site_pkg" ]; then
        export PYTHONPATH="\$site_pkg:\$PYTHONPATH"
    fi
done
export PYTHONPATH="/opt/unilab:\$PYTHONPATH"

# Start the backend server in the background
cd /opt/unilab/backend
/opt/unilab/venv/bin/gunicorn -w 4 -k uvicorn.workers.UvicornWorker api.main:app --bind 127.0.0.1:8000 &
SERVER_PID=\$!

# Launch the Flutter GUI
/opt/unilab/gui/unilab

# Clean up the server process when the GUI closes
kill \$SERVER_PID
EOF
    chmod +x "$BUILD_DIR/usr/bin/unilab"

    # UniLab Server (standalone)
    cat <<EOF > "$BUILD_DIR/usr/bin/unilab-server"
#!/bin/bash
export LD_LIBRARY_PATH="/opt/unilab/python/lib:/opt/unilab/gui/lib:\$LD_LIBRARY_PATH"

# Add virtualenv site-packages to PYTHONPATH dynamically
for site_pkg in /opt/unilab/venv/lib/python*/site-packages; do
    if [ -d "\$site_pkg" ]; then
        export PYTHONPATH="\$site_pkg:\$PYTHONPATH"
    fi
done
export PYTHONPATH="/opt/unilab:\$PYTHONPATH"

cd /opt/unilab/backend
/opt/unilab/venv/bin/gunicorn -w 4 -k uvicorn.workers.UvicornWorker api.main:app --bind 0.0.0.0:8000
EOF
    chmod +x "$BUILD_DIR/usr/bin/unilab-server"

    # Rust CLI
    cat <<EOF > "$BUILD_DIR/usr/bin/unilab-cli"
#!/bin/bash
/opt/unilab/bin/unilab-cli "\$@"
EOF
    chmod +x "$BUILD_DIR/usr/bin/unilab-cli"

    # Python CLI
    cat <<EOF > "$BUILD_DIR/usr/bin/unilab-core"
#!/bin/bash
export LD_LIBRARY_PATH="/opt/unilab/python/lib:/opt/unilab/gui/lib:\$LD_LIBRARY_PATH"

# Add virtualenv site-packages to PYTHONPATH dynamically
for site_pkg in /opt/unilab/venv/lib/python*/site-packages; do
    if [ -d "\$site_pkg" ]; then
        export PYTHONPATH="\$site_pkg:\$PYTHONPATH"
    fi
done
export PYTHONPATH="/opt/unilab:\$PYTHONPATH"

/opt/unilab/venv/bin/python3 /opt/unilab/backend/UniLab.py "\$@"
EOF
    chmod +x "$BUILD_DIR/usr/bin/unilab-core"

    echo "✅ Wrapper scripts created."

    # 6. Create Desktop Entry
    echo "🚀 Creating .desktop file..."
    cat <<EOF > "$BUILD_DIR/usr/share/applications/unilab.desktop"
[Desktop Entry]
Name=UniLab
Comment=Computational Intelligence and Simulation Environment
Exec=unilab
Icon=unilab
Terminal=false
Type=Application
Categories=Science;Engineering;Education;
EOF

    echo "✅ .desktop file created."

    # 7. Build the Debian Package
    echo "📦 Building final .deb package..."
    dpkg-deb --build "$BUILD_DIR" "$PROJECT_ROOT/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

    echo "✅ Success! Package created at root: ${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

elif [ "$PLATFORM" == "windows" ]; then
    echo "Windows build is not yet implemented in this unified script."
    echo "Please use build_unilab.ps1 or build_unilab_win.sh for Windows."
elif [ "$PLATFORM" == "macos" ]; then
    echo "macOS build is not yet implemented in this unified script."
fi
