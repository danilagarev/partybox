# Подготовка Baza к standalone Caddy

Проверенные VPS-вводные — [план PB-046](../../docs/plans/PB-046-vps-ingress.md).
Этот helper **только готовит** новую конфигурацию. Ничего не копирует в рабочую
папку приложения, не запускает deploy, не останавливает сервисы и не занимает 80/443.
Используется workflow [partybox-delivery](../../skills/partybox-delivery/SKILL.md).

## Запуск

На компьютере из репозитория PartyBox (VPS_IP заменить реальным адресом):

```sh
scp deploy/ingress/prepare-baza.py deploy@VPS_IP:/home/deploy/caddy/prepare-baza.py
```

На VPS от deploy:

```sh
python3 /home/deploy/caddy/prepare-baza.py
```

Требуются Python 3, Git, Docker и Compose; никакие Python-пакеты не устанавливаются.
Nginx проверяется текущим immutable image frontend в одноразовом контейнере
на существующей private-сети. Caddyfile проверяется caddy:2-alpine в одноразовом
контейнере без сети и host ports; при первом запуске Docker скачает image.

Результат `/home/deploy/caddy/staged/`:

- изменённые копии frontend/nginx.prod.conf и docker-compose.prod.yml;
- Caddyfile для sorima.tech и partybox.sorima.tech;
- baza-ingress.patch относительно фактических серверных файлов;
- source-sha256.json и base-commit.txt для проверки отсутствия дрейфа перед apply.

Hash Nginx, подсеть и допустимые участники proxy-сети проверяются до подготовки.
Другие домены, дополнительные ports, существующие real_ip настройки или неожиданный
mount из deploy override требуют ручного ревью и останавливают подготовку.
Compose JSON с секретами .env.prod обрабатывается только в памяти и не выводится.
При ошибке рабочие файлы остаются прежними; частичный staging нужно сохранить
для диагностики, затем повторять с новым --output, а не перезаписывать его.

## После подготовки

Проверить diff, затем согласовать конкретное переключение и откат. Hash исходников
нужно повторно сравнить с source-sha256.json непосредственно перед apply.

Миграцию требуется сохранить в репозитории **Baza**. Её CD использует git checkout -f
и удалит незафиксированные рабочие правки. Серверный base commit может отличаться
от локального Baza: patch нужно проверить на целевой ветке, сохранить её новые
маршруты и разрешить конфликты. Старые Baza commits до миграции нельзя штатно
разворачивать поверх Caddy: они снова захотят занять 80/443.

Cutover: frontend становится HTTP-only без host ports, healthcheck переключается
на HTTP, сеть baza_proxy связывает только Caddy и frontend. Реальный IP передаётся
Caddy в X-Real-IP; Nginx доверяет ему только из baza_proxy. В приватный backend
сохраняются X-Real-IP $remote_addr и X-Forwarded-Proto https. Существующие БД/worker
не перезапускаются ради ingress. Certbot и старые certificate volumes не удаляются
во время подготовки. VPS staging подтверждён пользователем: Compose/nginx/Caddy проверки прошли.
Точный base commit d38cc548ae2d2a6d59105107c91acdde48ab2772 найден локально;
SHA256 исходного Nginx совпал с серверным.

## Локальные проверки

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s deploy/ingress -p 'test_*.py'
```

7 unit-тестов плюс разовый local Docker smoke: полный локальный Nginx Baza,
реальный IP через Caddy, spoof protection, HTTPS scheme и /health. Исходные файлы
Baza и VPS этим тестом не менялись. Это не доказательство успешного VPS cutover.

## Проверенное переключение

На время операции не запускать Baza CD. DNS обоих доменов должен вести на VPS;
для HTTPS-проверки Sorima нужен рабочий публичный ACME challenge. Неработающий
AAAA может помешать выдаче сертификата — проверить DNS до переключения.
Скрипт рассчитан на существующие /home/deploy/app и /home/deploy/caddy/staged.
Запускать **от deploy, без sudo**: от другого владельца репозитория он откажется.

На компьютере из PartyBox:

```sh
scp deploy/ingress/switch-to-caddy.sh deploy@VPS_IP:/home/deploy/caddy/switch-to-caddy.sh
```

На VPS:

```sh
bash /home/deploy/caddy/switch-to-caddy.sh
```

Это уже live-операция с перерывом на пересоздание frontend. Скрипт:

1. Проверяет source hashes/HEAD, staged файлы, состав сети, чистый index и отсутствие
   Caddy; повторяет проверки непосредственно перед изменениями.
2. Проверяет конфиги immutable image текущего frontend и закешированного Caddy,
   делает новый backup, фиксирует frontend image ID для операции и отката.
3. Меняет только два Baza ingress-конфига, пересоздаёт **только frontend** с
   --no-deps/--no-build/--pull never, запускает standalone Caddy на двух proxy-сетях.
4. Ждёт корректного TLS Sorima и HTTP 200 от /health и / без отключения проверки
   сертификата, до трёх минут. PartyBox до своего deploy может отвечать 502.
5. После успеха создаёт **локальный коммит только этих двух файлов** в Baza от
   технического автора VPS ingress migration <deploy@localhost>, резервную ветку
   и печатает commit/backup. Push не выполняет и настройки Git глобально не меняет.

При ошибке после начала операции удаляет только свой Caddy по owner-label,
восстанавливает конфиги/index и прежний image frontend. БД, workers, Certbot,
certificate volumes и другие контейнеры не удаляются. Если Git HEAD изменился
параллельно или уже зафиксирован успешный ingress-коммит, автоматический rollback
не переписывает его и требует проверки. Сохранены nginx-preflight.log,
caddy-preflight.log, health-last-error.log и backup в /home/deploy/caddy.

## Перед следующим Baza CD

Успешный локальный коммит на VPS нужен, чтобы **первый будущий CD rollback**
использовал уже совместимые с Caddy конфиги вместо старого d38 с host ports.
Но коммит ещё нужно опубликовать в репозитории Baza и включить в master.
До этого CD Baza оставлять на паузе; нельзя деплоить старый SHA без ingress.

Коммит можно забрать на компьютер без изменения текущей feature-ветки Baza:

```sh
git -C ../baza_2 fetch deploy@VPS_IP:/home/deploy/app HEAD:refs/remotes/vps/ingress
git -C ../baza_2 worktree add ../baza-caddy -b ops/caddy-ingress refs/remotes/vps/ingress
```

Далее проверить коммит в отдельном worktree, опубликовать ветку и включить в
master штатным PR. Не заменять текущую локальную feature-ветку и не переносить
в production непроверенные функциональные изменения вместе с настройкой proxy.
Следующие Baza CD запускать только для commits с новой topology.

Тесты cutover используют fake Docker/curl и настоящий временный Git, проверяют
успех, frontend/Caddy/TLS/Git failure rollback, отказ заменять существующий Caddy
и отказ запускаться от неверного пользователя. Вместе с prepare — 14 тестов.
Это не выдаётся за выполненное live-переключение на VPS.
