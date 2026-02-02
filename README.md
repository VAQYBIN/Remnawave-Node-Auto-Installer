# Скрипты автоматизации развертывания Remnawave Node

[![GitHub release](https://img.shields.io/badge/version-v2.1-blue.svg)](https://github.com/VAQYBIN/Remnawave-Node-Auto-Installer/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

Автоматическая установка и настройка Remnawave Node с полным стеком мониторинга (cAdvisor, Node Exporter, VictoriaMetrics Agent) и настройкой безопасности (UFW Firewall).

---

## 🔑 Подготовка к установке

### Получение NetBird Setup Key

Перед запуском скрипта получите NetBird Setup Key:

1. Войдите в [панель NetBird](https://app.netbird.io/)
2. Перейдите в раздел **Setup Keys**
3. Нажмите **Create Setup Key**
4. Настройте параметры ключа:
   - Name: `remnawave-nodes` (или любое имя)
   - Expires: выберите срок действия
   - Auto-groups: (опционально) выберите группы
5. Скопируйте созданный ключ

**⚠️ Важно:** Ключ будет показан только один раз. Сохраните его в безопасном месте!

---

## 📦 Состав

1. **setup_remnawave_node.sh** - Основной скрипт установки
2. **check_monitoring_status.sh** - Скрипт проверки статуса мониторинга

---

## 🚀 Быстрый старт

### Вариант 1: Одной командой через pipe (рекомендуется)

```bash
curl -fsSL https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/setup_remnawave_node.sh | sudo bash
```

### Вариант 2: Скачать и запустить (безопаснее)

```bash
# Скачать скрипт
curl -fsSL https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/setup_remnawave_node.sh -o setup_remnawave_node.sh

# Просмотреть содержимое (опционально)
less setup_remnawave_node.sh

# Сделать исполняемым и запустить
chmod +x setup_remnawave_node.sh
sudo ./setup_remnawave_node.sh
```

### Вариант 3: Через wget

```bash
# Одной командой
wget -qO- https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/setup_remnawave_node.sh | sudo bash

# Или скачать и запустить
wget https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/setup_remnawave_node.sh
chmod +x setup_remnawave_node.sh
sudo ./setup_remnawave_node.sh
```

**💡 Совет:** Все варианты поддерживают интерактивный ввод благодаря использованию `/dev/tty`.

### Скрипт проверки статуса

```bash
# Скачать скрипт проверки
curl -fsSL https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/check_monitoring_status.sh -o check_monitoring_status.sh
chmod +x check_monitoring_status.sh

# Запустить проверку
sudo ./check_monitoring_status.sh
```

---

## 📋 setup_remnawave_node.sh

### Что устанавливает:

#### Базовые компоненты:
1. ✅ Обновление системы (apt update && apt upgrade)
2. 🔗 NetBird VPN mesh-сеть
3. 🐳 Docker & Docker Compose
4. 📁 Создание рабочей директории `/opt/remnanode`

#### Мониторинг (Stack):
5. 📊 **cAdvisor v0.55.1** - Метрики контейнеров Docker
6. 📈 **Node Exporter v1.9.1** - Системные метрики сервера
7. 🔍 **VictoriaMetrics Agent v1.123.0** - Сбор и отправка метрик

### Интерактивные параметры:

При запуске скрипт запросит:
- **NetBird Setup Key** (получить в панели NetBird: https://app.netbird.io/)
- **Название инстанса** (например: `de-node-01`, `ru-moscow-01`)
- **IP/URL Victoria Metrics** (например: `10.0.0.1` или `http://10.0.0.1:8428` - формат будет автоматически проверен)
- **NODE_PORT для связи с панелью** (по умолчанию: `2222`)
- **XRAY_PORT для входящих VPN подключений** (по умолчанию: `443`)
- **IP адрес панели Remnawave** (для настройки firewall)

### Что настраивается автоматически:

**🔒 Безопасность (UFW Firewall):**
- Разрешается OpenSSH (чтобы не потерять доступ)
- Разрешается доступ с IP панели на NODE_PORT
- UFW автоматически активируется

**🌐 NetBird:**
- После установки автоматически определяется и выводится NetBird IP
- Этот IP нужно использовать в панели Remnawave при создании ноды

### Структура директорий после установки:

```
/opt/
├── remnanode/              # Директория для docker-compose.yml Remnawave
└── monitoring/
    ├── cadvisor/
    │   └── cadvisor        # Бинарник cAdvisor
    ├── nodeexporter/
    │   └── node_exporter   # Бинарник Node Exporter
    └── vmagent/
        ├── vmagent         # Бинарник vmagent
        ├── scrape.yml      # Основной конфиг
        └── conf.d/
            ├── cadvisor.yml       # Job для cAdvisor
            └── nodeexporter.yml   # Job для Node Exporter
```

### Systemd сервисы:

После установки будут созданы и запущены:
- `cadvisor.service` - слушает на `127.0.0.1:9101`
- `nodeexporter.service` - слушает на `127.0.0.1:9100`
- `vmagent.service` - слушает на `127.0.0.1:8429`

Все сервисы добавлены в автозагрузку через `systemctl enable`.

### Логирование:

Все действия логируются в: `/var/log/remnawave_setup.log`

### Безопасность:

- ✅ Проверка прав root перед запуском
- ✅ Остановка при любой ошибке (`set -e`)
- ✅ Идемпотентность - можно запускать повторно
- ✅ Все метрики доступны только на localhost
- ✅ Проверка уже установленных компонентов

---

## 🔍 check_monitoring_status.sh

### Назначение:

Быстрая проверка состояния всего стека мониторинга.

### Что проверяет:

1. **Статус systemd сервисов** - активны ли cadvisor, nodeexporter, vmagent
2. **Время запуска** - когда каждый сервис был запущен
3. **Последние логи** - 3 последние записи из journalctl для каждого сервиса
4. **Проверка портов** - слушают ли процессы на нужных портах (9100, 9101, 8429)
5. **Конфигурация vmagent** - содержимое всех конфигов

### Использование:

```bash
# Простой запуск
sudo ./check_monitoring_status.sh

# Или если скрипт в PATH
sudo check_monitoring_status.sh
```

### Пример вывода:

```
═══════════════════════════════════════════════════════════
   Статус мониторинга Remnawave Node
═══════════════════════════════════════════════════════════

📊 Статус сервисов:

cadvisor: ✓ Активен
  Запущен: Sun 2025-02-02 15:30:22 UTC
  Последние логи:
    Feb 02 15:30:22 server systemd[1]: Started cAdvisor.
    ...

nodeexporter: ✓ Активен
  ...

vmagent: ✓ Активен
  ...

🔌 Проверка портов:

✓ Порт 9100 (Node Exporter) - СЛУШАЕТ
✓ Порт 9101 (cAdvisor) - СЛУШАЕТ
✓ Порт 8429 (vmagent) - СЛУШАЕТ

⚙️  Конфигурация vmagent:
...
```

---

## 🛠️ Полезные команды после установки

### Управление сервисами:

```bash
# Статус всех сервисов
systemctl status cadvisor nodeexporter vmagent

# Перезапуск
systemctl restart cadvisor nodeexporter vmagent

# Остановка
systemctl stop cadvisor nodeexporter vmagent

# Просмотр логов в реальном времени
journalctl -u vmagent -f
journalctl -u cadvisor -f
journalctl -u nodeexporter -f
```

### Проверка метрик:

```bash
# Метрики Node Exporter
curl http://127.0.0.1:9100/metrics

# Метрики cAdvisor
curl http://127.0.0.1:9101/metrics

# Статус vmagent
curl http://127.0.0.1:8429/metrics
```

### Изменение конфигурации:

```bash
# Редактировать label "instance"
nano /opt/monitoring/vmagent/conf.d/cadvisor.yml
nano /opt/monitoring/vmagent/conf.d/nodeexporter.yml

# Изменить URL Victoria Metrics
nano /etc/systemd/system/vmagent.service

# После изменений:
systemctl daemon-reload
systemctl restart vmagent
```

### Управление UFW Firewall:

```bash
# Проверить статус и правила
ufw status verbose
ufw status numbered

# Добавить новое правило
ufw allow from [IP] to any port [PORT]

# Удалить правило по номеру
ufw delete [NUMBER]

# Временно отключить UFW
ufw disable

# Включить UFW обратно
ufw enable

# Перезагрузить правила
ufw reload
```

### NetBird команды:

```bash
# Проверить статус и IP
netbird status

# Посмотреть список пиров
netbird list

# Переподключиться
netbird down && netbird up

# Посмотреть логи
journalctl -u netbird -f
```

---

## 🔧 Настройка Remnawave Node (после установки)

После успешного выполнения скрипта:

1. **Скопировать NetBird IP из вывода скрипта**
   - IP будет показан после завершения установки
   - Или проверить: `sudo netbird status`

2. **Перейти в панель Remnawave**
   - Nodes → Management → кнопка `+`

3. **Создать ноду**
   - Node Address: указать NetBird IP
   - Node Port: указать ваш NODE_PORT (по умолчанию 2222)
   - Заполнить остальные поля
   - Скопировать docker-compose.yml

4. **Создать конфигурацию на сервере**
   ```bash
   cd /opt/remnanode
   nano docker-compose.yml
   # Вставить скопированную конфигурацию
   ```

5. **Запустить контейнер**
   ```bash
   docker compose up -d
   docker compose logs -f -t
   ```

6. **Завершить в панели**
   - Нажать "Next"
   - Выбрать Config Profile
   - Нажать "Create"

7. **✅ Готово!** Firewall уже настроен автоматически скриптом

---

## 📊 Архитектура мониторинга

```
┌─────────────────────────────────────────┐
│           Remnawave Server              │
│  ┌─────────────────────────────────┐   │
│  │   Docker Container (Node)       │   │
│  │   ┌──────────────────────┐      │   │
│  │   │    XRAY-core         │      │   │
│  │   └──────────────────────┘      │   │
│  └─────────────────────────────────┘   │
│              ↓ metrics                  │
│  ┌─────────────────────────────────┐   │
│  │    cAdvisor (port 9101)         │   │
│  │    - Container metrics          │   │
│  │    - CPU/Memory/Network         │   │
│  └─────────────────────────────────┘   │
│              ↓                          │
│  ┌─────────────────────────────────┐   │
│  │  Node Exporter (port 9100)      │   │
│  │    - System metrics             │   │
│  │    - Disk/CPU/Network/Load      │   │
│  └─────────────────────────────────┘   │
│              ↓                          │
│  ┌─────────────────────────────────┐   │
│  │   vmagent (port 8429)           │   │
│  │    - Scrapes metrics            │   │
│  │    - Remote write               │   │
│  └─────────────────────────────────┘   │
│              ↓                          │
└──────────────┼──────────────────────────┘
               ↓ remoteWrite.url
┌──────────────────────────────────────────┐
│    Victoria Metrics                      │
│    (your-vm-server:8428)                 │
│    - Stores metrics                      │
│    - Queried by Grafana                  │
└──────────────────────────────────────────┘
```

---

## ❓ Troubleshooting

### Сервис не запускается

```bash
# Смотрим детальные логи
journalctl -xeu cadvisor
journalctl -xeu nodeexporter
journalctl -xeu vmagent

# Проверяем что файлы существуют
ls -lah /opt/monitoring/cadvisor/cadvisor
ls -lah /opt/monitoring/nodeexporter/node_exporter
ls -lah /opt/monitoring/vmagent/vmagent

# Проверяем права
chmod +x /opt/monitoring/cadvisor/cadvisor
chmod +x /opt/monitoring/nodeexporter/node_exporter
chmod +x /opt/monitoring/vmagent/vmagent
```

### vmagent не отправляет метрики

```bash
# Проверяем конфигурацию
cat /etc/systemd/system/vmagent.service

# Проверяем доступность Victoria Metrics
curl -I http://your-vm-ip:8428/

# Через NetBird проверяем связность
ping your-vm-ip

# Смотрим логи vmagent
journalctl -u vmagent -n 50
```

### Метрики не собираются

```bash
# Проверяем что сервисы слушают на портах
ss -tlnp | grep 9100
ss -tlnp | grep 9101

# Проверяем что метрики доступны
curl http://127.0.0.1:9100/metrics | head
curl http://127.0.0.1:9101/metrics | head

# Проверяем конфигурацию scrape
cat /opt/monitoring/vmagent/scrape.yml
cat /opt/monitoring/vmagent/conf.d/*.yml
```

### NetBird не подключается

```bash
# Проверяем статус
sudo netbird status

# Смотрим логи
sudo journalctl -u netbird -n 50

# Переподключаемся
sudo netbird down
sudo netbird up --setup-key [YOUR_KEY]
```

### Проблемы с UFW Firewall

```bash
# Проверить статус
sudo ufw status verbose

# Посмотреть все правила с номерами
sudo ufw status numbered

# Добавить правило вручную (если нужно)
sudo ufw allow from PANEL_IP to any port NODE_PORT

# Удалить правило по номеру
sudo ufw delete [NUMBER]

# Перезапустить UFW
sudo ufw reload

# Отключить UFW (если что-то пошло не так)
sudo ufw disable
```

### Не могу подключиться к серверу по SSH после настройки UFW

```bash
# Если потеряли SSH доступ, подключитесь через консоль хостинга и:
sudo ufw allow OpenSSH
sudo ufw reload

# Или временно отключите UFW
sudo ufw disable
```

---

## 🔄 Обновление компонентов

### Обновление версий в скрипте:

В начале скрипта `setup_remnawave_node.sh` измените версии:

```bash
CADVISOR_VERSION="0.55.1"      # Новая версия
NODE_EXPORTER_VERSION="1.9.1"  # Новая версия
VMAGENT_VERSION="1.123.0"      # Новая версия
```

### Ручное обновление cAdvisor:

```bash
cd /opt/monitoring/cadvisor/
systemctl stop cadvisor
rm -f cadvisor
wget https://github.com/google/cadvisor/releases/download/v0.55.1/cadvisor-v0.55.1-linux-amd64
mv cadvisor-v0.55.1-linux-amd64 cadvisor
chmod +x cadvisor
systemctl start cadvisor
systemctl status cadvisor
```

Аналогично для Node Exporter и vmagent.

---

## 📝 Changelog

### v2.1 (2025-02-02)
- ➕ Автоматическая настройка UFW firewall
- ➕ Запрос NODE_PORT для связи с панелью (по умолчанию 2222)
- ➕ Запрос IP панели Remnawave для настройки firewall
- ➕ Автоматическое определение и вывод NetBird IP
- 🔒 Убраны конкретные IP адреса из примеров
- ✨ Улучшенный вывод финальных инструкций с NetBird IP

### v2.0 (2025-02-02)
- ➕ Добавлена установка мониторинга (cAdvisor, Node Exporter, vmagent)
- ➕ Интерактивный режим для ввода instance name и Victoria Metrics URL
- ➕ Автоматическое создание systemd сервисов
- ➕ Скрипт проверки статуса мониторинга
- ✨ Улучшенное логирование с цветным выводом

### v1.0 (2025-02-01)
- 🎉 Первая версия
- ✅ Установка базовых компонентов (NetBird, Docker)
- ✅ Создание структуры директорий

---

## 📧 Поддержка

При возникновении проблем:
1. Проверьте логи: `/var/log/remnawave_setup.log`
2. Запустите скрипт проверки: `sudo ./check_monitoring_status.sh`
3. Проверьте статус сервисов: `systemctl status cadvisor nodeexporter vmagent`

---

## 📄 Лицензия

Скрипты созданы для автоматизации развертывания Remnawave Node.
Используйте на свой страх и риск в production окружении.
