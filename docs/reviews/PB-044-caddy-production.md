# PB-044 — проверка production CI/CD

2026-11-21. Исходники соседнего Baza использованы только для чтения процесса.
Финальная схема подтверждена пользователем: отдельная папка PartyBox,
standalone Docker Caddy вне Compose, partybox.sorima.tech.

Независимый агент проверил manual SHA/Checks gate, ancestry main, SSH host key,
immutable digest, Compose isolation, Caddy topology и инструкции диагностики/
rollback. Блокирующих находок не обнаружено. Неблокирующее замечание: layout guard
мог принимать промежуточный host-proxy вариант. Исправлено добавлением проверок
external-сети partybox_proxy и отсутствия ports до сборки/отправки.

Основной агент дополнительно изолировал GHCR login при PAT в docker-auth PartyBox,
чтобы не заменять учётные данные Baza при общем SSH_USER. Регрессия DOCKER_CONFIG
проходит; всего 6 deployment lifecycle tests. Bash syntax/Prettier/карта/diff
проходят. Настоящий isolated Docker smoke: отдельный docker run Caddy на external
network, API/БД без published ports, TLS HTTP с проверенным CA, Socket.IO WS с
тестовым исключением проверки сертификата, ready, API recreate, persistence;
временные ресурсы удалены. Caddyfile validated реальным Caddy.

В реальном GitHub/GHCR/SSH/VPS/DNS проверки не запускались. Caddy и Baza владельца
не изменялись. Конфигурация рассчитана на однократную настройку по PRODUCTION.md.
