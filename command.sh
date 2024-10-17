#!/bin/bash

# Ganti dengan token bot Telegram Anda
TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
WORKDIR="DIRECTORY" # check it with pwd
UPDATE_ID_FILE="$WORKDIR/update_id.txt"
LIST_DOMAIN="$WORKDIR/walawe/domains.txt"
LOG_FILE="$WORKDIR/walawe/current_log.txt"  # Assuming this is where the log data is stored

# Memeriksa dan membuat file untuk menyimpan update_id jika belum ada
if [[ ! -f $UPDATE_ID_FILE ]]; then
    echo "0" > $UPDATE_ID_FILE
fi

# Mengambil update terakhir dari Telegram
get_updates() {
    curl -s -X GET "https://api.telegram.org/bot$TOKEN/getUpdates"
}

# Mengirim pesan ke Telegram
send_telegram_message() {
    local CHAT_ID=$1
    local MESSAGE=$2

    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$MESSAGE" \
    -d parse_mode="Markdown"
}

# Mengirim file ke Telegram
send_telegram_file() {
    local FILE_PATH=$1
    local CHAT_ID=$2
    local CAPTION=$3

    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendDocument" \
    -F chat_id="$CHAT_ID" \
    -F document=@"$FILE_PATH" \
    -F caption="$CAPTION"
}

# Mengirim pesan bantuan
send_help_message() {
    local CHAT_ID=$1
    local MESSAGE="🆘 *Daftar Perintah 🆘*%0A"
    MESSAGE+="1. /fulldomain - Display all registered domains.%0A"
    MESSAGE+="2. /detailsdomain <domain> - Display details for a specific domain.%0A"
    MESSAGE+="3. /downloadcsv - Download data of all domains in CSV format.%0A"
    MESSAGE+="%0AUse the command above to obtain more information."

    send_telegram_message "$CHAT_ID" "$MESSAGE"
}

# Mengirim isi file list.txt ke Telegram dengan nomor
send_list_message() {
    local CHAT_ID=$1
    local FILE_PATH=$LIST_DOMAIN
    local MAX_LENGTH=4096

    if [[ -f $FILE_PATH ]]; then
        MESSAGE=""
        local LINE_NUMBER=1

        while IFS= read -r line; do
            MESSAGE+="$LINE_NUMBER. $line"$'\n'
            ((LINE_NUMBER++))
        done < "$FILE_PATH"

        while [ ${#MESSAGE} -gt $MAX_LENGTH ]; do
            CUT_INDEX=$MAX_LENGTH
            while [ $CUT_INDEX -gt 0 ] && [ "${MESSAGE:CUT_INDEX:1}" != $'\n' ]; do
                CUT_INDEX=$((CUT_INDEX - 1))
            done

            if [ $CUT_INDEX -eq 0 ]; then
                CUT_INDEX=$MAX_LENGTH
            fi

            PART="${MESSAGE:0:CUT_INDEX}"
            send_telegram_message "$CHAT_ID" "$PART"
            MESSAGE="${MESSAGE:CUT_INDEX}"
        done
        
        send_telegram_message "$CHAT_ID" "$MESSAGE"
    else
        send_telegram_message "$CHAT_ID" "File $LIST_DOMAIN not found."
    fi
}

# Mengambil detail domain
get_domain_details() {
    local DOMAIN=$1
    local WHOIS_OUTPUT
    WHOIS_OUTPUT=$(whois "$DOMAIN")

    local STATUS=$(echo "$WHOIS_OUTPUT" | grep -i "Domain Status" | head -n 1 | awk '{print $3}')
    local REGISTRAR=$(echo "$WHOIS_OUTPUT" | awk -F': ' '/Registrar:|Registrar Organization:/ {print $2; exit}' | xargs)
    local REGISTRAR_URL=$(echo "$WHOIS_OUTPUT" | awk -F': ' '/Registrar URL:/ {print $2; exit}' | xargs)
    local EXPIRATION_DATE=$(echo "$WHOIS_OUTPUT" | grep -i -E "Registry Expiry Date:|Expiration Date:" | awk -F': ' '{print $2}' | xargs | head -n 1 | awk '{print $1}' | cut -d'T' -f1)

    if [[ "$STATUS" == "active" || "$STATUS" == "clientDeleteProhibited" || "$STATUS" == "clientTransferProhibited" ]]; then
        STATUS_LABEL="Active"
    else
        STATUS_LABEL="Dead"
    fi

    local EXPIRATION_EPOCH=$(date -d "$EXPIRATION_DATE" +%s)
    local CURRENT_EPOCH=$(date +%s)
    local DAYS_UNTIL_EXPIRY=$(( (EXPIRATION_EPOCH - CURRENT_EPOCH) / 86400 ))

    local MESSAGE="🔍 *Detail Domain:*%0A"
    MESSAGE+="Domain Name: *$DOMAIN*%0A"
    MESSAGE+="Status: *$STATUS_LABEL*%0A"
    MESSAGE+="Registrar: *$REGISTRAR*%0A"
    MESSAGE+="URL Registrar: *$REGISTRAR_URL*%0A"
    MESSAGE+="Expired Date: *$EXPIRATION_DATE*%0A"
    MESSAGE+="Remaining Days Until Expired: *$DAYS_UNTIL_EXPIRY days*"

    send_telegram_message "$CHAT_ID" "$MESSAGE"
    
    # Log the domain details
    #echo -e "Nama Domain: $DOMAIN\nStatus: $STATUS_LABEL\nRegistrasi: $REGISTRAR\nURL: $REGISTRAR_URL\nTanggal Expired: $EXPIRATION_DATE\nSisa Hari hingga Expired: $DAYS_UNTIL_EXPIRY hari\n" >> "$LOG_FILE"
}

# Mengirim file CSV
send_csv_download() {
    if [ -f "$LOG_FILE" ]; then
        local CSV_FILE="domain_list.csv"

        echo "Domain,Status,Registrasi,URL,Tanggal Expired,Sisa Hari hingga Expired" > "$CSV_FILE"

        grep "Domain:" "$LOG_FILE" | while read -r line; do
            local DOMAIN=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
            local DOMAIN_INFO=$(grep -A 5 "$DOMAIN" "$LOG_FILE")

            local STATUS=$(echo "$DOMAIN_INFO" | grep "Status:" | cut -d':' -f2- | xargs)
            local REGISTRASI=$(echo "$DOMAIN_INFO" | grep "Registrar:" | cut -d':' -f2 | xargs)
            local URL=$(echo "$DOMAIN_INFO" | grep "Registrar URL:" | cut -d':' -f2- | xargs)
            local TANGGAL_EXPIRED=$(echo "$DOMAIN_INFO" | grep "Expiry Date:" | cut -d':' -f2 | xargs)
            local SISA_HARI=$(echo "$DOMAIN_INFO" | grep "Days Until Expiry:" | cut -d':' -f2 | xargs)

            echo "$DOMAIN,$STATUS,\"$REGISTRASI\",$URL,$TANGGAL_EXPIRED,$SISA_HARI" >> "$CSV_FILE"
        done

        local CAPTION="☝️ Below is a list of domains in CSV format 📊"
        send_telegram_file "$CSV_FILE" "$CHAT_ID" "$CAPTION"

        rm "$CSV_FILE"
    else
        send_telegram_message "$CHAT_ID" "❌ File log not found."
    fi
}

# Mendapatkan update terbaru
updates=$(get_updates)
LAST_UPDATE_ID=$(echo "$updates" | jq '.result | last | .update_id')
LAST_SAVED_UPDATE_ID=$(cat $UPDATE_ID_FILE)

# Jika ada update baru
if [[ $LAST_UPDATE_ID -gt $LAST_SAVED_UPDATE_ID ]]; then
    echo "$LAST_UPDATE_ID" > $UPDATE_ID_FILE

    MESSAGE_TEXT=$(echo "$updates" | jq -r '.result | last | .message.text')
    COMMAND=$(echo "$MESSAGE_TEXT" | cut -d ' ' -f 1)
    DOMAIN_NAME=$(echo "$MESSAGE_TEXT" | cut -d ' ' -f 2)

    case "$COMMAND" in
        "/help")
            send_help_message "$CHAT_ID"
            ;;
        "/fulldomain")
            send_list_message "$CHAT_ID"
            ;;
        "/detailsdomain")
            if [[ -n "$DOMAIN_NAME" ]]; then
                get_domain_details "$DOMAIN_NAME"
            else
                send_telegram_message "$CHAT_ID" "Please enter the domain name after the command /detailsdomain."
            fi
            ;;
        "/downloadcsv")
            send_csv_download
            ;;
        *)
            send_telegram_message "$CHAT_ID" "Command not recognized. Use /help to see the list of commands."
            ;;
    esac
fi
