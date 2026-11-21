# PB-044 — отдельный PartyBox за standalone Docker Caddy

## Результат

Подготовить CI/CD и настройку рядом с Baza на том же VPS. Подтверждено:
PartyBox лежит отдельной папкой, домен partybox.sorima.tech; Caddy настраивает
пользователь и запускает отдельным Docker-контейнером, вне Compose приложений.

## Границы

Прочитаны только workflow/Compose/инструкции соседнего baza_2; файлы и секреты
Baza не менялись. Из его production процесса приняты ручной запуск CD, SSH_*
и DEPLOY_PATH. Промежуточная идея интеграции в Nginx Baza отменена пользователем.
Деплой на VPS/публикация не входят в эту работу. Мобильное приложение не меняется.

## Шаги

- [x] Проверить фактическую topology Baza, закрепить новые вводные.
- [x] Manual workflow для проверенного main SHA, GHCR/SSH/migration/rollback.
- [x] Уникальный partybox-api, external partybox_proxy, закрытая БД, без host ports.
- [x] Инструкция Docker network connect/run/reload и домен partybox.sorima.tech.
- [x] Lifecycle и настоящий isolated standalone Caddy smoke.
- [x] Независимое ревью, финальная сверка инструкций, STATUS/ADR.

## Проверка

Shell syntax, deployment lifecycle tests, Compose validation и настоящий Docker
стенд с отдельным Caddy: TLS, Socket.IO WebSocket, пересоздание API и persistence.
Remote Actions/VPS/DNS остаются настройкой пользователя, не объявляются проверенными.

## Фактическая проверка

Шесть lifecycle tests, shell syntax, форматирование и карта проходят. Финальный
smoke использует standalone docker run Caddy с external-сетью и API без host ports;
trusted local TLS, WebSocket, API recreate и persistence прошли. Тестовые ресурсы
удалены. Реальный VPS/GitHub/GHCR не запускались; Flutter не менялся.

Независимое read-only ревью завершено: блокирующих дефектов нет. Layout guard
усилен по замечанию ревью; registry login изолирован от Baza, отдельная регрессия
подтвердила DOCKER_CONFIG. Файлы Baza и реальный VPS не менялись.

## Первый реальный production запуск

2026-11-21 по поручению пользователя workflow 44917953641 успешно развернул
main 3d26404 на VPS. После настройки DNS проверены публичные HTTPS health/ready,
HTTP redirect и весь цикл обеих игр четырьмя реальными Dart HTTP/WebSocket
клиентами с выходом из тестовой комнаты. Это дополняет прежнюю локальную проверку;
физические устройства и пользовательский плейтест всё ещё не подтверждены.
