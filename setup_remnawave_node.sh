#!/bin/bash

#####################################################
# Скрипт автоматической настройки Remnawave Node
# Включает: системные обновления, NetBird, Docker,
#           мониторинг (cAdvisor, Node Exporter, vmagent),
#           настройку UFW Firewall
#
# Поддерживает запуск через pipe благодаря /dev/tty:
#   curl ... | sudo bash
#   sudo bash <(curl ...)
#####################################################

set -e  # Остановить выполнение при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Параметры
NETBIRD_SETUP_KEY=""
PROJECT_DIR="/opt/remnanode"
MONITORING_DIR="/opt/monitoring"
LOG_FILE="/var/log/remnawave_setup.log"

# Версии компонентов мониторинга
CADVISOR_VERSION="0.55.1"
NODE_EXPORTER_VERSION="1.9.1"
VMAGENT_VERSION="1.123.0"

# Параметры мониторинга (будут запрошены у пользователя)
INSTANCE_NAME=""
VICTORIA_METRICS_URL=""
NODE_PORT=""
PANEL_IP=""
XRAY_PORT=""

# Функция логирования
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

# Проверка прав sudo
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен запускаться с правами root или через sudo"
        exit 1
    fi
}

# Запрос параметров мониторинга
ask_monitoring_params() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Настройка параметров мониторинга и безопасности          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Запрашиваем NetBird Setup Key
    while [[ -z "$NETBIRD_SETUP_KEY" ]]; do
        read -p "$(echo -e ${YELLOW}Введите NetBird Setup Key ${GREEN}\(получить в панели NetBird\)${NC}: )" NETBIRD_SETUP_KEY < /dev/tty
        if [[ -z "$NETBIRD_SETUP_KEY" ]]; then
            echo -e "${RED}NetBird Setup Key не может быть пустым!${NC}"
        fi
    done
    
    # Запрашиваем название инстанса
    while [[ -z "$INSTANCE_NAME" ]]; do
        read -p "$(echo -e ${YELLOW}Введите название инстанса/сервера ${GREEN}\(например: de-node-01\)${NC}: )" INSTANCE_NAME < /dev/tty
        if [[ -z "$INSTANCE_NAME" ]]; then
            echo -e "${RED}Название инстанса не может быть пустым!${NC}"
        fi
    done
    
    # Запрашиваем URL Victoria Metrics с валидацией формата
    while [[ -z "$VICTORIA_METRICS_URL" ]]; do
        read -p "$(echo -e ${YELLOW}Введите IP/URL Victoria Metrics ${GREEN}\(например: 10.0.0.1 или http://10.0.0.1:8428\)${NC}: )" vm_input < /dev/tty
        if [[ -z "$vm_input" ]]; then
            echo -e "${RED}URL Victoria Metrics не может быть пустым!${NC}"
            continue
        fi
        
        # Проверяем и форматируем URL
        if [[ "$vm_input" =~ ^https?:// ]]; then
            # URL уже содержит протокол
            if [[ "$vm_input" =~ :8428 ]]; then
                # Протокол и порт уже есть
                VICTORIA_METRICS_URL="$vm_input"
            else
                # Есть протокол, но нет порта - добавляем порт
                VICTORIA_METRICS_URL="${vm_input}:8428"
            fi
        else
            # Только IP или hostname - добавляем протокол и порт
            VICTORIA_METRICS_URL="http://${vm_input}:8428"
        fi
        
        log_info "Сформирован URL: $VICTORIA_METRICS_URL"
    done
    
    # Запрашиваем порт ноды для связи с панелью
    read -p "$(echo -e ${YELLOW}Введите NODE_PORT для связи с панелью ${GREEN}\(по умолчанию: 2222\)${NC}: )" node_port_input < /dev/tty
    if [[ -z "$node_port_input" ]]; then
        NODE_PORT="2222"
        log_info "Используется порт по умолчанию: $NODE_PORT"
    else
        NODE_PORT="$node_port_input"
    fi
    
    # Запрашиваем порт Xray
    read -p "$(echo -e ${YELLOW}Введите XRAY_PORT для входящих подключений ${GREEN}\(по умолчанию: 443\)${NC}: )" xray_port_input < /dev/tty
    if [[ -z "$xray_port_input" ]]; then
        XRAY_PORT="443"
        log_info "Используется порт по умолчанию для Xray: $XRAY_PORT"
    else
        XRAY_PORT="$xray_port_input"
    fi
    
    # Запрашиваем IP панели Remnawave
    while [[ -z "$PANEL_IP" ]]; do
        read -p "$(echo -e ${YELLOW}Введите IP адрес панели Remnawave ${GREEN}\(для настройки firewall\)${NC}: )" PANEL_IP < /dev/tty
        if [[ -z "$PANEL_IP" ]]; then
            echo -e "${RED}IP панели не может быть пустым!${NC}"
        fi
    done
    
    echo ""
    log_info "NetBird Setup Key: ${GREEN}[СКРЫТ]${NC}"
    log_info "Название инстанса: $INSTANCE_NAME"
    log_info "Victoria Metrics URL: $VICTORIA_METRICS_URL"
    log_info "NODE_PORT: $NODE_PORT"
    log_info "XRAY_PORT: $XRAY_PORT"
    log_info "IP панели Remnawave: $PANEL_IP"
    echo ""
}

# Шаг 1: Обновление системы
update_system() {
    log "Шаг 1/4: Обновление системных пакетов..."
    if apt update && apt upgrade -y >> "$LOG_FILE" 2>&1; then
        log "✓ Система успешно обновлена"
    else
        log_error "Ошибка при обновлении системы"
        exit 1
    fi
}

# Шаг 2: Установка NetBird
install_netbird() {
    log "Шаг 2/4: Установка NetBird..."
    
    if command -v netbird &> /dev/null; then
        log_warning "NetBird уже установлен, пропускаем установку"
        NETBIRD_VERSION=$(netbird version 2>/dev/null | head -n1 || echo "unknown")
        log_info "Текущая версия: $NETBIRD_VERSION"
    else
        if curl -fsSL https://pkgs.netbird.io/install.sh | sh >> "$LOG_FILE" 2>&1; then
            log "✓ NetBird успешно установлен"
        else
            log_error "Ошибка при установке NetBird"
            exit 1
        fi
    fi
}

# Шаг 3: Подключение к NetBird
setup_netbird() {
    log "Шаг 3/4: Подключение к NetBird mesh-сети..."
    
    # Проверяем, подключен ли уже NetBird
    if netbird status 2>/dev/null | grep -q "Connected"; then
        log_warning "NetBird уже подключен к сети"
        netbird status
    else
        if netbird up --setup-key "$NETBIRD_SETUP_KEY" >> "$LOG_FILE" 2>&1; then
            log "✓ NetBird успешно подключен"
            log_info "Статус NetBird:"
            netbird status | tee -a "$LOG_FILE"
        else
            log_error "Ошибка при подключении NetBird"
            exit 1
        fi
    fi
}

# Шаг 4: Установка Docker
install_docker() {
    log "Шаг 4/4: Установка Docker..."
    
    if command -v docker &> /dev/null; then
        log_warning "Docker уже установлен, пропускаем установку"
        DOCKER_VERSION=$(docker --version)
        log_info "$DOCKER_VERSION"
    else
        if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
            log "✓ Docker успешно установлен"
            
            # Добавляем текущего пользователя в группу docker (если скрипт запущен через sudo)
            if [ -n "$SUDO_USER" ]; then
                usermod -aG docker "$SUDO_USER"
                log_info "Пользователь $SUDO_USER добавлен в группу docker"
                log_warning "Необходимо выйти и войти снова для применения прав docker"
            fi
        else
            log_error "Ошибка при установке Docker"
            exit 1
        fi
    fi
}

# Создание директории проекта
create_project_dir() {
    log "Создание директории проекта..."
    
    if [ -d "$PROJECT_DIR" ]; then
        log_warning "Директория $PROJECT_DIR уже существует"
    else
        if mkdir -p "$PROJECT_DIR"; then
            log "✓ Создана директория: $PROJECT_DIR"
        else
            log_error "Не удалось создать директорию $PROJECT_DIR"
            exit 1
        fi
    fi
}

# Шаг 5: Создание директорий для мониторинга
create_monitoring_dirs() {
    log "Шаг 5/9: Создание директорий для мониторинга..."
    
    if mkdir -p "$MONITORING_DIR"/{cadvisor,nodeexporter,vmagent/conf.d} >> "$LOG_FILE" 2>&1; then
        log "✓ Созданы директории для мониторинга"
    else
        log_error "Ошибка при создании директорий мониторинга"
        exit 1
    fi
}

# Шаг 6: Установка cAdvisor
install_cadvisor() {
    log "Шаг 6/9: Установка cAdvisor v${CADVISOR_VERSION}..."
    
    cd "$MONITORING_DIR/cadvisor" || exit 1
    
    if [ -f "cadvisor" ]; then
        log_warning "cAdvisor уже установлен"
    else
        if wget -q "https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-amd64" >> "$LOG_FILE" 2>&1; then
            mv "cadvisor-v${CADVISOR_VERSION}-linux-amd64" cadvisor
            chmod +x cadvisor
            log "✓ cAdvisor v${CADVISOR_VERSION} успешно установлен"
        else
            log_error "Ошибка при скачивании cAdvisor"
            exit 1
        fi
    fi
}

# Шаг 7: Установка Node Exporter
install_node_exporter() {
    log "Шаг 7/9: Установка Node Exporter v${NODE_EXPORTER_VERSION}..."
    
    cd "$MONITORING_DIR/nodeexporter" || exit 1
    
    if [ -f "node_exporter" ]; then
        log_warning "Node Exporter уже установлен"
    else
        local archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
        
        if wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${archive}" >> "$LOG_FILE" 2>&1; then
            tar -xzf "$archive" >> "$LOG_FILE" 2>&1
            mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" .
            chmod +x node_exporter
            rm -rf "$archive" "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
            log "✓ Node Exporter v${NODE_EXPORTER_VERSION} успешно установлен"
        else
            log_error "Ошибка при скачивании Node Exporter"
            exit 1
        fi
    fi
}

# Шаг 8: Установка VictoriaMetrics Agent
install_vmagent() {
    log "Шаг 8/9: Установка VictoriaMetrics Agent v${VMAGENT_VERSION}..."
    
    cd "$MONITORING_DIR/vmagent" || exit 1
    
    if [ -f "vmagent" ]; then
        log_warning "VictoriaMetrics Agent уже установлен"
    else
        local archive="vmutils-linux-amd64-v${VMAGENT_VERSION}.tar.gz"
        
        if wget -q "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/${archive}" >> "$LOG_FILE" 2>&1; then
            tar -xzf "$archive" >> "$LOG_FILE" 2>&1
            mv vmagent-prod vmagent
            find . ! -name 'vmagent' ! -name 'conf.d' -type f -delete
            chmod +x vmagent
            log "✓ VictoriaMetrics Agent v${VMAGENT_VERSION} успешно установлен"
        else
            log_error "Ошибка при скачивании VictoriaMetrics Agent"
            exit 1
        fi
    fi
}

# Шаг 9: Создание конфигурационных файлов
create_monitoring_configs() {
    log "Шаг 9/9: Создание конфигурационных файлов мониторинга..."
    
    # Создаем основной конфиг vmagent
    cat > "$MONITORING_DIR/vmagent/scrape.yml" << EOF
scrape_config_files:
  - "/opt/monitoring/vmagent/conf.d/*.yml"
global:
  scrape_interval: 15s
EOF
    log_info "✓ Создан файл scrape.yml"
    
    # Создаем конфиг для cAdvisor
    cat > "$MONITORING_DIR/vmagent/conf.d/cadvisor.yml" << EOF
- job_name: integrations/cAdvisor
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9101']
      labels:
        instance: "$INSTANCE_NAME"
EOF
    log_info "✓ Создан файл cadvisor.yml"
    
    # Создаем конфиг для Node Exporter
    cat > "$MONITORING_DIR/vmagent/conf.d/nodeexporter.yml" << EOF
- job_name: integrations/node_exporter
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9100']
      labels:
        instance: "$INSTANCE_NAME"
EOF
    log_info "✓ Создан файл nodeexporter.yml"
    
    # Создаем systemd service для cAdvisor
    cat > /etc/systemd/system/cadvisor.service << EOF
[Unit]
Description=cAdvisor
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/cadvisor/cadvisor \\
        -listen_ip=127.0.0.1 \\
        -logtostderr \\
        -port=9101 \\
        -docker_only=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ Создан systemd service для cAdvisor"
    
    # Создаем systemd service для Node Exporter
    cat > /etc/systemd/system/nodeexporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ Создан systemd service для Node Exporter"
    
    # Создаем systemd service для vmagent
    cat > /etc/systemd/system/vmagent.service << EOF
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/vmagent/vmagent \\
      -httpListenAddr=127.0.0.1:8429 \\
      -promscrape.config=/opt/monitoring/vmagent/scrape.yml \\
      -promscrape.configCheckInterval=60s \\
      -remoteWrite.url=${VICTORIA_METRICS_URL}/api/v1/write
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ Создан systemd service для vmagent"
    
    log "✓ Все конфигурационные файлы созданы"
}

# Запуск сервисов мониторинга
start_monitoring_services() {
    log "Запуск сервисов мониторинга..."
    
    if systemctl daemon-reload >> "$LOG_FILE" 2>&1; then
        log_info "✓ systemd daemon перезагружен"
    else
        log_error "Ошибка при перезагрузке systemd daemon"
        exit 1
    fi
    
    if systemctl enable cadvisor nodeexporter vmagent >> "$LOG_FILE" 2>&1; then
        log_info "✓ Сервисы добавлены в автозагрузку"
    else
        log_error "Ошибка при добавлении сервисов в автозагрузку"
        exit 1
    fi
    
    if systemctl start cadvisor nodeexporter vmagent >> "$LOG_FILE" 2>&1; then
        log "✓ Сервисы мониторинга успешно запущены"
    else
        log_error "Ошибка при запуске сервисов мониторинга"
        exit 1
    fi
    
    # Проверяем статус сервисов
    echo ""
    log_info "Статус сервисов мониторинга:"
    systemctl status cadvisor --no-pager | head -n 3 | tee -a "$LOG_FILE"
    systemctl status nodeexporter --no-pager | head -n 3 | tee -a "$LOG_FILE"
    systemctl status vmagent --no-pager | head -n 3 | tee -a "$LOG_FILE"
}

# Настройка UFW firewall
configure_firewall() {
    log "Настройка UFW firewall..."
    
    # Устанавливаем UFW если не установлен
    if ! command -v ufw &> /dev/null; then
        log_info "UFW не установлен, устанавливаем..."
        if apt install -y ufw >> "$LOG_FILE" 2>&1; then
            log_info "✓ UFW успешно установлен"
        else
            log_error "Ошибка при установке UFW"
            exit 1
        fi
    else
        log_info "UFW уже установлен"
    fi
    
    # Разрешаем OpenSSH (чтобы не потерять доступ)
    if ufw allow OpenSSH >> "$LOG_FILE" 2>&1; then
        log_info "✓ Разрешен доступ OpenSSH"
    else
        log_warning "Не удалось добавить правило для OpenSSH"
    fi
    
    # Разрешаем доступ с IP панели на NODE_PORT
    if ufw allow from "$PANEL_IP" to any port "$NODE_PORT" comment "Remnawave Panel access" >> "$LOG_FILE" 2>&1; then
        log_info "✓ Разрешен доступ с $PANEL_IP на порт $NODE_PORT"
    else
        log_error "Ошибка при добавлении правила для панели"
        exit 1
    fi
    
    # Разрешаем XRAY_PORT для входящих VPN подключений
    if ufw allow "$XRAY_PORT"/tcp comment "Xray incoming connections" >> "$LOG_FILE" 2>&1; then
        log_info "✓ Разрешен порт $XRAY_PORT для Xray (входящие подключения)"
    else
        log_error "Ошибка при добавлении правила для Xray"
        exit 1
    fi
    
    # Включаем UFW
    log_warning "Включаем UFW firewall..."
    echo "y" | ufw enable >> "$LOG_FILE" 2>&1
    
    if ufw status | grep -q "Status: active"; then
        log "✓ UFW firewall успешно настроен и активирован"
        echo ""
        log_info "Текущие правила UFW:"
        ufw status numbered | tee -a "$LOG_FILE"
    else
        log_error "Ошибка при активации UFW"
        exit 1
    fi
}

# Получение NetBird IP
get_netbird_ip() {
    log "Получение NetBird IP адреса..."
    
    # Пытаемся получить IP из netbird status
    NETBIRD_IP=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[0-9.]+' || echo "")
    
    if [[ -z "$NETBIRD_IP" ]]; then
        # Пробуем альтернативный способ
        NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
    fi
    
    if [[ -n "$NETBIRD_IP" ]]; then
        log "✓ NetBird IP: ${GREEN}$NETBIRD_IP${NC}"
    else
        log_warning "Не удалось автоматически определить NetBird IP"
        log_info "Используйте команду: netbird status"
    fi
}

# Финальные инструкции
show_next_steps() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Установка базовых компонентов завершена успешно!          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}🌐 Сетевая информация:${NC}"
    if [[ -n "$NETBIRD_IP" ]]; then
        echo -e "   📍 NetBird IP: ${GREEN}$NETBIRD_IP${NC} ${YELLOW}← Используйте этот IP в панели Remnawave!${NC}"
    else
        echo -e "   ⚠️  NetBird IP не определен, проверьте: ${YELLOW}netbird status${NC}"
    fi
    echo ""
    echo -e "${BLUE}📊 Установленные компоненты мониторинга:${NC}"
    echo -e "   ✓ cAdvisor v${CADVISOR_VERSION} (порт 9101)"
    echo -e "   ✓ Node Exporter v${NODE_EXPORTER_VERSION} (порт 9100)"
    echo -e "   ✓ VictoriaMetrics Agent v${VMAGENT_VERSION} (порт 8429)"
    echo -e "   📍 Instance: ${GREEN}$INSTANCE_NAME${NC}"
    echo -e "   🔗 Remote Write: ${GREEN}$VICTORIA_METRICS_URL${NC}"
    echo ""
    echo -e "${BLUE}🔒 Настройки безопасности:${NC}"
    echo -e "   ✓ UFW Firewall активирован"
    echo -e "   ✓ Доступ разрешен: OpenSSH"
    echo -e "   ✓ Доступ с панели: $PANEL_IP → порт $NODE_PORT"
    echo -e "   ✓ Порт Xray: $XRAY_PORT (входящие VPN подключения)"
    echo ""
    echo -e "${BLUE}Следующие шаги для завершения настройки Remnawave Node:${NC}"
    echo ""
    echo -e "${YELLOW}1.${NC} Перейдите в панель Remnawave:"
    echo -e "   Nodes → Management → нажмите кнопку ${GREEN}+${NC}"
    echo ""
    echo -e "${YELLOW}2.${NC} Заполните форму создания ноды:"
    echo -e "   Node Address: ${GREEN}$NETBIRD_IP${NC}"
    echo -e "   Node Port: ${GREEN}$NODE_PORT${NC}"
    echo -e "   Скопируйте docker-compose.yml"
    echo ""
    echo -e "${YELLOW}3.${NC} Создайте файл конфигурации:"
    echo -e "   ${GREEN}cd $PROJECT_DIR && nano docker-compose.yml${NC}"
    echo ""
    echo -e "${YELLOW}4.${NC} Запустите контейнер:"
    echo -e "   ${GREEN}docker compose up -d && docker compose logs -f -t${NC}"
    echo ""
    echo -e "${YELLOW}5.${NC} В панели нажмите 'Next', выберите Config Profile и нажмите 'Create'"
    echo ""
    echo -e "${BLUE}🔍 Проверка мониторинга:${NC}"
    echo -e "   systemctl status cadvisor nodeexporter vmagent"
    echo -e "   journalctl -u vmagent -f  ${GREEN}# логи vmagent${NC}"
    echo ""
    echo -e "${BLUE}🔍 Проверка firewall:${NC}"
    echo -e "   ufw status numbered"
    echo ""
    echo -e "${BLUE}📝 Лог установки:${NC} $LOG_FILE"
    echo -e "${BLUE}📁 Директория проекта:${NC} $PROJECT_DIR"
    echo -e "${BLUE}📁 Директория мониторинга:${NC} $MONITORING_DIR"
    echo ""
}

# Основная функция
main() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Начало установки Remnawave Node с мониторингом${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Создаем лог-файл если его нет
    touch "$LOG_FILE"
    
    check_root
    ask_monitoring_params
    
    update_system
    install_netbird
    setup_netbird
    install_docker
    create_project_dir
    
    # Установка компонентов мониторинга
    create_monitoring_dirs
    install_cadvisor
    install_node_exporter
    install_vmagent
    create_monitoring_configs
    start_monitoring_services
    
    # Настройка безопасности
    configure_firewall
    
    # Получение NetBird IP для удобства
    get_netbird_ip
    
    show_next_steps
}

# Запуск скрипта
main
