# PartyBox на общем VPS за Caddy

Поддомен: **https://partybox.sorima.tech**. Caddy на входе настраивает владелец.
PartyBox лежит отдельной папкой рядом с Baza, имеет свои контейнеры, сеть, БД,
секреты и deployment lock. Подключение к Docker-сети/Nginx/Certbot Baza не требуется.

Из `../baza_2` взяты организация ручного production-деплоя, GHCR, SSH-настройки,
миграция до обновления и readiness/rollback. Файлы Baza не изменялись.
В Baza checkout на VPS обновляется из Git; PartyBox получает готовый образ
и bundle deployment-файлов, Git/Node/npm на VPS не нужны.

## Схема и требования

```text
Internet → standalone Docker Caddy :443
                 │ external network partybox_proxy
                 └→ partybox-api:3000 → PostgreSQL
                    отдельный Compose-проект partybox_prod
```

**Caddy живёт отдельным контейнером, вне Compose-проектов приложений.** PartyBox
не запускает и не перезапускает его. API и БД вообще не публикуют порты хоста;
никаких общих сетей/томов с Baza не требуется. Только Caddy и PartyBox API
подключены к выделенной proxy-сети, БД и migration остаются в закрытой сети.

Нужны Linux x86_64, Docker Engine, системный Compose v2 plugin с `--wait`, Bash, OpenSSL, flock,
SSH-пользователь с доступом к Docker. Init выполняется не от root; можно использовать
существующего непривилегированного deploy-пользователя Baza. Docker group даёт
права, эквивалентные root. Если SSH_USER=root, создайте отдельного пользователя
и ключ для PartyBox.

Default memory limits: API/миграция 384 MiB, БД 256 MiB; журналы каждого
контейнера ограничены 3×10 MB. До запуска проверьте `free -h`,
`docker stats --no-stream` и свободный диск. При миграции одновременно могут
работать прежний API, migration и БД. Для настройки лимитов добавьте
`PARTYBOX_API_MEMORY`/`PARTYBOX_DB_MEMORY` в `.env`; это лимиты, а не измерение
потребления всего сервера.

В прочитанном Compose Baza frontend сейчас занимает 80/443. При переводе входа
на Caddy эти порты нужно освободить для него и направить Baza отдельно.
Это настройка вашего общего ingress; PartyBox CI её не меняет.
Ровно один доверенный proxy перед PartyBox: `TRUST_PROXY_HOPS=1`.
Caddyfile перезаписывает X-Forwarded-For адресом TCP-клиента.

## 1. Отдельная папка на VPS

Узнайте текущее значение **DEPLOY_PATH Baza** в её GitHub Secrets. Оно не видно
из исходников; не копируйте это значение в PartyBox. Например:

```text
/srv/baza_2/              ← существующее приложение
/srv/partybox/            ← новый DEPLOY_PATH PartyBox
  .env                   ← UID/GID, proxy-сеть, лимиты
  secrets/               ← собственные пароли БД и токенов
  releases/<sha>-<run>-<attempt>/
  current-image
  previous-image
  deploy.lock
```

`/srv` здесь пример: используйте реальный родительский каталог Baza. Ниже замените
`/srv/partybox`, `USER`, `HOST`, порт SSH на ваши значения.
От администратора VPS создайте каталог владельцу deploy-пользователю:

```sh
sudo install -d -m 700 -o USER -g USER /srv/partybox
sudo install -d -m 700 -o USER -g USER /srv/partybox/bootstrap
```

С рабочей машины скопируйте initializer:

```sh
scp -P 22 deploy/production/init.sh USER@HOST:/srv/partybox/bootstrap/init.sh
```

По SSH **от USER**, состоящего в Docker group:

```sh
bash /srv/partybox/bootstrap/init.sh /srv/partybox
```

Init создаёт случайные секреты с правами 600, каталоги 700 и `.env` с реальными
UID/GID. Повторный запуск не заменяет секреты. Не меняйте UID/GID на 0.
Имя внешней сети по умолчанию `partybox_proxy`; если меняете его через
`PARTYBOX_PROXY_NETWORK` в `.env`, подключите Caddy к сети с тем же именем.
На VPS не нужен clone репозитория PartyBox.

## 2. GitHub Secrets: имена как у Baza

В **репозитории PartyBox** создайте Environment `production`, разрешите deployment
только ветки `main`. При желании включите required reviewers. Workflow должен
попасть в default branch `main`, чтобы появилась кнопка Run workflow.

Добавьте Secrets в этот Environment; GitHub не переносит их из соседнего репозитория:

| Secret            | Что указать                                                         |
| ----------------- | ------------------------------------------------------------------- |
| `SSH_HOST`        | Тот же VPS, что у Baza: IP/DNS, без схемы                           |
| `SSH_USER`        | Существующий непривилегированный deploy-пользователь либо отдельный |
| `SSH_PORT`        | SSH-порт; можно не задавать при 22                                  |
| `SSH_PRIVATE_KEY` | Полный отдельный deploy-ключ без passphrase; разрешённый на VPS     |
| `SSH_KNOWN_HOSTS` | Проверенная OpenSSH known_hosts запись VPS; обязательна             |
| `DEPLOY_PATH`     | **Новая соседняя папка PartyBox**, например `/srv/partybox`         |
| `GHCR_PAT`        | Необязательно: PAT classic с `read:packages` для pull на VPS        |

SSH_HOST/PORT/KNOWN_HOSTS можно взять из настройки Baza; USER/ключ — использовать
существующие, если их права подходят, либо выдать отдельные. DEPLOY_PATH обязан
отличаться. Для нового SSH-ключа поместите публичную часть в authorized_keys;
`.ssh` — 700, файл — 600; префикс `restrict` запрещает forwarding/pty и оставляет
команды. Приватную часть храните только в Secret.

Host key сверяйте через доверенную консоль VPS, не слепым ssh-keyscan.
Для 22 запись `HOST ssh-ed25519 AAAA...`; для другого порта —
`[HOST]:PORT ssh-ed25519 AAAA...`. HOST должен совпадать с SSH_HOST.

Образ: `ghcr.io/<owner>/<partybox-repo>-backend` (нижний регистр). Actions публикует
его через GITHUB_TOKEN; разрешите packages write, при существующем package выдайте
репозиторию Actions write access. Для приватного package VPS должен иметь pull-доступ:

- Если deploy-пользователь уже авторизован в GHCR, как у Baza, выдайте его PAT
  доступ к новому package; GHCR_PAT можно не задавать.
- Либо задайте GHCR_PAT: workflow авторизует VPS через stdin в отдельный
  `DEPLOY_PATH/docker-auth/config.json`, сохраняя Docker login Baza. PAT не попадает
  в аргументы SSH/образ/bundle. Имя пользователя берётся из github.actor, как в Baza;
  запускать workflow должен владелец используемого PAT.
- Либо один раз выполните
  `docker --config /srv/partybox/docker-auth login ghcr.io -u YOUR_GITHUB_USER`
  от SSH_USER на VPS и введите read:packages PAT через prompt. Это удобнее для общей команды.

Если есть локальный `docker-auth/config.json`, release.sh использует только его;
иначе остаётся совместимость с прежней авторизацией SSH_USER. Просроченный
отдельный login нужно обновить: автоматического fallback на учётные данные Baza нет.

При отдельном docker-auth проверьте `DOCKER_CONFIG=/srv/partybox/docker-auth docker compose version`:
plugin должен находиться в системном каталоге Docker, а не только в
`~/.docker/cli-plugins` прежнего пользователя/config.

Секреты приложения создаются только на VPS; значения БД Baza не используются.
Telegram и чужие уведомления не копируются. GitHub Secrets Baza не читаются
и не изменяются этим комплектом.

## 3. CI и ручной production-деплой

Как в production Baza, деплой запускается **вручную**, push сам сервер не обновляет:

1. Push/merge в `main` → дождаться зелёного **Checks** (`node`, `flutter`, `https`).
2. Actions → **Deploy backend** → Run workflow → branch **main**.
3. Поле `sha` пустое означает текущий main. Для проверенного старого commit
   укажите полный SHA из 40 строчных hex-символов.
4. Workflow требует успешный Checks push того же SHA и его принадлежность истории
   main, собирает точный commit, публикует GHCR image и отправляет immutable digest
   по SSH. Одновременные деплои сериализованы, на VPS используется flock.

В отличие от Baza сборка image расположена внутри ручного Deploy backend после
проверки CI. Это оставляет обычные PR-проверки без публикации image и не требует
разрешений packages write в Checks. Повтор деплоя/первый запуск выполняется той же
кнопкой. SHA должен содержать текущий Caddy deployment layout; коммиты до него
workflow отклоняет до изменения VPS.

На сервер передаётся bundle, затем: pull → ожидание БД → миграция → обновление API
→ `/ready`. Ошибка миграции сохраняет прежний API; ошибка readiness обновления
возвращает предыдущий immutable image. Первый неудачный запуск останавливает
только PartyBox API и сохраняет БД. Обычное обновление кратко разрывает WebSocket;
клиент восстанавливает комнату. Zero downtime не обещается.

## 4. Standalone Docker Caddy и partybox.sorima.tech

Один раз на VPS создайте внешнюю сеть **до первого deploy PartyBox**:

```sh
docker network inspect partybox_proxy >/dev/null 2>&1 || docker network create partybox_proxy
```

Если Caddy уже запущен, подключите его к сети (замените `caddy` реальным именем):

```sh
docker network connect partybox_proxy caddy
```

Повторять connect не требуется, если контейнер уже в этой сети. Обычный
`docker restart caddy` сохраняет подключение; удаление и создание нового
контейнера — нет. Добавьте `--network partybox_proxy` в свою постоянную команду
`docker run`, systemd-unit или другой скрипт запуска Caddy. Существующие сети,
volumes, параметры и сайты Caddy сохраняйте. Нужный фрагмент команды:

```sh
# Дополнить ваш существующий docker run, не запускать второй proxy поверх первого:
# docker run ... --name caddy --network partybox_proxy ... caddy:2-alpine
```

Сертификаты должны переживать пересоздание Caddy: сохраняйте `/data` и `/config`
в его постоянных volumes. Если для Baza нужна другая proxy-сеть, Caddy может быть
подключён к нескольким сетям; для PartyBox используйте уникальный upstream ниже.

Добавьте DNS A `partybox.sorima.tech` на VPS; AAAA — при рабочем IPv6. 80/443
должны вести на ваш Caddy. Добавьте блок из `deploy/production/Caddyfile.example`
в уже используемый Caddyfile:

```caddyfile
partybox.sorima.tech {
    encode zstd gzip
    reverse_proxy partybox-api:3000 {
        header_up X-Forwarded-For {remote_host}
    }
}
```

`127.0.0.1:3100` внутри Caddy не подходит: это сам контейнер, а не PartyBox.
Сертификат и продление обслуживает Caddy; Certbot Baza не нужен. WebSocket
поддерживается reverse_proxy штатно. Пути `/v1`, `/v2`, `/v3`, `/rooms`,
`/socket.io/`, `/health`, `/ready` передаются без добавления `/api`.

Для веба строка `encode zstd gzip` обязательна: JS и CanvasKit WASM занимают
около 10,8 МБ без сжатия. В конфигурации первоначального ingress cutover этой
строки не было; обновление backend через CD само по себе Caddyfile не меняет.
После применения проверьте GET `/main.dart.js` и `/canvaskit/canvaskit.wasm`
с заголовком `Accept-Encoding: gzip`: ожидается `Content-Encoding: gzip`.

Проверьте конфигурацию и примените её вашим штатным способом. При Caddyfile
в `/etc/caddy/Caddyfile`, container name `caddy` и включённом admin API:

```sh
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

Если admin API отключён, используйте свой способ reload/restart; CI PartyBox
не управляет жизненным циклом Caddy. Изменённый host Caddyfile должен быть виден
в контейнере. При bind-mount отдельного файла атомарная замена может оставлять
старый inode; монтируйте каталог конфигов либо обновляйте файл штатным способом.

## 5. Проверка после настройки

Из внешней сети:

```sh
curl --fail https://partybox.sorima.tech/health
curl --fail https://partybox.sorima.tech/ready
```

Новые APK по умолчанию используют `https://partybox.sorima.tech`; вводить адрес
не требуется. В прежних сборках или при ранее сохранённом другом адресе откройте
**Подключение комнат** и сохраните его. У всех друзей один сервер.
Если сохранён доступ к прежнему LAN-серверу, вернитесь к старому адресу либо явно
удалите прежний доступ на телефоне; токен не переносится между серверами.
Проверьте четырьмя телефонами обе игры, уход приложения в фон и возврат.
`health`/`ready` отдельно не доказывают работу WebSocket/полного игрового сценария.

## Диагностика, rollback и данные

На VPS выполните от deploy-пользователя, заменив RELEASE реальной папкой:

```sh
cd /srv/partybox
export BACKEND_IMAGE="$(cat current-image)"
compose=(docker compose --project-name partybox_prod --env-file .env -f releases/RELEASE/compose.yaml)
"${compose[@]}" ps
"${compose[@]}" logs --tail=100 partybox-api postgres
```

Для немедленного отката без пересборки (выберите совместимый bundle):

```sh
bash /srv/partybox/releases/RELEASE/release.sh "$(cat /srv/partybox/previous-image)"
```

Rollback не откатывает SQL. Будущие миграции должны быть совместимы со старым
API; разрушительные миграции требуют отдельного окна и проверенного backup.
Настройте отдельное резервное копирование PartyBox: backup Baza автоматически
его не включает. Не используйте `docker compose down -v` или глобальный
`docker system prune --volumes`. Runtime данные/секреты находятся вне bundle.

Caddyfile-пример приезжает в release только как справка: workflow не меняет
ваш активный ingress. Nginx-example — прежний альтернативный
host-сценарий, для текущей схемы не используется.

Основания, сверены 2026-11-21:
[Caddy reverse_proxy/WebSocket/headers](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
[Docker Compose networking](https://docs.docker.com/compose/how-tos/networking/),
[GitHub manual workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
Локальный Docker smoke проверяет изолированный Caddy с тестовым CA, TLS/Socket.IO,
пересоздание API и сохранение БД; он не является внешним VPS/DNS-плейтестом.

## Веб-клиент и три игры — PB-048

После публикации новой версии и успешного Checks тот же ручной **Deploy backend**
развёртывает backend и общий Flutter Web. Отдельный контейнер, DNS, порт или новое
правило reverse_proxy не требуются: `https://partybox.sorima.tech/` станет каталогом,
`/health`, `/ready`, `/rooms`, `/v2/rooms`, `/v3/rooms`, `/v4/rooms`
и Socket.IO продолжают обслуживаться там же.

Workflow Flutter собирает `scripts/build-web.sh`, проверяет полный набор assets и
публикует artifact `partybox-web-<SHA>`. HTTPS job проверяет именно этот bundle.
CD скачивает bundle точного успешного push-run выбранного main SHA, повторно
проверяет хеши и включает его в `/app/public` Docker-образа. Отсутствующий или
повреждённый bundle останавливает CD. Старые коммиты без такого artifact этим
новым workflow не разворачивать; для rollback используется сохранённый image.

На текущем VPS новые SQL-миграции для clues не нужны. Migration job всё равно
выполняется штатно. Пример Caddy теперь включает `encode zstd gzip`; для сжатия
первой загрузки рекомендуется добавить эту строку в существующий site block
и проверить/reload свой Caddy. Сам CD действующий Caddyfile не переписывает.
Без encode веб также работает, но assets передаются без этого сжатия.

Локально из корня:

```sh
FLUTTER_BIN="$PWD/.tools/flutter/bin/flutter" bash scripts/build-web.sh
node scripts/verify-web.mjs deploy/web
REQUIRE_WEB_BUNDLE=true node deploy/production/test-smoke.mjs
```

`deploy/web/` содержит только воспроизводимые public assets и игнорируется Git;
в нём нельзя хранить секреты. Runtime API/ответы никогда не попадают в web cache.
Веб использует sessionStorage отдельно для каждой вкладки; закрытие вкладки может
потерять доступ. Manifest/icons позволяют добавить ярлык, но offline web cache
в этом срезе не реализуется. Политика/контакты разработчика остаются открытыми
по просьбе владельца; готовность веба не означает готовность магазинной публикации.
