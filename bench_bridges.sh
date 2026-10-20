#!/bin/sh

TORRC="/etc/tor/torrc"
WORK_DIR="/tmp/tor_bench"
TEST_PORT="9059"
# Файл на 5 МБ от Cloudflare для замера скорости
TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"

# Где лежит основной кэш Tor (чтобы скопировать консенсус и не ждать 5 минут)
MAIN_DATA_DIR=$(grep -i "^DataDirectory" "$TORRC" | awk '{print $2}')
[ -z "$MAIN_DATA_DIR" ] && MAIN_DATA_DIR="/var/lib/tor"

echo "Начинаем тестирование мостов из $TORRC..."
echo "--------------------------------------------------------"

grep "^Bridge obfs4" "$TORRC" | while read -r bridge_line; do
    ip_port=$(echo "$bridge_line" | awk '{print $3}')
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/data"
    chmod 700 "$WORK_DIR/data"

    # Копируем кэш консенсуса, чтобы тест моста занимал 5 секунд вместо минуты
    cp -f "$MAIN_DATA_DIR"/cached-* "$WORK_DIR/data/" 2>/dev/null
    chown -R tor:tor "$WORK_DIR" 2>/dev/null

    # Генерируем минимальный конфиг для одного моста
    cat << CONF > "$WORK_DIR/torrc"
User tor
DataDirectory $WORK_DIR/data
SocksPort 127.0.0.1:$TEST_PORT
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
UseBridges 1
$bridge_line
Log notice file $WORK_DIR/tor.log
CONF

    # Запускаем тестовый экземпляр Tor в фоне
    tor -f "$WORK_DIR/torrc" >/dev/null 2>&1 &
    TOR_PID=$!

    # Ждем до 20 секунд, пока мост подключится на 100%
    bootstrapped=0
    for i in $(seq 1 20); do
        if grep -q "Bootstrapped 100%" "$WORK_DIR/tor.log" 2>/dev/null; then
            bootstrapped=1
            break
        fi
        if grep -q "general SOCKS server failure\|Connection timed out" "$WORK_DIR/tor.log" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if [ "$bootstrapped" -eq 1 ]; then
        # Замеряем скорость скачивания 5 МБ через SOCKS5
        speed_bps=$(curl --socks5-hostname "127.0.0.1:$TEST_PORT" -o /dev/null -s -w "%{speed_download}" --max-time 15 "$TEST_URL")
        # Переводим байты/сек в КБ/сек
        speed_kbps=$(awk "BEGIN {printf \"%.1f\", $speed_bps / 1024}")
        echo "[РАБОТАЕТ] $ip_port | Скорость: ${speed_kbps} KB/s (Подключился за ${i} сек)"
    else
        echo "[ОШИБКА]   $ip_port | Не прошел obfs4-рукопожатие или таймаут"
    fi

    # Убиваем тестовый процесс Tor
    kill -9 "$TOR_PID" 2>/dev/null
    wait "$TOR_PID" 2>/dev/null
done

rm -rf "$WORK_DIR"
echo "--------------------------------------------------------"
echo "Тестирование завершено."
