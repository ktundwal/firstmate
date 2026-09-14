#!/usr/bin/env bash
# The wrapper must give a native Windows Node process a usable environment path.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(node -p 'process.platform')" != win32 ]; then
  echo "skip: native Windows Node required"
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi-windows)
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/bin"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$TMP_ROOT/home/.tasks.toml"
printf 'correct isolated backlog\n' > "$TMP_ROOT/home/data/backlog.md"
cat > "$TMP_ROOT/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
node -e '
const fs = require("node:fs");
if (fs.readFileSync(process.env.TASKS_AXI_FILE, "utf8").trim() !== "correct isolated backlog") {
  throw new Error("Wrong backlog reached the native process");
}
console.log("native backlog reached");
'
SH
chmod +x "$TMP_ROOT/bin/tasks-axi"
out=$(PATH="$TMP_ROOT/bin:$PATH" FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-tasks-axi.sh" list) \
  || fail "native Node could not read the owning home's backlog"
[ "$out" = 'native backlog reached' ] || fail "the wrong backlog reached the native process"
pass "the backlog environment path crosses Git Bash to native Node without changing homes"
