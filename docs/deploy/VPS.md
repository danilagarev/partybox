# HTTPS backend для приёмки PB-040

Это комплект для одного Linux VPS: PostgreSQL 16.15 → одноразовая миграция →
NestJS → Caddy 2.10.2. Backend и БД не публикуют порты; доступны только 80/443
прокси. Одна реплика backend, без CDN и внешнего балансировщика.

## Подготовка

На сервере нужны Docker Engine и Compose с поддержкой `!override` (2.24.4+).
Установка — [официальная инструкция Docker](https://docs.docker.com/engine/install/ubuntu/).
Положить на VPS checkout проекта, содержащий `deploy/`. Домен вида
`rooms.example.com` должен указывать A/AAAA-записью на этот сервер, порты 80/443
должны быть доступны. DNS и сервер в этой сессии не создавались.

Из корня проекта:

```sh
cp deploy/.env.example deploy/.env
```

В `deploy/.env` заменить ROOM_DOMAIN своим доменом, без схемы/пути.
Создать два случайных секрета (Docker позволяет не устанавливать Node на VPS):

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  --volume "$PWD/deploy:/setup" --workdir /setup \
  node:24.15.0-bookworm-slim node init-secrets.mjs
```

Скрипт не заменяет существующие значения. Каталог secrets имеет mode 0700;
файлы читаются непривилегированным пользователем контейнера через отдельные mounts.
Не менять их при обычном обновлении: пароль должен соответствовать существующей
БД, room token secret обеспечивает повторы регистрации после рестарта.
Значения не входят в образ, `.env`, Git или логи. Build context ограничен
allowlist в `.dockerignore`; мобильные ключи, SDK, backups и secrets туда не попадают.

## Запуск и проверка

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
docker compose --env-file deploy/.env -f deploy/compose.yaml ps
curl --fail https://rooms.example.com/ready
curl --fail https://rooms.example.com/health
```

Ожидается `/ready` → `{"status":"ready"}` и `/health` → `{"status":"ok"}`.
Readiness проверяет доступ к БД и таблицам после миграции. Без БД health остаётся
доступен, ready возвращает 503. Proxy запускается после первой готовности backend.
Docker healthcheck отражает готовность, а restart policy перезапускает завершившийся
процесс; статус unhealthy сам по себе не удаляет и не пересоздаёт БД.

Caddy получает и обновляет публичный сертификат автоматически:
[документация HTTPS](https://caddyserver.com/docs/automatic-https).
HTTP redirect и WebSocket upgrade обслуживаются прокси. Access logging не включён;
тела запросов/Authorization/роли не записываются. Для диагностики:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml logs --tail=50 migrate backend proxy
```

TRUST_PROXY_HOPS=1 включён только в контейнерном варианте: HTTP и Socket.IO
используют последний валидный IP из X-Forwarded-For одного доверенного Caddy.
Backend нельзя публиковать напрямую с этой настройкой. В обычном `make backend`
значение по умолчанию 0, чужие forwarded headers игнорируются.
[Поведение Caddy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

## Обновление, данные и остановка

Загрузить проверенный checkout, сохранив `deploy/.env`, `deploy/secrets` и volumes:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
```

Остановка с сохранением данных:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml stop
```

Комнаты логически живут 24 часа. Backend при старте и раз в минуту удаляет истёкшие
комнаты, их регистрации/ack по FK cascade и истёкшие IP-счётчики. При недоступной
БД очистка повторяется позже. Закрытая комната до TTL сохраняет ack для retry.
После физического удаления клиент получает ROOM_UNAVAILABLE вместо ROOM_EXPIRED;
оба результата терминальные. Активные комнаты очистка не затрагивает.

Для ручной резервной копии (на сервере, не в Git):

```sh
mkdir -p deploy/backups
chmod 700 deploy/backups
umask 077
docker compose --env-file deploy/.env -f deploy/compose.yaml exec -T postgres \
  pg_dump -U partybox -Fc partybox > deploy/backups/partybox.dump
```

Dump содержит приватные игровые данные; хранить отдельно вместе с соответствующими
секретами доступа и удалять по выбранному сроку хранения. Restore проверять на
отдельной БД; текущие комнаты не затирать. Для первоначальной приёмки persistence
после рестарта уже проверяется локальным smoke без восстановления dump.

## Android/iOS и физическая приёмка

Собрать приложение с настоящим доменом:

```sh
cd apps/mobile
flutter build apk --release --dart-define=ROOM_SERVER_URL=https://rooms.example.com
```

Без ROOM_SERVER_URL приложение остаётся локальным. HTTPS-сертификат должен быть
доверенным платформе: production-приложение не отключает TLS-проверку и не содержит
тестовый CA. Существующий APK со сборочным адресом не изменяется настройкой backend.
iOS собирать на macOS/Xcode с тем же define; подпись и физические устройства
требуют отдельной проверки. [Протокол четырёх телефонов](../playtests/PB-040-network.md).

## Изолированный локальный HTTPS smoke

Из корня репозитория после `npm ci`, при работающем Docker:

```sh
node deploy/smoke.mjs
```

С настоящими Dart-клиентами дополнительно:

```sh
FLUTTER_BIN=/path/to/flutter/bin/flutter node deploy/smoke.mjs
```

Smoke использует отдельный случайный Compose project, volumes, секреты в /tmp,
случайный loopback-порт и внутренний CA Caddy. Проверяет TLS (в том числе отказ
без доверия CA), четыре клиента, миграцию/readiness, restart backend, outage/restart
БД, сохранение раунда, результат и retry. Dart получает CA только в test isolate;
валидация сертификатов остаётся включена. Поддельный forwarded header не обходит
IP-лимит прокси. В finally удаляются только ресурсы этого тестового project.
Публичный домен/ACME и физические телефоны этот прогон не подтверждает.
