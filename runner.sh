
#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="AUTOML1"
TOKEN="${1:-}"

if [[ -z "${TOKEN}" ]]; then
    echo "ERROR: AUTOML token is required."
    echo
    echo "Usage:"
    echo "  bash runner.sh 'AUTOML1....'"
    exit 1
fi

WORK_DIR="${HOME}/automl_training"
REPO_DIR="${WORK_DIR}/repo"
DATA_DIR="${WORK_DIR}/data"
LOG_DIR="${WORK_DIR}/logs"
VENV_DIR="${WORK_DIR}/venv"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/training_${TIMESTAMP}.log"
PAYLOAD_FILE="${WORK_DIR}/payload.json"

mkdir -p "${WORK_DIR}" "${REPO_DIR}" "${DATA_DIR}" "${LOG_DIR}"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo
echo "============================================================"
echo " AUTOML TRAINING RUNNER"
echo "============================================================"
echo "Started : $(date)"
echo "Host    : $(hostname)"
echo "Workdir : ${WORK_DIR}"
echo "Log     : ${LOG_FILE}"
echo

cleanup() {
    rm -f "${PAYLOAD_FILE}"
    rm -f "${WORK_DIR}/git-askpass.sh"
    unset GITHUB_TOKEN
    unset GITHUB_REPO
    unset GITHUB_BRANCH
    unset GOOGLE_DRIVE_URL
    unset WANDB_API_KEY
}

failure() {
    local code=$?

    echo
    echo "============================================================"
    echo " AUTOML TRAINING FAILED"
    echo "============================================================"
    echo "Exit code : ${code}"
    echo "Log      : ${LOG_FILE}"
    echo "Time     : $(date)"
    echo

    cleanup

    exit "${code}"
}

trap failure ERR
trap cleanup EXIT


echo "[1/10] Checking system..."

for command in python3 git curl; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: ${command} is not installed."
        exit 1
    fi
done

python3 --version
git --version


echo
echo "[2/10] Decoding AUTOML token..."

TOKEN_VERSION="${TOKEN%%.*}"

if [[ "${TOKEN_VERSION}" != "${VERSION}" ]]; then
    echo "ERROR: Invalid or unsupported token."
    exit 1
fi

TOKEN_DATA="${TOKEN#*.}"

if [[ -z "${TOKEN_DATA}" ]]; then
    echo "ERROR: Empty token payload."
    exit 1
fi

python3 - "${TOKEN_DATA}" "${PAYLOAD_FILE}" <<'PY'
import base64
import sys
from pathlib import Path

encoded = sys.argv[1]
output = Path(sys.argv[2])

encoded += "=" * (-len(encoded) % 4)

try:
    data = base64.urlsafe_b64decode(encoded)
except Exception as exc:
    raise SystemExit(f"Invalid token encoding: {exc}")

try:
    text = data.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit("Token payload is not valid UTF-8.")

try:
    import json
    payload = json.loads(text)
except Exception as exc:
    raise SystemExit(f"Invalid JSON payload: {exc}")

output.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2),
    encoding="utf-8"
)
PY

chmod 600 "${PAYLOAD_FILE}"


echo
echo "[3/10] Installing jq..."

if ! command -v jq >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y jq
    else
        echo "ERROR: jq is required."
        exit 1
    fi
fi


echo
echo "[4/10] Reading configuration..."

GITHUB_REPO="$(jq -er '.github.repo' "${PAYLOAD_FILE}")"
GITHUB_BRANCH="$(jq -er '.github.branch // "main"' "${PAYLOAD_FILE}")"
GITHUB_TOKEN="$(jq -er '.github.token' "${PAYLOAD_FILE}")"
TRAINING_PATH="$(jq -er '.training.path' "${PAYLOAD_FILE}")"
GOOGLE_DRIVE_URL="$(jq -er '.data.google_drive' "${PAYLOAD_FILE}")"

WANDB_PROJECT="$(jq -er '.wandb.project // empty' "${PAYLOAD_FILE}" || true)"
WANDB_API_KEY="$(jq -er '.wandb.api_key // empty' "${PAYLOAD_FILE}" || true)"

echo "GitHub repo : ${GITHUB_REPO}"
echo "Git branch  : ${GITHUB_BRANCH}"
echo "Training    : ${TRAINING_PATH}"

if [[ -n "${WANDB_PROJECT}" ]]; then
    echo "W&B project : ${WANDB_PROJECT}"
fi


echo
echo "[5/10] Checking GPU..."

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
else
    echo "WARNING: nvidia-smi not found."
fi


echo
echo "[6/10] Creating Python environment..."

if [[ ! -d "${VENV_DIR}" ]]; then
    python3 -m venv "${VENV_DIR}"
fi

source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip setuptools wheel


echo
echo "[7/10] Downloading private GitHub repository..."

rm -rf "${REPO_DIR}"

cat > "${WORK_DIR}/git-askpass.sh" <<'EOF'
#!/usr/bin/env bash

case "$1" in
    *Username*)
        printf '%s\n' "x-access-token"
        ;;
    *Password*)
        printf '%s\n' "${GITHUB_TOKEN}"
        ;;
esac
EOF

chmod 700 "${WORK_DIR}/git-askpass.sh"

export GIT_ASKPASS="${WORK_DIR}/git-askpass.sh"
export GIT_TERMINAL_PROMPT=0

git clone \
    --filter=blob:none \
    --no-checkout \
    --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_REPO}.git" \
    "${REPO_DIR}"

cd "${REPO_DIR}"

git sparse-checkout init --cone
git sparse-checkout set "${TRAINING_PATH}"
git checkout "${GITHUB_BRANCH}"

echo
echo "Repository downloaded."

unset GITHUB_TOKEN
unset GIT_ASKPASS
unset GIT_TERMINAL_PROMPT

rm -f "${WORK_DIR}/git-askpass.sh"


echo
echo "[8/10] Downloading Google Drive data..."

python -m pip install gdown

mkdir -p "${DATA_DIR}"

if [[ "${GOOGLE_DRIVE_URL}" == *"/folders/"* ]]; then
    gdown \
        --folder \
        "${GOOGLE_DRIVE_URL}" \
        -O "${DATA_DIR}"
else
    gdown \
        "${GOOGLE_DRIVE_URL}" \
        -O "${DATA_DIR}"
fi


echo
echo "[9/10] Installing training dependencies..."

cd "${REPO_DIR}/${TRAINING_PATH}"

if [[ ! -f "train.py" ]]; then
    echo "ERROR: train.py was not found."
    exit 1
fi

if [[ -f "requirements.txt" ]]; then
    python -m pip install -r requirements.txt
fi


echo
echo "[10/10] Starting training..."

export PYTHONUNBUFFERED=1
export AUTOML_DATA_DIR="${DATA_DIR}"

if [[ -n "${WANDB_API_KEY}" ]]; then
    export WANDB_API_KEY
fi

if [[ -n "${WANDB_PROJECT}" ]]; then
    export WANDB_PROJECT
fi

python train.py


echo
echo "============================================================"
echo " TRAINING COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "Finished : $(date)"
echo "Log      : ${LOG_FILE}"
echo

exit 0
