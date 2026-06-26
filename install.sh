#!/usr/bin/env bash
# heroku-scripts installer
# Usage: curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/heroku-scripts/main/install.sh | sh
set -eu

REPO="DefactoSoftware/heroku-scripts"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

echo "Installing heroku-scripts..."

# Determine install directory
if [ -w "/usr/local/bin" ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

# Download main script
curl -fsSL "${BASE_URL}/bin/heroku-scripts" -o "${INSTALL_DIR}/heroku-scripts"
chmod +x "${INSTALL_DIR}/heroku-scripts"

echo ""
echo "Installed heroku-scripts to ${INSTALL_DIR}/heroku-scripts"
echo ""

# PATH check
if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$INSTALL_DIR"; then
  echo "NOTE: ${INSTALL_DIR} is not in your PATH. Add it:"
  echo ""
  echo "  # bash/zsh"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  echo ""
  echo "  # fish"
  echo "  fish_add_path ${INSTALL_DIR}"
  echo ""
fi

# heroku CLI check
if ! command -v heroku >/dev/null 2>&1; then
  echo "NOTE: the heroku CLI was not found. heroku-scripts needs it installed"
  echo "and authenticated: https://devcenter.heroku.com/articles/heroku-cli"
  echo ""
fi

cat <<EOF
Get started:

  heroku login        # if you haven't already
  heroku-scripts help

See https://github.com/DefactoSoftware/heroku-scripts for full documentation.
EOF
