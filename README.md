# Скрипты автоматизации развертывания Remnawave Node

[![GitHub release](https://img.shields.io/badge/version-v4.0.0-blue.svg)](https://github.com/VAQYBIN/Remnawave-Node-Auto-Installer/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

Автоматическая установка и настройка Remnawave Node с полным стеком мониторинга (cAdvisor, Node Exporter, VictoriaMetrics Agent) и настройкой безопасности (UFW Firewall).

С v4 один скрипт ставит сервер любой из трёх [ролей](#-роли-нод): входная нода
(`entry`), выходная (`exit`) или выходная с прямыми подключениями (`exit-direct`).
Пути, имена контейнеров и конфиги одинаковы на всех серверах.

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
3. **.env.example** - Шаблон файла конфигурации
4. **templates/** - Шаблоны nginx для ролей и сайт-заглушка. При запуске через
   `curl | bash` скрипт сам скачивает их из репозитория
5. **panel/** - Конфигурация панели: профили и описание ролей ([panel/README.md](panel/README.md))
6. **tools/rw_export.py** - Выгрузка конфигурации панели через API с маскировкой
   секретов: `RW_URL=https://panel.example.com RW_TOKEN=<API-токен> python3 tools/rw_export.py`.
   Отправлять можно только `rw-export-masked.zip`. В `rw-export/raw/` настоящие ключи,
   обе папки исключены из git

---

## 🚀 Быстрый старт

### Вариант 1: Скачать и запустить

```bash
curl -fsSL -o setup_remnawave_node.sh git.new/remnawave-setup && sudo bash setup_remnawave_node.sh
```

**⚠️ Не запускайте через `sudo bash <(curl ...)`.** Под `sudo` подстановка процесса
не работает: `/dev/fd/63` открыт в оболочке пользователя, а не в процессе от root.
На Ubuntu 26.04 с `sudo-rs` такой запуск падает всегда, на других системах
зависит от настроек `sudo`. Скачайте скрипт файлом, как в примерах ниже.

**💡 Совет:** Интерактивный ввод работает во всех вариантах, ответы читаются из `/dev/tty`.

### Вариант 2: Без вопросов, из файла конфигурации

Для раскатки нескольких нод параметры задаются заранее, и скрипт отрабатывает
целиком без ручного ввода — см. раздел [Неинтерактивный режим](#-неинтерактивный-режим).

```bash
sudo bash setup_remnawave_node.sh --config /root/node.env --non-interactive
```

### Вариант 3: Привести существующую ноду к стандарту роли

```bash
sudo bash setup_remnawave_node.sh --role-only --config /root/node.env
```

Подробнее — в разделе [Режим --role-only](#режим---role-only).

### Проверка неслитой ветки

Новые версии сначала попадают в ветку `dev`, а в `main` переносятся после
проверки. Короткая ссылка `git.new/remnawave-setup` и шаблоны по умолчанию
берутся из `main`. Чтобы проверить `dev` на тестовом сервере, возьмите скрипт
из этой ветки и укажите её же для шаблонов (`templates/`):

```bash
curl -fsSL -o setup_remnawave_node.sh \
  https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/dev/setup_remnawave_node.sh \
  && sudo REMNAWAVE_INSTALLER_REF=dev bash setup_remnawave_node.sh \
  --config /root/node.env --non-interactive
```

Переменная `REMNAWAVE_INSTALLER_REF=dev` пишется после `sudo`, перед `bash`:
`sudo` очищает окружение, и переменная, указанная до него, до скрипта не дойдёт.

Без `REMNAWAVE_INSTALLER_REF=dev` скрипт из `dev` будет скачивать шаблоны
из `main`. Если их там нет, установка остановится на предпроверках, до
каких-либо изменений на сервере. Если в `main` лежит старая версия
шаблонов, скрипт этого не заметит, поэтому переменную лучше не забывать. В клоне репозитория
переменная не нужна: шаблоны берутся из папки `templates/` рядом со скриптом.

### Скрипт проверки статуса

```bash
# Скачать скрипт проверки
curl -fsSL https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/main/check_monitoring_status.sh -o check_monitoring_status.sh
chmod +x check_monitoring_status.sh

# Запустить проверку
sudo ./check_monitoring_status.sh
```

---

## 🎭 Роли нод

Сервис построен на каскаде: клиент подключается к **входной** ноде в РФ, а она
передаёт трафик по сети NetBird на **выходную** ноду за рубежом. Роль задаётся
обязательным параметром `NODE_ROLE`.

| | `entry` (вход, РФ) | `exit` (выход) | `exit-direct` (выход + прямые) |
|---|---|---|---|
| nginx | SNI-роутер на 443 + сайт-заглушка | нет | только сайт-заглушка |
| Сертификат | да | нет | да (сайт + Hysteria2) |
| Кто слушает 443/tcp | nginx (stream) | никто | Xray |
| UFW, открыто для всех | 443/tcp, 80/tcp | ничего | 443/tcp, 443/udp, 8443/tcp, 80/tcp |
| Сертификат смонтирован в remnanode | нет | нет | да |

**entry.** nginx принимает 443/tcp и, не расшифровывая TLS, смотрит на SNI:
подключения на `NODE_DOMAIN` уходят в Xray (`127.0.0.1:XRAY_LOCAL_PORT`), а все
остальные, в том числе с чужим SNI или без него, попадают на сайт-заглушку
(`127.0.0.1:SITE_LOCAL_PORT`). Reality использует этот же сайт как `target`,
поэтому у сайта включены TLS 1.3, X25519 и HTTP/2. Proxy protocol не используется
(`xver: 0`). Порт 80 только перенаправляет на `https://NODE_DOMAIN`.

**exit.** Ни nginx, ни сертификата. Трафик приходит с входных нод на инбаунд
`bridge-in` через NetBird, наружу не открыто ничего, кроме SSH.

**exit-direct.** 443 слушает сам Xray, неавторизованные подключения он
передаёт на сайт-заглушку. Сертификат смонтирован в `remnanode` для Hysteria2.

**Порт моста `10443/tcp`** в UFW не открывается ни в одной роли. Мост работает
через NetBird, а NetBird ставит свои правила файрвола раньше UFW. Итоговая
проверка скрипта отдельно убеждается, что 10443 в UFW не разрешён.

Что настроить в панели для каждой роли, скрипт выводит в конце работы.
Подробнее о профилях и сквадах — в [panel/README.md](panel/README.md).

### Единые пути и имена

| Что | Путь / имя |
|---|---|
| remnanode | `/opt/remnanode/docker-compose.yml`, контейнер `remnanode` |
| nginx | `/opt/nginx/nginx.conf`, `/opt/nginx/html/`, `/opt/nginx/docker-compose.yml`, контейнер `nginx` |
| сертификаты | `/opt/certs/fullchain.pem`, `/opt/certs/privkey.key` |
| CertWarden-клиент | `/opt/certwarden-client/docker-compose.yml`, контейнер `certwarden-client` |

Правила, которым следуют все сгенерированные compose-файлы:

- **Сертификаты монтируются папкой** `/opt/certs`, а не отдельными файлами. Если
  файл заменить через переименование, отдельно смонтированный файл в контейнере
  продолжит показывать старую версию.
- **Никаких `ports:` на `0.0.0.0`.** Порты, опубликованные Docker, идут через
  iptables мимо UFW и оказываются открыты всему интернету. Поэтому nginx и
  remnanode работают в `network_mode: host`, а CertWarden-клиент публикуется
  только на `127.0.0.1:5055`.
- **Повторный запуск безопасен.** Перед заменой конфига старая версия сохраняется
  в `/opt/<компонент>/backup-<дата>/`. Неизменённые файлы не трогаются. Если
  поменялся только `nginx.conf`, nginx делает `reload`, а не перезапуск, поэтому
  текущие подключения не рвутся.
- **Свой сайт не перезаписывается.** Сайт-заглушка кладётся в `/opt/nginx/html/`,
  только если папка пуста.

### Сертификаты

`CERT_SOURCE=certwarden` поднимает CertWarden-клиент
(`ghcr.io/gregtwallace/certwarden-client`) по схеме с текущих серверов и ждёт,
пока он запишет `fullchain.pem` и `privkey.key` в `/opt/certs`. После продления
клиент перезапускает контейнер `nginx`.

`remnanode` клиент **не перезапускает**: Xray сам перечитывает файлы сертификата
раз в час, а перезапуск ноды оборвал бы все подключения. Но это работает,
только если в конфиг Xray попадает путь к файлу. Сейчас панель встраивает в
конфиг собственную копию сертификата, подробнее в
[panel/README.md](panel/README.md#откуда-нода-на-самом-деле-берёт-сертификат).

CertWarden-клиент опубликован на `127.0.0.1:5055`, как на текущих серверах.
С такой публикацией сервер CertWarden не может сам отправить клиенту
обновление, если на сервере нет прокси. Тогда сертификат приходит, когда
клиент запускается.

`CERT_SOURCE=manual` предполагает, что файлы вы кладёте сами, например
wildcard-сертификат:

```bash
mkdir -p /opt/certs
cp fullchain.pem /opt/certs/fullchain.pem   # сертификат с цепочкой
cp privkey.key   /opt/certs/privkey.key     # приватный ключ
```

В обоих случаях скрипт проверяет:
- файлы есть и читаются;
- сертификат не просрочен (`openssl x509 -checkend`);
- ключ подходит к сертификату;
- сертификат покрывает `NODE_DOMAIN`.

Если что-то не так, скрипт останавливается и пишет, что и куда положить. Права на
`privkey.key` выставляются `600`. В конце выводятся срок действия и SAN.

### Предпроверки

Предпроверки выполняются до любых изменений на сервере. Скрипт **ничего не
останавливает сам**: если порт занят, он показывает процесс (`ss -tlnp`) и
завершается.

- **443/tcp и 80/tcp** (`entry`, `exit-direct`). Порт может держать только
  собственный контейнер роли: `nginx` или, для 443 на `exit-direct`,
  `remnanode`.
- **SITE_LOCAL_PORT**, а на `entry` ещё и **XRAY_LOCAL_PORT**.
- **5055/tcp** для CertWarden-клиента.
- **Контейнеры `remnanode`, `nginx`, `certwarden-client`**. Если контейнер с
  таким именем создан из другой папки, docker compose не сможет им управлять,
  и скрипт тоже остановится.
- **Старые контейнеры** ручной установки (`remnawave-nginx`, `certwardenclient`):
  о них скрипт только предупреждает.
- **Образы роли есть в реестре**: `remnawave/node:REMNANODE_VERSION`, nginx и
  certwarden-client. Если Docker уже установлен, проверка идёт через
  `docker manifest inspect`. При полной установке Docker ещё нет, поэтому
  скрипт обращается к HTTP API Docker Hub и ghcr.io через `curl`.
- **Шаблоны роли** скачиваются и проверяются заранее: в шаблоне nginx должны
  быть все подстановки, в сайте — `</html>`. Дальше установка берёт уже
  проверенные файлы.

### Режим --role-only

`--role-only` выполняет только ролевую часть:
- сертификат;
- nginx;
- `docker-compose.yml` remnanode;
- правила UFW;
- итоговую проверку.

Обновление системы, NetBird, Docker и мониторинг не трогаются, поэтому
`NETBIRD_SETUP_KEY`, `INSTANCE_NAME` и `VICTORIA_METRICS_URL` в этом режиме не нужны.
Режим нужен, чтобы привести к стандарту уже работающие ноды без переустановки.

- `SECRET_KEY` берётся из существующего `/opt/remnanode/docker-compose.yml`,
  если его нет в конфигурации.
- Правила UFW, которые ставил скрипт (в том числе `Xray TCP`/`Xray UDP` из v3),
  но которых нет в наборе роли, удаляются. SSH, NODE_PORT и правила,
  добавленные вручную, остаются.
- Старые контейнеры (`remnawave-nginx`, `certwardenclient`) нужно остановить
  вручную. Пока они держат 443 или 5055, предпроверка не пройдёт.

```bash
# пример для существующей входной ноды
docker stop remnawave-nginx certwardenclient
sudo bash setup_remnawave_node.sh --role-only --config /root/node.env
# убедившись, что всё работает:
docker rm remnawave-nginx certwardenclient
```

### Итоговая проверка

В конце скрипт выводит отчёт по пунктам с ✓ / ✗:
- запущены контейнеры роли;
- `entry`: nginx слушает `0.0.0.0:443` и `0.0.0.0:80`, сайт на
  `127.0.0.1:SITE_LOCAL_PORT` отвечает по TLS 1.3 с ALPN h2 и валидным
  для `NODE_DOMAIN` сертификатом, а 443 с чужим SNI отдаёт сайт;
- `exit-direct`: сайт отвечает, файлы сертификата видны внутри `remnanode`;
- `10443` не разрешён в UFW;
- NetBird подключён, выводятся NetBird IP и FQDN.

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
8. 📄 Генерация `/opt/remnanode/docker-compose.yml` (образ `remnawave/node:REMNANODE_VERSION`)
   и запуск ноды, если задан `SECRET_KEY`

#### Роль (`entry`, `exit-direct`):
9. 🔐 Сертификат в `/opt/certs` — CertWarden-клиент или файлы вручную
10. 🌐 nginx (`nginx:1.30.6-alpine`, стабильная ветка, `network_mode: host`) по шаблону
    роли и сайт-заглушка

### Интерактивные параметры:

Всё перечисленное ниже можно задать заранее и обойтись без вопросов —
см. [Неинтерактивный режим](#-неинтерактивный-режим).

В начале работы скрипт запросит:
- **Роль ноды** — `entry`, `exit` или `exit-direct`
- **NetBird Setup Key** (получить в панели NetBird: https://app.netbird.io/)
- **Название инстанса** (например: `de-node-01`, `ru-moscow-01`)
- **IP/URL Victoria Metrics** (например: `10.0.0.1` или `http://10.0.0.1:8428` - формат будет автоматически проверен)
- **NODE_PORT для связи с панелью** (по умолчанию: `2222`)
- **NetBird IP панели Remnawave** — адрес панели **внутри mesh-сети** (обычно `100.x.x.x`), а не её публичный IP
- Для `entry` и `exit-direct`: **домен ноды**, **источник сертификата** и, для
  CertWarden, имена и ключи сертификата

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
- Публичные порты задаёт роль (см. [Роли нод](#-роли-нод)); `10443` не открывается никогда
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
│   ├── docker-compose.yml  # Генерируется скриптом (chmod 600, в нём SECRET_KEY)
│   └── backup-<дата>/      # Предыдущие версии при повторном запуске
├── nginx/                  # entry, exit-direct
│   ├── nginx.conf
│   ├── html/index.html     # Сайт-заглушка
│   └── docker-compose.yml
├── certs/                  # entry, exit-direct
│   ├── fullchain.pem
│   └── privkey.key         # chmod 600
├── certwarden-client/      # CERT_SOURCE=certwarden
│   └── docker-compose.yml  # chmod 600, в нём ключи CertWarden
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

5. **Запустить контейнер** — если SECRET_KEY был известен скрипту, нода уже
   запущена. Иначе:
   ```bash
   cd /opt/remnanode
   docker compose up -d
   docker compose logs -f -t
   ```

6. **Завершить в панели**
   - Нажать "Next"
   - Выбрать Config Profile роли: `entry-ru`, `exit` или `exit-direct`
   - Нажать "Create"
   - Выполнить шаги роли из подсказки в конце вывода скрипта
     (см. также [panel/README.md](panel/README.md))

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
    --role-only        Только ролевая часть, без системы, NetBird, Docker
                       и мониторинга
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
| `NODE_ROLE` | да | `entry`, `exit` или `exit-direct` |
| `NETBIRD_SETUP_KEY` | да¹ | Ключ из панели app.netbird.io |
| `INSTANCE_NAME` | да¹ | Имя ноды в метриках, **уникальное** для каждой ноды |
| `VICTORIA_METRICS_URL` | да¹ | IP или URL Victoria Metrics |
| `PANEL_NETBIRD_IP` | да | NetBird IP панели (`100.x.x.x`), не публичный |
| `NODE_DOMAIN` | entry, exit-direct | Домен ноды, например `ru03.example.org` |
| `CERT_SOURCE` | entry, exit-direct | `certwarden` или `manual` |
| `CW_CLIENT_SERVER_ADDRESS` | certwarden | Адрес сервера CertWarden, `https://...` |
| `CW_CLIENT_CERT_NAME`, `CW_CLIENT_CERT_APIKEY` | certwarden | Имя сертификата и его API-ключ |
| `CW_CLIENT_KEY_NAME`, `CW_CLIENT_KEY_APIKEY` | certwarden | Имя ключа и его API-ключ |
| `CW_CLIENT_AES_KEY_BASE64` | certwarden | AES-ключ из Post Processing |
| `CW_CLIENT_FILE_UPDATE_TIME_START` / `_END` | нет | Окно обновления файлов, по умолчанию `02:00`–`03:00` |
| `CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK` | нет | Дни недели, по умолчанию все |
| `TZ` | нет | Часовой пояс окна, по умолчанию `Europe/Moscow` |
| `REMNANODE_VERSION` | нет | Тег `remnawave/node`, по умолчанию `3.4.4`; `latest` не принимается |
| `XRAY_LOCAL_PORT` | нет | entry: порт Reality на 127.0.0.1, по умолчанию `10443` |
| `SITE_LOCAL_PORT` | нет | Порт сайта-заглушки на 127.0.0.1, по умолчанию `9443` |
| `NODE_PORT` | нет | Порт связи с панелью, по умолчанию `2222` |
| `SSH_PORTS` | нет | Порты SSH через пробел; пусто — автоопределение |
| `SECRET_KEY` | нет | Ключ ноды из панели; пусто — ключ из существующего compose или плейсхолдер |

¹ Не нужны с `--role-only`.

`XRAY_PORT` из v3 больше не используется: нода такую переменную не читает (порты
Xray задаёт профиль в панели), а правила UFW теперь определяет роль. Если он
остался в старом `.env`, скрипт предупредит и проигнорирует его.

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
     bash setup_remnawave_node.sh --config /root/common.env --non-interactive
```

> **⚠️ Переменные пишите ПОСЛЕ `sudo`.** Запись `VAR=x sudo bash script.sh` не сработает:
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
NODE_ROLE="exit"
REMNANODE_VERSION="3.4.4"
SSH_PORTS="22"
```

```bash
# на каждой ноде уникально только имя
for host in de-node-01 fi-node-02 nl-node-03; do
    scp common.env "root@$host:/root/common.env"
    ssh "root@$host" "chmod 600 /root/common.env && \
        curl -fsSL -o /root/setup_remnawave_node.sh git.new/remnawave-setup && \
        INSTANCE_NAME=$host bash /root/setup_remnawave_node.sh \
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

### Обновление remnanode:

Версия образа задаётся `REMNANODE_VERSION` в `.env`, тег без `v`, например `3.4.4`
(список: [Docker Hub](https://hub.docker.com/r/remnawave/node/tags)). После
изменения:

```bash
sudo bash setup_remnawave_node.sh --role-only --config /opt/remnawave-installer/.env
```

Скрипт сохранит старый `docker-compose.yml` в `backup-<дата>/` и пересоздаст
контейнер с новой версией.

---

## 📝 Changelog

### v4.0.0
- ✨ **Роли нод** `NODE_ROLE`: `entry`, `exit`, `exit-direct`. Роль задаёт nginx,
  сертификат, монтирования remnanode и публичные порты UFW
- ✨ Единые пути и имена контейнеров на всех серверах: `/opt/remnanode`, `/opt/nginx`,
  `/opt/certs`, `/opt/certwarden-client`. Раньше имена nginx на серверах различались,
  CertWarden-клиент мог перезапускать не тот контейнер, и новый сертификат не
  подхватывался
- ✨ nginx по шаблонам из `templates/nginx/`: SNI-роутер на 443 для `entry`, сайт-заглушка
  с TLS 1.3, X25519 и HTTP/2 для Reality, редирект с 80
- ✨ Сертификаты: CertWarden-клиент или файлы, положенные вручную. Проверка срока,
  соответствия ключа и домена
- ✨ Режим `--role-only` для приведения существующих нод к стандарту
- ✨ Предпроверки до любых изменений: занятые порты, чужие контейнеры,
  наличие образов роли в реестре, загрузка и целостность шаблонов
- 🔧 Все образы закреплены: `nginx:1.30.6-alpine`, `certwarden-client:v0.5.0`
- ✨ Итоговая проверка с отчётом ✓ / ✗ и подсказкой, что сделать в панели
- 🔧 Образ `remnawave/node` фиксируется по версии (`REMNANODE_VERSION`), `latest` больше
  не используется
- 🔧 Конфиги перед заменой сохраняются в `/opt/<компонент>/backup-<дата>/`
- 🔧 `SECRET_KEY` при повторном запуске берётся из существующего compose-файла, а не
  затирается плейсхолдером. Compose-файлы с секретами получают `chmod 600`
- 🔧 Если `SECRET_KEY` известен, remnanode запускается сразу
- ⚠️ `XRAY_PORT` удалён: нода такую переменную не читает. Порты UFW теперь задаёт роль,
  правила `Xray TCP`/`Xray UDP` из v3 вне роли удаляются

### v3.2.1
- 🐛 **Установка больше не требует `wget`.** На минимальных образах Ubuntu/Debian
  его нет, и все три загрузки бинарников мониторинга падали с `command not found`,
  а сообщение об ошибке указывало на недоступность GitHub. Теперь загрузчик
  выбирается по факту наличия (`curl` или `wget`), а недостающий доустанавливается
- 🐛 Вывод загрузчика больше не подавляется — реальная причина сбоя (DNS, 404,
  таймаут) попадает в лог
- 🔧 Зависимости (`curl`/`wget`, `tar`) проверяются в начале установки, а не
  обнаруживаются на середине

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
