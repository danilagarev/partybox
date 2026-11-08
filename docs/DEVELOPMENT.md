# Среда разработки

## Инструменты

- Node 24.15.0 (`.nvmrc`) и npm 11. Используйте `nvm use` или `fnm use`.
- Flutter 3.38.5 (`.fvmrc`), комплектный Dart 3.10.4. Это закреплённая совместимая
  версия, не утверждение о самом свежем релизе. Обновлять отдельно с проверками.
- Git и make; Android Studio/Android SDK и JDK для Android; macOS/Xcode для iOS.

Если Flutter установлен через FVM:

```sh
fvm install
fvm flutter doctor -v
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
```

FVM устанавливается пользователем выбранным способом; репозиторий не меняет глобальные
настройки IDE и агентов. Альтернатива — SDK нужной версии из
[официального архива Flutter](https://docs.flutter.dev/install/archive) в PATH.
При обновлении версии менять `.fvmrc` и `flutter-version` в CI одновременно.

## Установка и проверки

```sh
make bootstrap
make check
```

`make bootstrap` запускает `npm ci`, `dart pub get` для ядра и `flutter pub get`
для приложения. В CI Dart/Flutter используют `--enforce-lockfile`. Все три lockfile
коммитятся. `npm run check` — только Node-часть; `make check-mobile` — Dart/Flutter.
Тест сервера открывает случайный loopback-порт, Dart test также может открывать
локальный сервис. В изолированной среде этим командам нужно разрешить localhost.

```sh
npm run format
dart format packages/game_core packages/game-content/lib apps/mobile/lib apps/mobile/test apps/mobile/integration_test
```

Prettier не форматирует generated native-файлы и Dart. Для Dart используется
комплектный formatter; конфликта двух форматтеров нет.

## Запуск

```sh
make backend
curl http://127.0.0.1:3000/health
```

`tsc-watch` пересобирает TypeScript и перезапускает сервер после успешной компиляции.
По умолчанию сервер слушает только localhost:3000; `HOST` и `PORT` можно передать
переменными окружения. Пример — `apps/backend/.env.example`. `.env` автоматически
не загружается. Для проверки с устройства явно задайте доступный интерфейс:

```sh
HOST=0.0.0.0 PORT=3000 npm run dev:backend
```

Мобильный каркас работает независимо от сервера:

```sh
flutter devices
make mobile
```

Доступен полный локальный цикл «Шпиона», включая повтор с прежними именами.
Имена, время и набор сохраняются локально при старте партии и восстанавливаются
в новой подготовке. Активный раунд остаётся в памяти и после закрытия теряется.
В подготовке доступно удаление сохранённых данных. В web данные привязаны к origin:
для проверки reload использовать тот же localhost/порт. Приватное окно/очистка
браузера могут удалить настройки. Формат версии 1 и стратегия — ADR 0002.
`packages/game-content` одновременно является npm workspace
для валидации и Flutter-пакетом `partybox_game_content` для доставки assets.
Мобильный клиент использует ключ `packages/partybox_game_content/packs/spy-ru-base.json`;
widget-тест проверяет asset manifest и чтение JSON. Не создавайте вторую ручную копию контента.

## Проверка локальной партии

`make check-mobile` запускает анализ, тесты ядра и widget-тесты. Они покрывают полный
цикл, повтор, передачу, двойное нажатие, скрытие роли в фоне, восстановление deadline,
отмену подготовки и экран 320×640 с масштабом текста 2.

Integration-тест использует тот же полный пользовательский сценарий с реальным
встроенным набором. На подключённом Android/iOS-устройстве или эмуляторе:

```sh
cd apps/mobile
flutter devices
flutter test integration_test/local_game_test.dart -d <device-id>
```

Этот запуск выполняется отдельно от `make check-mobile`: нужен платформенный SDK
и устройство. CI пока запускает только ядро/widget-тесты. Для ручной приёмки:
четыре человека проходят цикл без интернета; при открытой роли свернуть приложение,
вернуться и убедиться, что карточка закрыта; во время обсуждения уйти в фон дольше
выбранного времени и проверить переход к выбору подозреваемого. Проверить также
системный «Назад»: во время партии нужен диалог, отмена оставляет роль закрытой.

## Превью выбранного дизайна PB-015

```sh
make preview-mobile
```

Открыть http://localhost:8716. Это настоящий локальный игровой цикл Flutter
в web host; сервер игры не требуется. Сборка использует локальные fonts/CanvasKit
и отключает service worker, чтобы изменения не скрывались кешем старой версии.
Если ранее запускали старое web-превью с service worker, один раз удалить данные
именно этого localhost origin в браузере или открыть приватное окно.
Для галереи компонентов в non-release режиме: `make gallery-mobile`, порт 8717.
Команды требуют Python 3 и Flutter в PATH. Сборка для web не заменяет Android/iOS.
Подробности: [DESIGN_SYSTEM](DESIGN_SYSTEM.md), [снимки и проверки](design/pb-015/verification.md).

## Нативные проекты

Android/iOS host-проекты сгенерированы Flutter 3.38.5. Временный namespace/bundle ID
начинается с `dev.partybox.prototype`; перед store-сборками заменить осознанно и
проверить deep links, подпись и developer accounts. Отображаемое название —
Вечеро (временное название); иконки пока шаблонные. Release-подпись ещё не настроена.

Изменения native-файлов проверяются настоящей сборкой нужной платформы, а не только
`flutter analyze`. Сборка Android: `flutter build apk --debug` из `apps/mobile` при
наличии SDK/JDK. iOS: `flutter build ios --no-codesign` на macOS с Xcode.

## Android APK для установки вручную

Для текущего Flutter 3.38.5 нужны Android SDK Platform 36, Build Tools 35.0.0,
NDK 28.2.13676358, CMake 3.22.1 и совместимый JDK (для этой сборки — Temurin 21).
Задайте JAVA_HOME и ANDROID_HOME для своей установки; SDK/кеши не входят в Git.
При конфликте Gradle file watcher в WSL можно задать
`GRADLE_OPTS=-Dorg.gradle.vfs.watch=false` для команды сборки.
После подготовки SDK и зависимостей:

```sh
cd apps/mobile
flutter build apk --release
```

Для переключения с тестов/debug на release не добавляйте `--no-pub`:
в Flutter 3.38.5 этот флаг также пропускает обновление native plugin registrant,
из-за чего там может остаться dev-плагин integration_test без release-класса.
GeneratedPluginRegistrant обновляется Flutter, вручную его не исправлять.

Результат: `build/app/outputs/flutter-apk/app-release.apk`. Без `--split-per-abi`
собирается один APK для всех включённых архитектур. Текущая release-конфигурация
использует debug-подпись: это оптимизированная тестовая сборка для телефона,
store-подпись ещё не настроена. Для обновления поверх установленной версии нужны
тот же app ID и тот же ключ; не удаляйте локальный debug.keystore между сборками.
Ключи в Git/каталог передачи APK не копировать. `local.properties` также игнорируется.

Готовые копии APK и SHA-256 хранить в `output/android/` (не коммитятся).
Перенести APK на телефон, открыть файловым менеджером и подтвердить установку.
Если Android запросит разрешение для этого источника, включить его в показанном
системном диалоге: [официальная инструкция](https://developer.android.com/studio/publish#publishing-website).
Проверка на устройстве: [протокол PB-020](playtests/PB-020-protocol.md).
Успешная сборка и проверка подписи не заменяют запуск и партию на телефоне.

## Git и совместная работа

Основная ветка `main`; рабочие ветки `feat/pb-010-local-session`, `fix/...`, `docs/...`.
Содержательное изменение → подходящие проверки → PR с кратким сценарием и результатом.
Инструкции одинаковы для человека и агента: [AGENTS.md](../AGENTS.md).
Для длительной работы — [шаблон плана](plans/TEMPLATE.md); передача результата через
`docs/STATUS.md`, а не через скрытую память конкретного агента.

Remote `origin`: `https://github.com/danilagarev/vechero.git`.
После публикации включить обязательные CI-проверки `node`, `flutter` и `https` для `main`.
CI не отправляет приложение в магазины. Подпись и deployment требуют отдельной настройки.

## Источники решений

- [Архитектура Flutter](https://docs.flutter.dev/app-architecture/guide).
- [Начало работы с NestJS](https://docs.nestjs.com/first-steps).
- [Инструкции Codex через AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
- [Гарантии доставки Socket.IO](https://socket.io/docs/v4/delivery-guarantees/).

## Серверное лобби PB-040

Локальная игра по-прежнему работает без backend. Сервер комнат — один процесс,
HTTP + Socket.IO; мобильное лобби и сетевой игровой цикл подключены через v2.
Для разработки PostgreSQL 16 можно поднять отдельно:

```sh
docker compose up -d --wait postgres
export DATABASE_URL=postgresql://partybox:partybox_dev@127.0.0.1:5432/partybox
```

Один раз создайте ROOM_TOKEN_SECRET командой `openssl rand -hex 32`, сохраните
в локальном `.env` вне Git и экспортируйте ту же переменную во всех запусках backend.
Не выводите ключ в отчёты. `.env` автоматически не загружается. Образец переменных —
`apps/backend/.env.example`. Пароль из Compose предназначен только для локального
loopback, для внешнего сервера задать собственные учётные данные и TLS.

```sh
npm run migrate --workspace @partybox/backend
make backend
```

Без DATABASE_URL health доступен, операции комнат возвращают 503. При наличии
DATABASE_URL требуется корректный ROOM_TOKEN_SECRET (64 hex-символа). Смена секрета
между запусками нарушает повторы регистрации; постоянство ключа обязательно.
Миграция повторяемая, выполняется отдельно; данные в Docker volume переживают рестарт.
`docker compose stop` останавливает БД с сохранением данных.

Контракты: `packages/game-contracts/schemas/rooms-v1.schema.json`, примеры
`examples/rooms-v1.json`, `openapi-rooms-v1.json`. Типы и OpenAPI обновляются только
через `npm run generate --workspace @partybox/game-contracts`.
REST: `POST /rooms`, `POST /rooms/join/{pin}`, `GET /rooms/{roomId}`,
`POST /rooms/{roomId}/commands` (пока только `room.leave`). Поля и ошибки — в OpenAPI;
PIN не заменяет Authorization. Имена после trim, максимум 40 символов.

Socket.IO использует стандартный `/socket.io` и handshake auth `{ roomId, guestToken }`.
События сервера: `room.snapshot` (схема Snapshot), `room.error` (схема Error).
Ошибка handshake приходит как `connect_error` со стабильным code в message.
После reconnect сервер отправляет актуальный snapshot; клиент игнорирует старые
версии и при пропуске перечитывает HTTP snapshot. Команды пока идут только по HTTP.
Нет presence-статуса: закрытие соединения не означает выход из комнаты.

```sh
export TEST_DATABASE_URL="$DATABASE_URL"
npm run check
```

Интеграционные тесты создают и удаляют отдельную случайную схему в тестовой БД;
роли БД нужно разрешение CREATE SCHEMA. Используйте отдельную БД для проверок.
Без TEST_DATABASE_URL серверная интеграционная группа явно пропускается;
health, форматирование, TS и тесты схем остаются доступны. В CI URL задан и пропуска нет.
Проверяются четыре независимых HTTP/Socket.IO-клиента, восстановление после
перезапуска приложения, идемпотентность, гонки, TTL, отзыв токена и лимиты PIN.
Сам Compose и физические телефоны этими тестами не проверяются.

## Мобильное лобби PB-040

После запуска PostgreSQL, миграции и backend из раздела выше:

```sh
cd apps/mobile
flutter run --dart-define=ROOM_SERVER_URL=http://10.0.2.2:3000
```

`10.0.2.2` — адрес хоста для Android Emulator. Для физического Android в debug
использовать доступный LAN IP компьютера и `HOST=0.0.0.0` у backend. Отдельный
ввод адреса в приложении не нужен. В release указывать настоящий HTTPS origin:

```sh
flutter build apk --release --dart-define=ROOM_SERVER_URL=https://your-room-server.example
```

Заменить пример своим сервером. Адрес должен быть origin без пути, query,
userInfo и токенов; редиректы не поддерживаются. Без ROOM_SERVER_URL каталог
остаётся локальным. В этом репозитории публичный сервер ещё не развёрнут.
HTTP разрешён только в debug Android; release и iOS ATS не ослаблены.
Для iOS нужен доступный HTTPS backend и обычная сборка на macOS/Xcode.

Каталог → «Комната “Шпиона”» → имя → создать либо код из шести цифр → состав.
Каждый телефон хранит собственный доступ в secure storage. Назад в каталог
сохраняет место; «Выйти из комнаты» требует подтверждения и освобождает его.
После закрытия/повторного открытия лобби клиент восстанавливает своё место.
При потере ответа «Повторить» сохраняет прежний requestId/commandId. Если очистка
хранилища не удалась, новый вход блокируется до её успешного повтора.
«Удалить доступ с телефона» забывает сохранение, но не удаляет участника на сервере.
Восстановить чужое место по одному PIN нельзя. Ведущий может начать сетевую
партию после входа четырёх участников. Каждый подтверждает собственную карточку;
потом идут обсуждение, устное голосование, выбор ведущего, результат и повтор.

Токены и pending-запросы — отдельный ключ SecureRoomVault; обычное удаление
локальной подготовки «Шпиона» их не затрагивает. В browser preview доступ хранится
только в памяти. Сетевой browser-сценарий с CORS не проверен; целевые клиенты —
Android/iOS. Физическая проверка Keystore/Keychain ещё открыта.

Отдельная проверка настоящих Dart-клиентов (backend уже запущен):

```sh
cd apps/mobile
ROOM_TEST_SERVER=http://127.0.0.1:3000 flutter test test/rooms/room_server_test.dart
```

Для этого использовать только локальную тестовую БД/сервер: тест создаёт комнату,
четырёх участников и затем выводит их. Проверяет потерянный ответ регистрации,
восстановление, Socket.IO, фон/возврат и передачу ведущего. Лимиты сервера остаются
включены; при частых повторных запусках дождаться следующего минутного окна.
Без ROOM_TEST_SERVER этот opt-in тест явно пропускается. Остальные мобильные
проверки работают без backend. Весь набор с сервером:

```sh
ROOM_TEST_SERVER=http://127.0.0.1:3000 make check-mobile
```

Эта команда выполняется из корня репозитория. Схема Dart обновляется вместе с
TS/OpenAPI через `npm run generate --workspace @partybox/game-contracts`;
generated-файл вручную не редактировать. Общие примеры версии 1 проверяются
в Node и Dart. Новый эталон лобби — `apps/mobile/test/rooms/goldens/lobby.png`.

## Полная сетевая партия PB-040

Новый Flutter-клиент использует `/v2/rooms` и GameCommand v2. Лобби v1 совместимо;
старые токены восстанавливаются. Для старта всем участникам нужно открыть комнату
в новой версии приложения. На четырёх телефонах: один создаёт, остальные входят
по PIN → ведущий выбирает 3–15 минут → «Начать партию» → каждый открывает и
подтверждает роль → обсуждение → ведущий завершает его или ждёт серверный deadline →
выбирает подозреваемого → результат → «Сыграть ещё». Ведущий может отменить раунд.
Вход новых участников закрыт до результата/лобби. Явный выход отменяет активный
раунд; disconnect сохраняет место и роль. После возврата карточка закрыта.

`ROOM_TEST_SERVER=... flutter test test/rooms/room_server_test.dart` теперь проходит
полный раунд четырьмя Dart-клиентами, включая потерю ответа регистрации, возврат
из фона, роли, подтверждения, результат и передачу ведущего. Backend-тест отдельно
проверяет 12 клиентов за одним IP, конкурентные команды, серверный deadline,
перезапуск процесса, повтор и изменённый повтор, попытку не-ведущего начать игру.
Ни эти тесты, ни release APK не заменяют физическую приёмку Android/iOS.

Контракты: `rooms-v2.schema.json`, `examples/rooms-v2.json`, `openapi-rooms-v2.json`.
Общие векторы: `packages/game-contracts/vectors/spy-v1.json`, запускаются в Node
и чистом Dart. Все generated TS/Dart/OpenAPI-файлы обновляет общая generate-команда.
Публичный backend здесь не развёрнут; сборка без ROOM_SERVER_URL остаётся локальной.

## HTTPS и проверка развёртывания

[Комплект VPS/HTTPS](deploy/VPS.md) собирает образ с чистым npm ci и ограниченным
build context. Caddy → backend → PostgreSQL; миграция завершается до готовности
приложения. `/ready` учитывает БД/таблицы, `/health` остаётся независимым.
Истёкшие комнаты и IP-счётчики удаляются backend автоматически.
`TRUST_PROXY_HOPS=0` по умолчанию игнорирует forwarded headers; значение 1 допустимо
только за одним доверенным прокси с приватным backend.

Из корня: `node deploy/smoke.mjs`, либо с Flutter
`FLUTTER_BIN=/path/to/flutter/bin/flutter node deploy/smoke.mjs`.
Второй вариант проходит полный раунд четырьмя Dart-клиентами по настоящему HTTPS,
с явным тестовым CA и без отключения TLS. Проверяет Node-клиенты, миграцию,
readiness, restart backend/БД, сохранение дедлайна и запрет подмены IP.
Секреты/volumes smoke изолированы и удаляются. CI job https запускает тот же сценарий.
Ни публичный сервер, ни четыре физических телефона этот smoke не подменяет.
