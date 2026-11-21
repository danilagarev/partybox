# PB-046 — подготовка переключения VPS на Caddy

## Результат и вводные

Подтверждены /home/deploy/app, prod+deploy Compose, standalone Caddy,
PartyBox /home/deploy/partybox; сети partybox_proxy и baza_proxy созданы.
Подсеть baza_proxy 172.20.0.0/16. Backup: /home/deploy/caddy/backups/baza.CJ3O3Rky.
Серверный SHA256 Nginx 105582ad12ae7a82673a761dd1ff327a5d9c167f72955a3d759af4daf0948783
отличается от локального Baza: нельзя заменять конфиг локальной копией.

## Границы и шаги

- [x] Prepare-only helper читает фактические файлы, проверяет hash/сеть,
      сохраняет patch и исходные hashes, не применяет изменения/не перезапускает сервисы.
- [x] Scoped real IP, HTTPS scheme, сохранение маршрутов, HTTP healthcheck,
      external baza_proxy с alias baza-frontend, без host ports frontend.
- [x] Семь unit-тестов и реальный local Docker IP/proxy smoke, независимое ревью.
- [x] Пользователь запустил helper на VPS: Compose/nginx/Caddy проверки прошли.
- [x] Ревью exact-base diff, переключение пользователем и локальный коммит Baza.
- [ ] Публикация ingress-коммита Baza в GitHub/master (результат не сообщён).
- [x] Первый CD PartyBox и публичный DNS/TLS/readiness/обе игры проверены.

## Проверка и передача

Local Docker на исходнике Baza подтвердил nginx -t, здоровье, реальный IP через
Caddy, HTTPS scheme и отказ поддельному IP от прямого нетрастового клиента.
Подготовка и live cutover на VPS выполнены пользователем; результаты ниже.
Предыдущий commit не изменяется. Новые файлы не коммитились и не публиковались.

## Передача live-шага

Точный серверный base d38cc548 найден в локальном Git Baza, Nginx hash совпал.
Добавлен switch-to-caddy.sh с повторными проверками, immutable image pin,
frontend-only cutover, owner-label rollback и локальным ingress-коммитом Baza
для совместимости первого будущего CD rollback. 14 тестов проходят, независимое
ревью завершено. На точном d38 исходнике реальный Docker smoke подтвердил
IP/header security, HTTPS scheme и health. Live-helper затем успешно выполнен пользователем на VPS.

## Подтверждённый live-результат

Пользователь выполнил switch-to-caddy.sh. Frontend стал Healthy, standalone Caddy
запущен; Sorima /health и / прошли HTTPS-проверку сертификата через loopback/SNI.
Создан локальный Git Baza commit 3564b8d293514cee4d32ada114a5b6460597bd07,
backup /home/deploy/caddy/backups/cutover.vzT7bq2q. Автооткат не потребовался.
Commit ещё не опубликован в GitHub; Baza CD нельзя запускать для старой topology.
PartyBox API пока не подтверждён. Внешняя браузерная/платёжная проверка не заявлена.

После добавления DNS 2026-11-21 через публичный HTTPS пройден полный сетевой
цикл обеих игр четырьмя Dart-клиентами; Sorima /health продолжает отвечать 200.
