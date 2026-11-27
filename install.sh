#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CCG_REPO_URL:-https://github.com/sglinhome/ccg.git}"
BASE_DIR="${HOME}/.agents/skills"
TARGET_DIR="${BASE_DIR}/ccg"

mkdir -p "${BASE_DIR}"

if [ -d "${TARGET_DIR}/.git" ]; then
  echo "[ccg] Updating existing installation in ${TARGET_DIR}..."
  git -C "${TARGET_DIR}" pull --ff-only
else
  rm -rf "${TARGET_DIR}"
  echo "[ccg] Cloning ${REPO_URL} to ${TARGET_DIR}..."
  git clone --depth 1 "${REPO_URL}" "${TARGET_DIR}"
fi

chmod +x "${TARGET_DIR}/scripts/ccg.py"

for agent_dir in "${HOME}/.pi/agent/skills" "${HOME}/.claude/skills" "${HOME}/.codex/skills"; do
  mkdir -p "${agent_dir}"
  ln -sfn "${TARGET_DIR}" "${agent_dir}/ccg"
done

if [ -d "${HOME}/.omp/agent" ]; then
  mkdir -p "${HOME}/.omp/agent/skills"
  ln -sfn "${TARGET_DIR}" "${HOME}/.omp/agent/skills/ccg"
fi

if [ ! -f "${HOME}/.ccg.json" ]; then
  echo ""
  echo "[ccg] Next step: create ~/.ccg.json (chmod 600) with your Magpie Gateway key:"
  cat << 'EOF'
cat > ~/.ccg.json << 'JSON'
{
  "baseUrl": "http://10.89.10.199:3425/v1",
  "apiKey": "YOUR_GATEWAY_KEY",
  "planModel": "group/plan-review",
  "codeModel": "group/code-pro",
  "timeoutSec": 120
}
JSON
chmod 600 ~/.ccg.json
EOF
else
  echo "[ccg] Found existing ~/.ccg.json"
fi

echo "[ccg] Installed successfully!"
