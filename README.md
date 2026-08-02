# Скрипты автоматизации развертывания Remnawave Node

[![GitHub release](https://img.shields.io/badge/version-v3.2-blue.svg)](https://github.com/VAQYBIN/Remnawave-Node-Auto-Installer/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

Автоматическая установка и настройка Remnawave Node с полным стеком мониторинга (cAdvisor, Node Exporter, VictoriaMetrics Agent) и настройкой безопасности (UFW Firewall).

Поддерживаются архитектуры **x86_64 (amd64)** и **aarch64 (arm64)** — нужные бинарники выбираются автоматически.

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

### Вариант 1: Одной командой (рекомендуется)

```bash
bash <(curl -fsSL git.new/remnawave-setup)
```

### Вариант 2: Скачать и запустить

```bash
# Скачать скрипт
curl -fsSL git.new/remnawave-setup -o setup_remnawave_node.sh

# Сделать исполняемым и запустить
chmod +x setup_remnawave_node.sh
sudo ./setup_remnawave_node.sh
```

**💡 Совет:** Все варианты поддерживают интерактивный ввод благодаря использованию `/dev/tty`.

### Вариант 3: Без вопросов, из файла конфигурации

Для раскатки нескольких нод параметры задаются заранее, и скрипт отрабатывает
целиком без ручного ввода — см. раздел [Неинтерактивный режим](#-неинтерактивный-режим).

```bash
sudo ./setup_remnawave_node.sh --config /root/node.env --non-interactive
```

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

Все три бинарника скачиваются **параллельно** — суммарное время равно самой
медленной загрузке, а не их сумме.

#### Конфигурация ноды:
8. 📄 Генерация `/opt/remnanode/docker-compose.yml` по шаблону

### Интерактивные параметры:

Всё перечисленное ниже можно задать заранее и обойтись без вопросов —
см. [Неинтерактивный режим](#-неинтерактивный-режим).

В начале работы скрипт запросит:
- **NetBird Setup Key** (получить в панели NetBird: https://app.netbird.io/)
- **Название инстанса** (например: `de-node-01`, `ru-moscow-01`)
- **IP/URL Victoria Metrics** (например: `10.0.0.1` или `http://10.0.0.1:8428` - формат будет автоматически проверен)
- **NODE_PORT для связи с панелью** (по умолчанию: `2222`)
- **XRAY_PORT для входящих VPN подключений** (по умолчанию: `443`)
- **NetBird IP панели Remnawave** — адрес панели **внутри mesh-сети** (обычно `100.x.x.x`), а не её публичный IP

Ещё два вопроса задаются по ходу установки:
- **Подтверждение SSH-портов** перед включением UFW (см. ниже)
- **SECRET_KEY** для `docker-compose.yml` — можно пропустить (Enter) и вписать позже

> **⚠️ Почему NetBird IP, а не публичный?**
> Панель обращается к ноде через mesh-сеть NetBird, поэтому источником пакетов
> будет её адрес в этой сети. Правило UFW с публичным IP панели просто не сработает.
> Найти адрес: панель NetBird → **Peers** → строка сервера панели.

### Что настраивается автоматически:

**🔒 Безопасность (UFW Firewall):**
- **SSH-порты определяются автоматически** из `sshd_config`, `sshd_config.d/*.conf`,
  переменной `$SSH_CONNECTION` текущей сессии и списка сокетов `ss`. Найденный список
  показывается и требует подтверждения **до** включения UFW — можно отменить установку
  или задать порты вручную. Нестандартный SSH-порт больше не приводит к потере доступа.
- Разрешается доступ с NetBird IP панели на NODE_PORT (только TCP)
- Разрешается XRAY_PORT для всех входящих (TCP + UDP)
- UFW автоматически активируется

**🌐 NetBird:**
- После установки автоматически определяется и выводится NetBird IP
- Этот IP нужно использовать в панели Remnawave при создании ноды

**♻️ Повторные запуски:**
- Скрипт идемпотентен: установленные компоненты пропускаются
- Версии бинарников мониторинга сверяются с указанными в скрипте — при расхождении
  бинарник обновляется, при совпадении пропускается
- Прерванная транзакция `dpkg` восстанавливается автоматически (`dpkg --configure -a`)

### Структура директорий после установки:

```
/opt/
├── remnanode/
│   └── docker-compose.yml  # Генерируется скриптом
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
- ✅ Остановка при любой ошибке (`set -euo pipefail`)
- ✅ Идемпотентность - можно запускать повторно
- ✅ Все метрики доступны только на localhost
- ✅ Проверка уже установленных компонентов
- ✅ Подтверждение SSH-портов перед включением firewall
- ✅ NODE_PORT доступен только с адреса панели в mesh-сети

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
6. **Статус UFW** - активен ли firewall и список правил с номерами
7. **Статус NetBird** - подключение к mesh-сети и текущий NetBird IP

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

🔒 Статус UFW Firewall:
✓ UFW активен
...

🌐 Статус NetBird:
✓ NetBird подключен
NetBird IP: 100.64.0.12
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
   - Скопировать выданный **SECRET_KEY**

4. **Вписать SECRET_KEY в конфигурацию**

   `docker-compose.yml` уже создан скриптом в `/opt/remnanode/`. Если вы вводили
   SECRET_KEY во время установки — этот шаг можно пропустить. Иначе:

   ```bash
   nano /opt/remnanode/docker-compose.yml
   # заменить REPLACE_WITH_SECRET_KEY_FROM_PANEL на ключ из панели
   ```

5. **Запустить контейнер**
   ```bash
   cd /opt/remnanode
   docker compose up -d
   docker compose logs -f -t
   ```

6. **Завершить в панели**
   - Нажать "Next"
   - Выбрать Config Profile
   - Нажать "Create"

7. **✅ Готово!** Firewall уже настроен автоматически скриптом

> **Примечание:** сгенерированный `docker-compose.yml` использует `network_mode: host`,
> поэтому проброс портов через Docker не нужен — доступ регулируется правилами UFW.
> Если вы предпочитаете конфигурацию, скопированную из панели, просто замените
> содержимое файла на неё.

---

## 🤖 Неинтерактивный режим

Все ответы можно задать заранее — в файле конфигурации или через переменные
окружения — и скрипт отработает от начала до конца без единого вопроса.
Это нужно, когда нод больше одной.

### Опции командной строки

```
-c, --config PATH      Путь к файлу конфигурации
                       (по умолчанию: /opt/remnawave-installer/.env)
-n, --non-interactive  Не задавать вопросов. При нехватке обязательных
                       параметров скрипт завершится с ошибкой
    --no-save-env      Не сохранять введённые ответы в файл конфигурации
-h, --help             Показать справку
```

### Файл конфигурации

Возьмите за основу [`.env.example`](.env.example) из репозитория:

```bash
curl -fsSL https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/.env.example \
  -o /opt/remnawave-installer/.env
chmod 600 /opt/remnawave-installer/.env
nano /opt/remnawave-installer/.env
```

| Параметр | Обязательный | Описание |
|---|:---:|---|
| `NETBIRD_SETUP_KEY` | да | Ключ из панели app.netbird.io |
| `INSTANCE_NAME` | да | Имя ноды в метриках, **уникальное** для каждой ноды |
| `VICTORIA_METRICS_URL` | да | IP или URL Victoria Metrics |
| `PANEL_NETBIRD_IP` | да | NetBird IP панели (`100.x.x.x`), не публичный |
| `NODE_PORT` | нет | Порт связи с панелью, по умолчанию `2222` |
| `XRAY_PORT` | нет | Порт VPN-подключений, по умолчанию `443` |
| `SSH_PORTS` | нет | Порты SSH через пробел; пусто — автоопределение |
| `SECRET_KEY` | нет | Ключ ноды из панели; пусто — плейсхолдер |

Файл не исполняется скриптом, а разбирается построчно: произвольный код в нём
не выполнится, а неизвестные ключи будут пропущены с предупреждением.

### Приоритет источников

```
переменная окружения → файл конфигурации → значение по умолчанию → вопрос
```

Это позволяет держать общее для всех нод в одном файле, а уникальное
передавать точечно:

```bash
sudo INSTANCE_NAME=de-node-02 SECRET_KEY=xxx \
     ./setup_remnawave_node.sh --config /root/common.env --non-interactive
```

> **⚠️ Переменные пишите ПОСЛЕ `sudo`.** Запись `VAR=x sudo ./script` не сработает:
> `sudo` по умолчанию очищает окружение (`env_reset`), и до скрипта переменная
> не долетит.

### Автосохранение

После интерактивной установки ответы записываются в файл конфигурации
(`chmod 600`), поэтому повторный запуск на той же ноде проходит без вопросов.
Отключается флагом `--no-save-env`. В неинтерактивном режиме файл не
перезаписывается — им управляете вы.

### Что важно учесть

**SSH-порты.** Подтвердить автоопределение в неинтерактивном режиме некому,
поэтому оно выполняется молча, а результат пишется в лог. Если раскатываете
на серверы с нестандартным SSH-портом — задайте `SSH_PORTS` явно. Цена ошибки
здесь — потеря доступа к серверу.

**SECRET_KEY.** Его выдаёт панель в момент создания ноды, и он уникален для
каждой. Полностью автоматической раскатки «с нуля» не выйдет: сначала нода
создаётся в панели, потом ключ попадает в конфигурацию. Если оставить параметр
пустым, скрипт доведёт сервер до полной готовности с плейсхолдером, а ключ
можно вписать позже.

**Секреты.** В файле лежат `NETBIRD_SETUP_KEY` и `SECRET_KEY` — держите права
`600`. Скрипт предупредит, если права шире. Значения, переданные в командной
строке, видны другим пользователям сервера через `ps` и оседают в истории shell.

**Без терминала.** Если `/dev/tty` недоступен (cron, Ansible, CI), скрипт сам
переключается в неинтерактивный режим, а не падает на первом же вопросе.

### Пример: раскатка на несколько нод

```bash
# common.env — одинаковое для всех нод (chmod 600)
NETBIRD_SETUP_KEY="nbp_reusable_key"
VICTORIA_METRICS_URL="100.64.0.1"
PANEL_NETBIRD_IP="100.64.0.5"
NODE_PORT="2222"
XRAY_PORT="443"
SSH_PORTS="22"
```

```bash
# на каждой ноде уникально только имя
for host in de-node-01 fi-node-02 nl-node-03; do
    scp common.env "root@$host:/root/common.env"
    ssh "root@$host" "chmod 600 /root/common.env && \
        INSTANCE_NAME=$host bash <(curl -fsSL git.new/remnawave-setup) \
        --config /root/common.env --non-interactive"
done
```

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
# ВАЖНО: адрес панели — её NetBird IP (100.x.x.x), а не публичный
sudo ufw allow from PANEL_NETBIRD_IP to any port NODE_PORT proto tcp

# Удалить правило по номеру
sudo ufw delete [NUMBER]

# Перезапустить UFW
sudo ufw reload

# Отключить UFW (если что-то пошло не так)
sudo ufw disable
```

### Панель не видит ноду

Проверьте, что правило UFW разрешает именно **NetBird-адрес** панели:

```bash
# Правило должно ссылаться на 100.x.x.x, а не на публичный IP панели
sudo ufw status numbered | grep [NODE_PORT]

# Убедитесь, что mesh-связность есть в обе стороны
sudo netbird status
ping [PANEL_NETBIRD_IP]

# Проверьте, что нода слушает NODE_PORT
sudo ss -tlnp | grep [NODE_PORT]
```

Если правило было создано с публичным IP панели (версии до v3.1), удалите его
и добавьте заново с NetBird-адресом.

### Не могу подключиться к серверу по SSH после настройки UFW

Начиная с v3.1 скрипт определяет SSH-порты автоматически и запрашивает
подтверждение перед включением UFW, поэтому такой ситуации быть не должно.
Если доступ всё же потерян — подключитесь через консоль хостинга и:

```bash
# Разрешить ваш реальный SSH-порт (посмотреть: grep -i '^Port' /etc/ssh/sshd_config)
sudo ufw allow [SSH_PORT]/tcp
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

### v3.2
- ➕ **Неинтерактивный режим**: параметры задаются в `.env`-файле и/или
  переменных окружения, установка проходит без вопросов
- ➕ Флаги `--config`, `--non-interactive`, `--no-save-env`, `--help`
- ➕ Ответы интерактивной установки сохраняются в файл конфигурации
  (`chmod 600`) — повторный запуск идёт без вопросов
- ➕ Шаблон `.env.example` и `.gitignore` для защиты секретов
- 🔒 Файл конфигурации разбирается построчно, а не через `source`:
  произвольный код не выполняется, неизвестные ключи отсеиваются
- 🔧 Без управляющего терминала (cron, Ansible, CI) скрипт сам переходит
  в неинтерактивный режим вместо падения на первом вопросе

### v3.1
- 🐛 **UFW больше не отрезает SSH на нестандартном порту** — порты определяются
  из `sshd_config`, `sshd_config.d/*.conf`, `$SSH_CONNECTION` и `ss`, затем
  подтверждаются пользователем до включения firewall
- 🐛 **NODE_PORT разрешается с NetBird IP панели**, а не с публичного: панель
  обращается к ноде через mesh-сеть, и старое правило не срабатывало
- 🐛 Детект APT-блокировки работает без пакета `psmisc` (fallback на скан `/proc`);
  раньше отсутствие `fuser` молча превращало проверку в заглушку
- 🐛 Устойчивое определение версий бинарников: `node_exporter` понимает только
  `--version`, cAdvisor и vmagent — обе формы флага
- 🐛 Исправлен разбор статусов параллельных загрузок (ветка «пропущено» была
  недостижима, ошибка подпроцесса могла остаться незамеченной)
- 🐛 Запуск без root выдаёт понятное сообщение вместо `Permission denied`

### v3.0
- ➕ Параллельная загрузка бинарников мониторинга
- ➕ Автоопределение архитектуры (amd64 / arm64)
- ➕ Генерация `docker-compose.yml` для ноды с запросом SECRET_KEY
- ➕ Проверка версий при повторном запуске (идемпотентность)
- ➕ Восстановление `dpkg` после прерванной транзакции
- ➕ UFW открывает XRAY_PORT для TCP и UDP
- 🔧 Исправлена индентация YAML-конфигов
- 🔧 Таймауты и повторы на загрузках (`wget --timeout --tries`)
- 🔧 Валидация IP-адресов и портов

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
