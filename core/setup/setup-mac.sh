#!/bin/bash
# One-time install on macOS, run by start-app.command when Node.js or PowerShell is missing: Homebrew, Node.js,
# PowerShell 7 and the browser bridge, each only when missing, then the same readiness check as Cấu hình.
cd "$(dirname "$0")/../.." || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.dotnet/tools:$PATH"
step() { printf '\n== %s\n' "$1"; }

step "Homebrew"
if ! command -v brew >/dev/null; then
  read -r -p "Chưa có Homebrew (dùng để cài Node.js và PowerShell). Cài bây giờ? (y/n) " answer
  [ "$answer" = "y" ] || { echo "Cài Homebrew theo https://brew.sh rồi mở lại start-app.command."; exit 1; }
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

step "Node.js"
command -v node >/dev/null || brew install node || exit 1
echo "Node.js $(node --version)"

step "PowerShell 7"
command -v pwsh >/dev/null || brew install --cask powershell || exit 1
pwsh --version

step "Cầu nối trình duyệt"
[ -f core/bridge/package.json ] && (cd core/bridge && npm install --silent) && echo "Đã cài."

step "Kiểm tra"
pwsh -NoProfile -File core/setup/setup-check.ps1
echo
