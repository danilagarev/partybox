# ADR 0010: отдельный Docker Caddy и ручной production CD

Принято 2026-11-21. Заменяет topology/автоматический trigger ADR 0009;
навигация и настройки приложения из ADR 0009 сохраняются.

Trigger CD заменён [ADR 0015](0015-ai-memory-and-automatic-delivery.md)
2026-11-23. Остальные инфраструктурные решения сохраняются.

## Контекст

Пользователь поручил посмотреть CI/CD в соседнем baza_2 и разместить PartyBox
на том же VPS в отдельной соседней папке. Baza использует ручной production CD,
GHCR, SSH_* и DEPLOY_PATH; её frontend Nginx занимает 80/443. Затем пользователь
уточнил: входным proxy будет отдельный Docker Caddy вне Compose приложений,
который он настроит сам. Поддомен подтверждён: partybox.sorima.tech.

## Решение

- Compose partybox_prod содержит только собственные PostgreSQL, одноразовую
  migration и partybox-api. БД/секреты/volume отдельные; host-порты не публикуются.
- Выделенная external network partybox_proxy связывает только Caddy и API.
  Она создаётся владельцем до deploy. Standalone Caddy подключается через
  docker network connect, а при пересоздании — флагом --network в его запуске.
  API имеет уникальное service name и не конфликтует с backend Baza.
- Caddy завершает TLS и проксирует partybox.sorima.tech → partybox-api:3000,
  перезаписывая X-Forwarded-For TCP-адресом клиента. Backend доверяет одному proxy.
  Конфигурация ingress, выдача сертификатов и lifecycle Caddy принадлежат владельцу,
  PartyBox workflow не меняет их. Данные Caddy /data и /config сохраняются отдельно.
- Deploy backend запускается вручную с main. Полный SHA (либо текущий main)
  должен иметь успешный Checks push и принадлежать истории main. Точный commit
  собирается в image внутри ручного CD, отправляется в GHCR, deploy идёт по digest.
  Это отличается от Baza расположением image build, но сохраняет ручной контроль.
- Имена Secrets соответствуют Baza: SSH_HOST, SSH_USER, SSH_PORT,
  SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS, DEPLOY_PATH; необязательный GHCR_PAT.
  DEPLOY_PATH — другая папка; пароль БД/токенов Baza не используется. При
  GHCR_PAT Docker login хранится в DEPLOY_PATH/docker-auth, отдельно от Baza.
- Миграция до замены, readiness rollback и flock сохраняются. Logs ограничены,
  API/миграция 384 MiB и DB 256 MiB по умолчанию, настраиваемые через .env.

## Последствия и проверка

Нужна однократная настройка сети/SSH/GHCR/DNS/Caddy владельцем. Пересоздание
Caddy без сети разорвёт маршрутизацию; restart сохраняет связь. Docker network
удаляется отдельно и не принадлежит docker compose down PartyBox. При переводе
общего ingress пользователь должен освободить 80/443 от нынешнего Baza frontend.
Новые проекты не объединяются по БД или приватным сетям.

[Инструкция](../deploy/PRODUCTION.md).
Первичные источники: [Compose networking](https://docs.docker.com/compose/how-tos/networking/),
[Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
[GitHub manual workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
Сверены 2026-11-21. Локальный smoke не заменяет реальный VPS/Actions запуск.
