#!/bin/bash

#####################################################
# Скрипт проверки статуса мониторинга Remnawave Node
#####################################################

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Статус мониторинга Remnawave Node${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Проверка статуса сервисов
echo -e "${GREEN}📊 Статус сервисов:${NC}"
echo ""

services=("cadvisor" "nodeexporter" "vmagent")

for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        status="${GREEN}✓ Активен${NC}"
        uptime=$(systemctl show "$service" --property=ActiveEnterTimestamp --value)
    else
        status="${RED}✗ Неактивен${NC}"
        uptime="N/A"
    fi
    
    echo -e "${YELLOW}$service:${NC} $status"
    if [ "$uptime" != "N/A" ]; then
        echo -e "  Запущен: $uptime"
    fi
    
    # Показываем последние 3 строки логов
    echo -e "  ${BLUE}Последние логи:${NC}"
    journalctl -u "$service" -n 3 --no-pager | sed 's/^/    /'
    echo ""
done

# Проверка портов
echo -e "${GREEN}🔌 Проверка портов:${NC}"
echo ""

ports=("9100:Node Exporter" "9101:cAdvisor" "8429:vmagent")

for port_info in "${ports[@]}"; do
    IFS=':' read -r port name <<< "$port_info"
    if ss -tlnp | grep -q ":$port "; then
        echo -e "${GREEN}✓${NC} Порт $port ($name) - ${GREEN}СЛУШАЕТ${NC}"
    else
        echo -e "${RED}✗${NC} Порт $port ($name) - ${RED}НЕ СЛУШАЕТ${NC}"
    fi
done

echo ""

# Проверка конфигурации vmagent
echo -e "${GREEN}⚙️  Конфигурация vmagent:${NC}"
echo ""

if [ -f "/opt/monitoring/vmagent/scrape.yml" ]; then
    echo -e "${BLUE}scrape.yml:${NC}"
    cat /opt/monitoring/vmagent/scrape.yml | sed 's/^/  /'
    echo ""
fi

if [ -f "/opt/monitoring/vmagent/conf.d/cadvisor.yml" ]; then
    echo -e "${BLUE}cadvisor.yml:${NC}"
    cat /opt/monitoring/vmagent/conf.d/cadvisor.yml | sed 's/^/  /'
    echo ""
fi

if [ -f "/opt/monitoring/vmagent/conf.d/nodeexporter.yml" ]; then
    echo -e "${BLUE}nodeexporter.yml:${NC}"
    cat /opt/monitoring/vmagent/conf.d/nodeexporter.yml | sed 's/^/  /'
    echo ""
fi

# Проверка UFW firewall
echo -e "${GREEN}🔒 Статус UFW Firewall:${NC}"
echo ""

if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo -e "${GREEN}✓${NC} UFW активен"
        echo ""
        echo -e "${BLUE}Правила UFW:${NC}"
        ufw status numbered | sed 's/^/  /'
    else
        echo -e "${RED}✗${NC} UFW неактивен"
    fi
else
    echo -e "${YELLOW}⚠${NC}  UFW не установлен"
fi

echo ""

# Проверка NetBird
echo -e "${GREEN}🌐 Статус NetBird:${NC}"
echo ""

if command -v netbird &> /dev/null; then
    if netbird status 2>/dev/null | grep -q "Connected"; then
        echo -e "${GREEN}✓${NC} NetBird подключен"
        echo ""
        
        # Пытаемся получить IP
        NETBIRD_IP=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[0-9.]+' || echo "")
        
        if [[ -z "$NETBIRD_IP" ]]; then
            NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
        fi
        
        if [[ -n "$NETBIRD_IP" ]]; then
            echo -e "${BLUE}NetBird IP:${NC} ${GREEN}$NETBIRD_IP${NC}"
        else
            echo -e "${YELLOW}⚠${NC}  Не удалось определить NetBird IP"
        fi
        
        echo ""
        echo -e "${BLUE}Полный статус:${NC}"
        netbird status | sed 's/^/  /'
    else
        echo -e "${RED}✗${NC} NetBird не подключен"
        echo -e "  Используйте: ${YELLOW}sudo netbird up${NC}"
    fi
else
    echo -e "${RED}✗${NC} NetBird не установлен"
fi

echo ""

# Полезные команды
echo -e "${GREEN}📝 Полезные команды:${NC}"
echo ""
echo -e "  Просмотр логов в реальном времени:"
echo -e "    ${YELLOW}journalctl -u vmagent -f${NC}"
echo -e "    ${YELLOW}journalctl -u cadvisor -f${NC}"
echo -e "    ${YELLOW}journalctl -u nodeexporter -f${NC}"
echo ""
echo -e "  Перезапуск сервисов:"
echo -e "    ${YELLOW}systemctl restart cadvisor nodeexporter vmagent${NC}"
echo ""
echo -e "  Проверка конфигурации vmagent:"
echo -e "    ${YELLOW}cat /etc/systemd/system/vmagent.service${NC}"
echo ""
echo -e "  Управление UFW:"
echo -e "    ${YELLOW}ufw status verbose${NC}"
echo -e "    ${YELLOW}ufw allow from [IP] to any port [PORT]${NC}"
echo ""
echo -e "  Проверка NetBird:"
echo -e "    ${YELLOW}netbird status${NC}"
echo -e "    ${YELLOW}netbird list${NC}"
echo ""
