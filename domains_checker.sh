#!/bin/bash

# DIISIKAN SESUAI ANDA
WORKDIR="DIRECTORY_PATH" # check it with pwd
domain_file="$WORKDIR/domains.txt"
LOG_FILE="$WORKDIR/current_log.txt"
TEMP_LOG_FILE="$WORKDIR/temp_log.txt"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
NOTIFICATION_FILE="$WORKDIR/notification_log.txt"

send_telegram_message() {
    local message=$1
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TELEGRAM_CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=Markdown" > /dev/null
}

check_domain() {
    local domain=$1
    local whois_output=$(whois "$domain")
    # Ambil status lama dari log
    local old_status=$(grep -A 5 "$domain" "$LOG_FILE" | grep "Status:" | awk -F': ' '{print $2}' | xargs)
    
    # Ambil informasi domain
    local status=$(echo "$whois_output" | grep -i 'Domain Status' | head -n 1 | awk '{print $3}')
    local registrar=$(echo "$whois_output" | awk -F': ' '/Registrar:|Registrar Organization:/ {print $2; exit}' | xargs)
    local registrar_url=$(echo "$whois_output" | awk -F': ' '/Registrar URL:/ {print $2; exit}' | xargs)
    local expiry_date=$(echo "$whois_output" | grep -i -E "Registry Expiry Date:|Expiration Date:" | awk -F': ' '{print $2}' | xargs | head -n 1 | awk '{print $1}' | cut -d'T' -f1)

    if [ -n "$expiry_date" ]; then
        local expiry_epoch=$(date -d "$expiry_date" +%s)
        local current_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    else
        local days_left="N/A"
    fi

    if [[ "$status" == "active" || "$status" == "clientDeleteProhibited" || "$status" == "clientTransferProhibited" ]]; then
        status_label="Aktif"
    else
        status_label="Mati"
    fi

    echo "Domain: $domain" >> "$TEMP_LOG_FILE"
    echo "Status: $status_label" >> "$TEMP_LOG_FILE"
    echo "Registrar: ${registrar:-N/A}" >> "$TEMP_LOG_FILE"
    echo "Registrar URL: ${registrar_url:-N/A}" >> "$TEMP_LOG_FILE"
    echo "Expiry Date: ${expiry_date:-N/A}" >> "$TEMP_LOG_FILE"
    echo "Days Until Expiry: ${days_left:-N/A}" >> "$TEMP_LOG_FILE"
    echo "--------------------------------------" >> "$TEMP_LOG_FILE"

    notify_expiration "$domain" "$days_left"
    notify_day_increase "$domain" "$old_days_left" "$days_left"
    
    # Notifikasi perubahan status
    notify_status_change "$domain" "$old_status" "$status_label"
}

compare_logs() {
    if [ -f "$LOG_FILE" ]; then
        ADDED_DOMAINS=$(grep -F -x -v -f "$LOG_FILE" "$TEMP_LOG_FILE" | grep "Domain:" | awk -F': ' '{print $2}')
        REMOVED_DOMAINS=$(grep -F -x -v -f "$TEMP_LOG_FILE" "$LOG_FILE" | grep "Domain:" | awk -F': ' '{print $2}')
        if [ -n "$ADDED_DOMAINS" ]; then
            send_telegram_message "📋 Domain yang ditambahkan ✅%0A*$ADDED_DOMAINS*"
        fi
        if [ -n "$REMOVED_DOMAINS" ]; then
            send_telegram_message "📋 Domain yang dihapus ❌%0A*$REMOVED_DOMAINS*"
        fi
    fi
}

notify_expiration() {
    local DOMAIN="$1"
    local DAYS="$2"
    local TODAY=$(date +%Y-%m-%d)

    if [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        LAST_NOTIFICATION_DATE=$(grep -E "^$DOMAIN " "$NOTIFICATION_FILE" | awk '{print $2}')
        if [[ "$LAST_NOTIFICATION_DATE" != "$TODAY" ]]; then
            if [ "$DAYS" -lt 4 ] || [ "$DAYS" -eq 7 ] || [ "$DAYS" -eq 30 ]; then
                send_telegram_message "⚠️ Domain *$DOMAIN* ⚠️%0AAkan kedaluwarsa dalam *$DAYS hari*! "
            fi
            if [[ -n "$LAST_NOTIFICATION_DATE" ]]; then
                sed -i "/^$DOMAIN /d" "$NOTIFICATION_FILE"  # Hapus entri lama
            fi
            echo "$DOMAIN $TODAY" >> "$NOTIFICATION_FILE"
        fi
    fi
}

notify_day_increase() {
    local DOMAIN="$1"
    local OLD_DAYS="$2"
    local NEW_DAYS="$3"

    if [[ "$OLD_DAYS" =~ ^[0-9]+$ ]] && [[ "$NEW_DAYS" =~ ^[0-9]+$ ]]; then
        local DIFF=$(( NEW_DAYS - OLD_DAYS ))

        if [ "$DIFF" -gt 0 ]; then
            local TOTAL_DAYS=$(( OLD_DAYS + DIFF ))
            send_telegram_message "✅ *$DOMAIN* ✅%0AMengalami perpanjangan *$DIFF hari*%0ADan total sisa hari hingga kadaluarsa adalah *$TOTAL_DAYS hari*!"
        fi
    fi
}

notify_status_change() {
    local DOMAIN="$1"
    local OLD_STATUS="$2"
    local NEW_STATUS="$3"

    if [[ "$OLD_STATUS" != "$NEW_STATUS" ]]; then
        if [[ "$NEW_STATUS" == "Aktif" ]]; then
            send_telegram_message "✅ Domain *$DOMAIN* sekarang dalam status *Aktif*! 🎉"
        else
            send_telegram_message "❌ Domain *$DOMAIN* sekarang dalam status *Mati*! ⚠️"
        fi
    fi
}

create_and_send_csv() {
    local TODAY=$(date +%Y-%m-%d)
    local LAST_CSV_MONTH=$(grep -E "^csv_sent " "$NOTIFICATION_FILE" | awk '{print $2}')

    if [[ -z "$LAST_CSV_MONTH" ]] || [[ "$(date -d "$TODAY" +%m)" != "$(date -d "$LAST_CSV_MONTH" +%m)" ]] || [[ "$(date -d "$TODAY" +%Y)" != "$(date -d "$LAST_CSV_MONTH" +%Y)" ]]; then
        local CSV_FILE="$WORKDIR/domain_report_$TODAY.csv"
        echo "Nama Domain,Status,Registrasi,URL Registrasi,Tanggal Expired,Sisa Hari hingga Expired" > "$CSV_FILE"

        while IFS= read -r DOMAIN; do
            DOMAIN_INFO=$(grep -A 5 "$DOMAIN" "$LOG_FILE")

            # Ambil masing-masing informasi dengan benar
            local STATUS=$(echo "$DOMAIN_INFO" | grep "Status:" | cut -d':' -f2- | xargs)
            local REGISTRASI=$(echo "$DOMAIN_INFO" | grep "Registrar:" | cut -d':' -f2- | xargs)
            local URL=$(echo "$DOMAIN_INFO" | grep "Registrar URL:" | cut -d':' -f2- | xargs)
            local TANGGAL_EXPIRED=$(echo "$DOMAIN_INFO" | grep "Expiry Date:" | cut -d':' -f2- | xargs)
            local SISA_HARI=$(echo "$DOMAIN_INFO" | grep "Days Until Expiry:" | cut -d':' -f2- | xargs)

            # Tulis ke file CSV
            echo "$DOMAIN,$STATUS,\"$REGISTRASI\",$URL,$TANGGAL_EXPIRED,$SISA_HARI" >> "$CSV_FILE"
        done < "$domain_file"

        send_telegram_message "📊 Laporan domain terbaru telah dibuat dan dilampirkan."
        curl -F document=@"$CSV_FILE" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID"

        # Menghapus file CSV yang lebih lama jika jumlahnya lebih dari 10
        local csv_count=$(ls -1 "$WORKDIR"/domain_report_*.csv 2>/dev/null | wc -l)
        if [ "$csv_count" -ge 10 ]; then
            oldest_csv=$(ls -1t "$WORKDIR"/domain_report_*.csv | tail -1)
            rm "$oldest_csv"
        fi

        sed -i "/^csv_sent /d" "$NOTIFICATION_FILE"
        echo "csv_sent $TODAY" >> "$NOTIFICATION_FILE"
    fi
}

if [ -f "$domain_file" ]; then
    > "$TEMP_LOG_FILE"
    while IFS= read -r domain; do
        check_domain "$domain"
    done < "$domain_file"

    compare_logs

    mv "$TEMP_LOG_FILE" "$LOG_FILE"

    create_and_send_csv
else
    echo "File '$domain_file' tidak ditemukan!"
fi
