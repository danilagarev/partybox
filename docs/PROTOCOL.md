# Сетевой протокол: лобби v1 и проект игровой сессии

## Реализовано: серверное лобби PB-040

Flutter-клиент поддерживает лобби при заданном ROOM_SERVER_URL. Сервер поддерживает
лобби v1 и игровые команды v2, описанные ниже. Источник формата — [JSON-схема v1](../packages/game-contracts/schemas/rooms-v1.schema.json),
[примеры](../packages/game-contracts/examples/rooms-v1.json),
[OpenAPI](../packages/game-contracts/openapi-rooms-v1.json),
[ADR 0003](adr/0003-rooms-and-guests.md). Generated-типы и OpenAPI обновляются
`npm run generate --workspace @partybox/game-contracts`.

- `POST /rooms`: создание; `POST /rooms/join/{pin}`: вход. Тело — protocolVersion=1,
  requestId UUID v4, retryKey (32 случайных байта base64url), name (1–40 символов,
  непустое после trim). Клиент сохраняет requestId+retryKey до ответа и повторяет
  их без изменений при потере ответа. Ответ — guestToken и snapshot текущей версии;
  повтор не добавляет участника. Изменённый повтор — COMMAND_CONFLICT.
- `GET /rooms/{roomId}` с `Authorization: Bearer <guestToken>` — snapshot.
  Поля: protocolVersion, roomId, version, serverTime, selfId, publicState,
  privateState=null. Публичны только PIN, ведущий, состав, фаза lobby и expiresAt.
- `POST /rooms/{roomId}/commands` с тем же заголовком: пока только room.leave.
  Envelope — protocolVersion, commandId UUID v4, expectedVersion, type, payload={}.
  Принятый ack сохраняется атомарно с изменением; повтор принятой команды проверяется
  раньше версии и возвращает прежний ack. Изменение команды с тем же ID — конфликт.
  Отказы не сохраняются как принятые команды. Ack: protocolVersion, commandId,
  accepted=true, version. HTTP-ошибка: protocolVersion и code.
- Socket.IO `/socket.io`, auth `{ roomId, guestToken }`; сервер отправляет
  `room.snapshot` персонально при подключении и изменениях состава. Reconnect
  всегда читает свежий snapshot; клиент игнорирует старую версию и перечитывает
  состояние при пропуске. `room.error` содержит protocolVersion и code и завершает
  соединение; отказ handshake — `connect_error`. Команды передаются по HTTP.

Комната живёт 24 часа с создания. Токен истекает вместе с комнатой; PIN не возвращает
прежнее место. Явный выход отзывает доступ и передаёт ведущего следующему оставшемуся
участнику по порядку входа. Последний выход закрывает комнату. Обрыв связи сохраняет
место и ведущего. Повтор собственного принятого выхода разрешён до TTL, даже после
закрытия. Лобби допускает 1–12 участников; минимум 4 потребуется при старте игры.

Лимиты на IP за минуту: создание 10, вход 30 (включая неизвестный PIN), snapshot 120,
команды 120, socket handshake 60. Счётчики в PostgreSQL переживают рестарт; автоматически
не доверяем X-Forwarded-For. JSON/Socket.IO payload ≤ 8 KiB. Ошибки JSON parser (400/413)
имеют стандартный HTTP-формат middleware. Ответы приложения — Cache-Control: no-store.
За пределами localhost нужен TLS; Authorization, retryKey и тела запросов не логировать.

Сейчас один backend-процесс, межпроцессная рассылка не реализована. Истечение
проверяется на каждом обращении и закрывает соединение по сроку. При старте и раз
в минуту удаляются истёкшие комнаты с registrations/ack и IP-счётчики; после удаления
ответ ROOM_UNAVAILABLE терминален, как и ROOM_EXPIRED. За одним доверенным приватным
прокси IP берётся из forwarded header только при явном TRUST_PROXY_HOPS=1. Без БД health остаётся доступен, комнаты отвечают 503.

## Реализовано: игра v2

Источник: [схема v2](../packages/game-contracts/schemas/rooms-v2.schema.json),
[примеры](../packages/game-contracts/examples/rooms-v2.json),
[OpenAPI v2](../packages/game-contracts/openapi-rooms-v2.json),
[ADR 0005](adr/0005-network-spy.md).

Новый клиент использует `/v2/rooms`, `/v2/rooms/join/{pin}`,
`/v2/rooms/{roomId}` и `/v2/rooms/{roomId}/commands`.
Enrollment отличается protocolVersion=2. Существующий токен продолжает работать;
незавершённая регистрация v1 повторяется через прежний endpoint. Чтение v2
фиксирует поддержку игры; старт отклоняется CLIENT_UPGRADE_REQUIRED, пока
не обновились все активные участники. Лобби v1 остаётся совместимым и не получает
секретов. Во время активного раунда вход новых участников закрыт.

Snapshot v2 содержит publicState.game: null в лобби либо sessionId, packId,
packVersion, phase, readyIds, deadline и result. До results result=null, в публичной
части нет выбранной локации и ID шпиона. privateState — только собственная карточка
(role, location); шпион получает location=null, результаты — privateState=null.
Socket.IO использует прежние события, auth добавляет protocolVersion=2;
на каждом соединении строится отдельная проекция. Snapshot/таймер могут применить
истёкший deadline; после commit переход рассылается всем соединениям комнаты.
Фоновый проход по дедлайнам восстанавливается после рестарта.

GameCommand: protocolVersion=2, commandId, expectedVersion, sessionId, type, payload.
До партии sessionId=null; в партии требуется текущий sessionId. Команды:

- spy.start: discussionMinutes (3–15), packId из встроенного каталога
  (`spy-ru-base`, `spy-ru-travel`, `spy-ru-unusual`), только ведущий,
  4–12 участников. После results создаёт новую партию с новым sessionId.
- spy.ready: пустой payload, подтверждение собственной роли, один раз.
- spy.vote: пустой payload, ведущий завершает обсуждение раньше.
- spy.accuse: suspectId из текущего состава, только ведущий в voting.
- spy.cancel: пустой payload, ведущий отменяет раунд.
- room.leave: пустой payload, участник выходит; активный раунд отменяется,
  ведущий передаётся следующему оставшемуся участнику.

Состав, приватные данные и ack изменяются в одной PostgreSQL транзакции.
Повтор принятой команды проверяется до версии/фазы/sessionId и возвращает прежний
ack. Изменённый payload с тем же ID даёт COMMAND_CONFLICT; actor берётся по токену.
Новый устаревший запрос — VERSION_CONFLICT, чужая партия — SESSION_CONFLICT,
недоступное полномочие — FORBIDDEN, незаконный этап — INVALID_PHASE.
Отказы не записываются как принятые ack. На клиенте неопределённый результат
повторяется с тем же ID; известный отказ обновляет snapshot и требует нового действия.

Сервер хранит секретную сессию в JSONB, фиксируя версию встроенного пакета.
Время и случайность передаются чистым правилам явно. Общие TS/Dart-векторы
проверяют переходы, deadline, недопустимые действия и обе победы.

Расширение PB-025 сохраняет формат протокола 2 и прежние примеры. packId теперь
проверяется как устойчивый ID, неизвестный серверу ID даёт INVALID_REQUEST (400).
Приватная история ротации по packId/version сохраняется в той же транзакции;
она не входит в snapshot. [ADR 0006](adr/0006-bundled-spy-catalog.md).
