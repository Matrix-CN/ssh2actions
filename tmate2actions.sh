#!/usr/bin/env bash

set -Eeuo pipefail

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"

INFO="[${Green_font_prefix}INFO${Font_color_suffix}]"
ERROR="[${Red_font_prefix}ERROR${Font_color_suffix}]"

TMATE_SOCK="/tmp/tmate.sock"
TELEGRAM_LOG="/tmp/telegram.log"
CONTINUE_FILE="/tmp/continue"

# ============================================================
# Cleanup
# ============================================================

cleanup() {
    if [[ -S "${TMATE_SOCK}" ]]; then
        tmate -S "${TMATE_SOCK}" kill-server >/dev/null 2>&1 || true
    fi

    rm -f "${TMATE_SOCK}" "${CONTINUE_FILE}"
}

trap cleanup EXIT

# ============================================================
# Install dependencies
# ============================================================

echo -e "${INFO} Setting up tmate ..."

OS="$(uname -s)"

if [[ "${OS}" == "Linux" ]]; then

    # GitHub-hosted Ubuntu runner
    if command -v apt-get >/dev/null 2>&1; then

        echo -e "${INFO} Installing dependencies with apt..."

        sudo apt-get update -qq

        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            tmate \
            openssh-client \
            curl \
            jq

    elif command -v dnf >/dev/null 2>&1; then

        sudo dnf install -y tmate openssh-clients curl jq

    elif command -v yum >/dev/null 2>&1; then

        sudo yum install -y tmate openssh-clients curl jq

    else
        echo -e "${ERROR} Unsupported Linux package manager!"
        exit 1
    fi

elif [[ "${OS}" == "Darwin" ]]; then

    if ! command -v brew >/dev/null 2>&1; then
        echo -e "${ERROR} Homebrew is not installed!"
        exit 1
    fi

    brew install tmate curl jq

else

    echo -e "${ERROR} This system is not supported!"
    exit 1

fi

# ============================================================
# Check tmate
# ============================================================

if ! command -v tmate >/dev/null 2>&1; then
    echo -e "${ERROR} tmate installation failed!"
    exit 1
fi

echo -e "${INFO} tmate version:"
tmate -V

# ============================================================
# Generate SSH key
# ============================================================

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ ! -f "${HOME}/.ssh/id_rsa" ]]; then
    echo -e "${INFO} Generating SSH key..."

    ssh-keygen \
        -t rsa \
        -b 4096 \
        -f "${HOME}/.ssh/id_rsa" \
        -q \
        -N ""
fi

# ============================================================
# Start tmate
# ============================================================

echo -e "${INFO} Running tmate..."

rm -f "${TMATE_SOCK}" "${CONTINUE_FILE}"

tmate \
    -S "${TMATE_SOCK}" \
    new-session \
    -d

echo -e "${INFO} Waiting for tmate server..."

tmate \
    -S "${TMATE_SOCK}" \
    wait \
    tmate-ready

# ============================================================
# Get connection information
# ============================================================

TMATE_SSH="$(
    tmate \
        -S "${TMATE_SOCK}" \
        display \
        -p '#{tmate_ssh}'
)"

TMATE_WEB="$(
    tmate \
        -S "${TMATE_SOCK}" \
        display \
        -p '#{tmate_web}'
)"

if [[ -z "${TMATE_SSH}" ]]; then
    echo -e "${ERROR} Failed to obtain tmate SSH address!"
    exit 1
fi

echo
echo "-----------------------------------------------------------------------------------"
echo "GitHub Actions - tmate session"
echo
echo "CLI:"
echo "${TMATE_SSH}"
echo
echo "URL:"
echo "${TMATE_WEB}"
echo
echo "TIPS:"
echo "Run 'touch ${CONTINUE_FILE}' to continue to the next step."
echo "-----------------------------------------------------------------------------------"
echo

# ============================================================
# Telegram notification
# ============================================================

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then

    echo -e "${INFO} Sending message to Telegram..."

    MSG="*GitHub Actions - tmate session info:*

⚡ *CLI:*
\`${TMATE_SSH}\`

🔗 *URL:*
${TMATE_WEB}

🔔 *TIPS:*
Run \`touch ${CONTINUE_FILE}\` to continue to the next step."

    TELEGRAM_API="${TELEGRAM_API_URL:-https://api.telegram.org}"

    set +e

    curl \
        --silent \
        --show-error \
        --fail \
        --request POST \
        "${TELEGRAM_API}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${MSG}" \
        >"${TELEGRAM_LOG}" 2>&1

    CURL_STATUS=$?

    set -e

    if [[ ${CURL_STATUS} -ne 0 ]]; then

        echo -e "${ERROR} Telegram request failed:"
        cat "${TELEGRAM_LOG}"

    elif command -v jq >/dev/null 2>&1 &&
         [[ "$(jq -r '.ok // false' "${TELEGRAM_LOG}" 2>/dev/null)" != "true" ]]; then

        echo -e "${ERROR} Telegram message sending failed:"
        cat "${TELEGRAM_LOG}"

    else

        echo -e "${INFO} Telegram message sent successfully!"

    fi
fi

# ============================================================
# Print connection information periodically
# ============================================================

PRT_COUNT="${PRT_COUNT:-1}"
PRT_TOTAL="${PRT_TOTAL:-10}"
PRT_INTERVAL_SEC="${PRT_INTERVAL_SEC:-10}"

while (( PRT_COUNT <= PRT_TOTAL )); do

    if (( PRT_COUNT > 1 )); then
        SECONDS_LEFT="${PRT_INTERVAL_SEC}"

        while (( SECONDS_LEFT > 0 )); do
            echo -e "${INFO} (${PRT_COUNT}/${PRT_TOTAL}) Please wait ${SECONDS_LEFT}s ..."
            sleep 1
            ((SECONDS_LEFT--))
        done
    fi

    echo "-----------------------------------------------------------------------------------"
    echo "To connect to this session copy and paste the following:"
    echo
    echo -e "CLI: ${Green_font_prefix}${TMATE_SSH}${Font_color_suffix}"
    echo -e "URL: ${Green_font_prefix}${TMATE_WEB}${Font_color_suffix}"
    echo
    echo "TIPS: Run 'touch ${CONTINUE_FILE}' to continue to the next step."
    echo "-----------------------------------------------------------------------------------"

    ((PRT_COUNT++))

done

# ============================================================
# Wait for manual continuation
# ============================================================

echo
echo -e "${INFO} Waiting for '${CONTINUE_FILE}' ..."
echo -e "${INFO} Connect via tmate and run:"
echo
echo "touch ${CONTINUE_FILE}"
echo

while [[ ! -e "${CONTINUE_FILE}" ]]; do

    # Detect tmate unexpectedly exiting
    if [[ ! -S "${TMATE_SOCK}" ]]; then
        echo -e "${ERROR} tmate session/socket disappeared!"
        exit 1
    fi

    sleep 2

done

echo -e "${INFO} Continue to the next step."

exit 0
