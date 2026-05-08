#!/bin/bash
set -euo pipefail

# --- Step 1: Check if the script is being run as root ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ This script must be run with superuser privileges."
  echo "💡 Usage: sudo bash $0"
  exit 1
fi

echo "✅ Running with sudo privileges..."
echo

#apt update
#apt upgrade -y
apt install bridge-utils python3-prettytable python3-argcomplete

# --- Step 1: Extract lincus.tgz to /opt and set permissions ---
TAR_FILE="$(dirname "$0")/lincus.tgz"
DEST_DIR="/opt/lincus"
LINK_PATH="/usr/local/bin/lincus"
SCRIPT_PATH="$DEST_DIR/lincus.sh"
LABS_PATH="$DEST_DIR/labs"

if [ -f "$TAR_FILE" ]; then
    echo "📦 Extracting $TAR_FILE to $DEST_DIR..."
    mkdir -p "$DEST_DIR"
    tar -xzf "$TAR_FILE" -C /opt
    echo "✅ Extraction completed."
    
    echo "🔗 Creating $LABS_PATH..."
    mkdir -p $LABS_PATH
    echo "✅ $LABS_PATH created."
    
    echo "🔗 Creating lincus database..."
    python3 -c "import sqlite3, os; conn = sqlite3.connect(os.path.expanduser('/opt/lincus/labs/lincus-scenarios.db')); conn.execute('CREATE TABLE IF NOT EXISTS SCENARIOS (ID TEXT PRIMARY KEY, PATH TEXT NOT NULL, RUNNING BOOLEAN DEFAULT FALSE, TITLE TEXT);'); conn.commit(); conn.close()"
    echo "✅ Lincus database created."

    echo "👤 Setting ownership to $SUDO_USER..."
    chown -R "$SUDO_USER":"$SUDO_USER" "$DEST_DIR"
    echo "✅ Ownership set."

    echo "🔗 Creating symlink $LINK_PATH -> $SCRIPT_PATH..."
    ln -sf "$SCRIPT_PATH" "$LINK_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ Symlink created and executable permission set."

else
    echo "⚠️ File $TAR_FILE not found, skipping extraction."
fi
echo

# --- Step 2: Add Lincus scripts to user shell startup files ---
USER_HOME=$(eval echo "~$SUDO_USER")
PROFILE_FILE="$USER_HOME/.profile"
BASHRC_FILE="$USER_HOME/.bashrc"
LINE='[ -f /opt/lincus/scripts/lincus-scripts.sh ] && source /opt/lincus/scripts/lincus-scripts.sh'

echo "🧩 Adding Lincus environment setup to $PROFILE_FILE and $BASHRC_FILE..."

# --- .profile section ---
# Create .profile if it doesn't exist
if [ ! -f "$PROFILE_FILE" ]; then
    echo "# ~/.profile" > "$PROFILE_FILE"
    echo >> "$PROFILE_FILE"
fi

# Add line only if it's not already present
if ! grep -Fxq "$LINE" "$PROFILE_FILE"; then
    echo "$LINE" >> "$PROFILE_FILE"
    echo "✅ Line added to $PROFILE_FILE"
else
    echo "ℹ️ Line already present in $PROFILE_FILE"
fi

# --- .bashrc section ---
# Create .bashrc if it doesn't exist
if [ ! -f "$BASHRC_FILE" ]; then
    echo "# ~/.bashrc" > "$BASHRC_FILE"
    echo >> "$BASHRC_FILE"
fi

# Add line only if it's not already present
if ! grep -Fxq "$LINE" "$BASHRC_FILE"; then
    echo >> "$BASHRC_FILE"
    echo "# Load Lincus scripts if available" >> "$BASHRC_FILE"
    echo "$LINE" >> "$BASHRC_FILE"
    echo "✅ Line added to $BASHRC_FILE"
else
    echo "ℹ️ Line already present in $BASHRC_FILE"
fi

# Ensure ownership
chown "$SUDO_USER":"$SUDO_USER" "$PROFILE_FILE" "$BASHRC_FILE"
echo


# --- Step 3: Create symlink to Incus aliases in user's local folder ---
USER_HOME=$(eval echo "~$SUDO_USER")
LOCAL_DIR="$USER_HOME/.local/lincus"
SOURCE_FILE="/opt/lincus/incus_aliases.sh"
TARGET_FILE="$LOCAL_DIR/incus_aliases.sh"

echo "🔗 Creating symlink $TARGET_FILE -> $SOURCE_FILE..."

# Ensure directory exists
mkdir -p "$LOCAL_DIR"

# Create or update the symlink
ln -sf "$SOURCE_FILE" "$TARGET_FILE"

# Ensure the user owns it
chown -h "$SUDO_USER":"$SUDO_USER" "$TARGET_FILE"
chown -R "$SUDO_USER":"$SUDO_USER" "$LOCAL_DIR"

echo "✅ Symlink created for Incus aliases."
echo

# --- Step 4: Ensure proper shell configuration (bash or zsh) ---
USER_HOME=$(eval echo "~$SUDO_USER")
USER_SHELL=$(getent passwd "$SUDO_USER" | cut -d: -f7)

echo "💬 Detected shell for $SUDO_USER: $USER_SHELL"

if [[ "$USER_SHELL" == *"zsh" ]]; then
  ZSHRC_FILE="$USER_HOME/.zshrc"

  echo "⚙️  Configuring .zshrc for Incus aliases and profile loading..."

  # Añadir bloque solo si no existe ya
  if ! grep -q "source ~/.local/lincus/incus_aliases.sh" "$ZSHRC_FILE" 2>/dev/null; then
    cat <<'EOF' >> "$ZSHRC_FILE"

# Cargar alias y funciones personalizadas
if [ -f ~/.local/lincus/incus_aliases.sh ]; then
  source ~/.local/lincus/incus_aliases.sh
fi

# ~/.zshrc
if [ -f ~/.profile ]; then
   source ~/.profile
fi
EOF
    echo "✅ Added Incus configuration to .zshrc"
  else
    echo "✅ .zshrc already contains Incus configuration"
  fi

  chown "$SUDO_USER":"$SUDO_USER" "$ZSHRC_FILE"

else
  echo "🐚 Shell is bash (or another shell)."
  echo "ℹ️  No need to modify .bashrc because bash already loads .profile automatically."
fi
echo

# --- Step 5: Run Incus image build as normal user ---
echo "🚀 Now building base Incus images as $SUDO_USER ..."
sudo -u "$SUDO_USER" bash <<'EOSU'
set -euo pipefail

ALPINE_VERSION="3.22"
BASE_IMAGE="images:alpine/${ALPINE_VERSION}"

if ! incus image list --format csv | cut -d',' -f1 | grep -q "^alpine/${ALPINE_VERSION}$"; then
    echo "Copying base Alpine ${ALPINE_VERSION} image..."
    incus image copy "${BASE_IMAGE}" local: --alias "alpine/${ALPINE_VERSION}"
fi

declare -A PACKAGES
declare -A SERVICES

PACKAGES["router"]="nano frr iptables dnsmasq"
SERVICES["router"]="staticroute sysctl dnsmasq frr iptables"

PACKAGES["simple-host"]="nano socat iproute2 bonding tcpdump"
SERVICES["simple-host"]="sysctl staticroute"

PACKAGES["afdx-host"]="nano socat bonding iproute2 tcpdump"
SERVICES["afdx-host"]="sysctl staticroute"

CONTAINERS=("router" "simple-host" "afdx-host")

setup_container() {
    local container=$1
    echo "Updating Alpine packages for '${container}'..."
    incus exec "$container" -- apk update
    incus exec "$container" -- apk upgrade
    if [[ -n "${PACKAGES[$container]:-}" ]]; then
        echo "Installing packages for '${container}': ${PACKAGES[$container]}"
        incus exec "$container" -- apk add ${PACKAGES[$container]}
    fi
    if [[ -n "${SERVICES[$container]:-}" ]]; then
        echo "Enabling services for '${container}': ${SERVICES[$container]}"
        for svc in ${SERVICES[$container]}; do
            incus exec "$container" -- rc-update add "$svc"
        done
    fi
    if echo "${PACKAGES[$container]}" | grep -qw iptables; then
        incus exec "$container" -- rc-service iptables save
    fi
}

for CONTAINER_NAME in "${CONTAINERS[@]}"; do
    IMAGE_NAME="$CONTAINER_NAME"
    if incus list --format csv | cut -d',' -f1 | grep -q "^${CONTAINER_NAME}$"; then
        echo "Container '${CONTAINER_NAME}' exists. Deleting..."
        incus delete "${CONTAINER_NAME}" --force
    fi
    echo "Creating container '${CONTAINER_NAME}'..."
    incus launch "local:alpine/${ALPINE_VERSION}" "$CONTAINER_NAME"
    echo "Waiting for container '${CONTAINER_NAME}' to start..."
    until [ "$(incus list --format csv | grep "^${CONTAINER_NAME}," | cut -d',' -f2)" = "RUNNING" ]; do
        sleep 1
    done
    until incus exec "${CONTAINER_NAME}" -- ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; do
        sleep 1
    done
    setup_container "$CONTAINER_NAME"
    incus stop "$CONTAINER_NAME"
    if incus image list --format csv | cut -d',' -f1 | grep -q "^${IMAGE_NAME}$"; then
        echo "Image '${IMAGE_NAME}' exists. Deleting..."
        incus image delete "$IMAGE_NAME"
    fi
    incus publish "$CONTAINER_NAME" --alias "$IMAGE_NAME" description="${IMAGE_NAME} (Alpine ${ALPINE_VERSION})"
    echo "Image '${IMAGE_NAME}' created successfully."
    incus delete "$CONTAINER_NAME" --force
done
EOSU

echo
echo "✅ Lincus environment setup completed successfully."
echo
echo "Please press open a new one to use the updated Lincus environment."



