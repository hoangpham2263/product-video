#!/bin/bash
# Opens Product Video on macOS: core/launch.ps1 names the server to start (src/server.mjs).
cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.dotnet/tools:$PATH"
if ! command -v node >/dev/null || ! command -v pwsh >/dev/null; then bash core/setup/setup-mac.sh || { read -r -p "Chưa cài xong. Nhấn Enter để đóng."; exit 1; }; fi
entry=$(pwsh -NoProfile -File core/launch.ps1 -Mac) || { read -r -p "Không mở được Product Video. Nhấn Enter để đóng."; exit 1; }
[ -n "$entry" ] || exit 0
# The server's own output (a crash, say) is kept in workspace/logs/mac-server.log for Gửi lỗi.
logs=workspace/logs
mkdir -p "$logs"
log="$logs/mac-server.log"
[ -f "$log" ] && [ "$(wc -c < "$log")" -gt 1048576 ] && mv "$log" "$logs/mac-server.old.log"
nohup node "$entry" >>"$log" 2>&1 &
disown
# The app keeps running on its own; close this Terminal window once the script has ended.
# nohup: Terminal hangs up this session's processes when the script exits, before the close would run.
nohup /bin/bash -c 'sleep 1; osascript -e "tell application \"Terminal\" to close (every window whose name contains \"start-app.command\")"' >/dev/null 2>&1 &
exit 0
