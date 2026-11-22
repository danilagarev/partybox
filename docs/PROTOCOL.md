# Сетевой протокол: лобби v1 и проект игровой сессии

## Актуальное дополнение: личное голосование v5

Уточнение PB-053: порядок JSON-полей `spy.ballot` и `clues.answer` не влияет
на повтор принятой команды; учитываются fingerprints обеих ранних форм записи.
При входе нового участника завершённая партия очищается в той же транзакции,
включая «Шпиона», поэтому старый клиент получает работоспособный доступ к лобби.
Лимит ответа «Что объединяет?» в TS/Dart и UI считается по 120 кодовым точкам
Unicode, как `maxLength` в JSON Schema, а не по единицам UTF-16.

[Схема](../packages/game-contracts/schemas/rooms-v5.schema.json),
[примеры](../packages/game-contracts/examples/rooms-v5.json),
[OpenAPI](../packages/game-contracts/openapi-rooms-v5.json).
HTTP `/v5/rooms` и Socket.IO `protocolVersion: 5` сохраняют возможности v4.
Новая команда `spy.ballot` принимает `{round, suspectId}` в обычном envelope
с `sessionId` и `commandId`. Игрок определяется по токену.

`spy.start` v5 требует v5 у всех участников и создаёт личное голосование.
В фазе voting `publicState.game.voting` содержит `round`, `candidateIds`,
`votedIds`; `privateState.ballot` присутствует только у проголосовавшего и
содержит его `round` и `suspectId`. После всех голосов уникальный лидер
становится подозреваемым результата. Ничья увеличивает round, сужает кандидатов
до лидеров и очищает голоса без раскрытия ролей. Голосуют все; выбор себя разрешён.

Повтор commandId возвращает сохранённый ack. Другой голос того же игрока
в том же туре отклоняется. Чужие параллельные голоса могут увеличить room version:
отставший expectedVersion допускается только для `spy.ballot` текущего тура
и сессии. Поздний голос предыдущего тура, чужой кандидат и другая sessionId
отклоняются. Личный выбор и ack сохраняются атомарно в PostgreSQL; во Flutter
выбор остаётся в памяти и восстанавливается через персональный snapshot.

В индивидуальной партии `spy.accuse` отклоняется на всех версиях endpoint.
Чтение v2–v4 требует обновить клиент. Старые партии продолжают устный режим;
локальная игра на одном телефоне не меняется. Для v5 действуют такие же
лимиты IP/участника, как для v4. [Решение](adr/0013-spy-personal-voting.md).

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

## PB-031 — вторая игра, протокол v3

Решение — [ADR 0007](adr/0007-tolerance-and-protocol-v3.md),
правила — [«Шкала терпения»](GAME_RULES.md#шкала-терпения--pb-031).
Новый клиент использует `/v3/rooms`, `/v3/rooms/join/{pin}`,
`/v3/rooms/{roomId}` и `/v3/rooms/{roomId}/commands`;
Socket.IO auth содержит protocolVersion=3. v1/v2 продолжают обслуживаться.
Источник формата — `packages/game-contracts/schemas/rooms-v3.schema.json`;
TS/Dart/OpenAPI обновляются общей командой генерации.

Snapshot v3 сохраняет поля «Шпиона» и добавляет publicState.tolerance и
privateTolerance верхнего уровня. В лобби и во время «Шпиона» они равны null.
Во время новой игры publicState.game и privateState равны null. Публичное состояние
содержит sessionId, phase, roundIndex, heroId, четыре исходные cards, targetId,
visibleOrder (три ID после подтверждения героя), submittedIds, scores, result,
winners. До раскрытия result=null. В ranking visibleOrder пуст: нельзя восстановить
порядок героя из публичного состояния. privateTolerance содержит только собственные
order или guess, остальные значения null. На reveal/finished полный порядок и
догадки становятся общими.

Envelope команды: protocolVersion=3, commandId, expectedVersion, sessionId,
type, payload. sessionId указывает текущую игру либо null в лобби.

- tolerance.start `{}` — ведущий начинает партию, 4–12 участников с поддержкой v3.
- tolerance.rank `{ order: [id, id, id, id] }` — герой подтверждает перестановку
  четырёх карточек в ranking. Дубликаты и чужие ID отвергаются серверными правилами.
- tolerance.guess `{ position: 0..3 }` — каждый кроме героя отвечает один раз в
  guessing. Последний ответ атомарно раскрывает раунд и обновляет счёт.
- tolerance.next `{}` — ведущий переходит из reveal к следующему герою либо finished.
- tolerance.cancel `{}` — ведущий возвращает комнату в лобби.
- spy-команды и room.leave сохраняют свои назначения.

Формат v3 и поддержка участников не заменяют авторизацию: actor определяется токеном,
сервер проверяет фазу, версию, партию и полномочия. Во время незавершённой партии
новые участники не входят. Выход через любой поддерживаемый протокол отменяет её.
Принятый commandId повторяется до проверки текущей версии и не начисляет очки снова.

Порядок/догадки не записываются в ожидающую команду на телефоне. Неопределённый
ответ вызывает синхронизацию: принятый выбор виден в личной проекции; непринятый
потребует нового явного подтверждения. Старые сохранённые команды v1/v2
повторяются через свои endpoints до перехода к чтению v3.

## Клиентская готовность и браузерный транспорт PB-041

Сервер по-прежнему отвергает устаревшую версию команды. Для spy.ready клиент
после определённого VERSION_CONFLICT перечитывает snapshot и завершает исходное
подтверждение в той же сессии без второго нажатия: уже принято — заканчивает,
ещё distribution — отправляет новую команду с новой версией и ID. Число попыток
ограничено числом участников; смена сессии/фазы или уход в фон прекращают новые
попытки. Между такими попытками WebSocket не переподключается. Неопределённый
ответ сохраняет прежний ID, прочие команды не получают автоматической новой попытки.

Браузерные запуски используют один origin для статики, HTTP и Socket.IO.
SessionRoomVault хранит только доступ и разрешённую retry-метаинформацию в
sessionStorage; секретные действия новой игры, роли и snapshot туда не пишутся.
Подробнее — [ADR 0008](adr/0008-browser-play.md).

## PB-048 — «Что объединяет?», протокол v4

Источник: `packages/game-contracts/schemas/rooms-v4.schema.json`, примеры
`examples/rooms-v4.json`, generated TS/Dart/OpenAPI. Endpoint-префикс `/v4/rooms`,
Socket.IO auth protocolVersion=4. v1/v2/v3 продолжают работать. Новая игра требует
v4 у всех активных участников; у «Шпиона»/«Шкалы» прежние минимумы версий сохранены.

Snapshot v4 добавляет `publicState.clues` и верхний `privateClues`. Игра содержит
sessionId, phase(playing/reveal/finished), roundIndex0..4, roundCount5,
clueIndex0..3, только открытые clues, solvedIds, attemptedIds текущей подсказки,
scores, result и winners. Другие игровые поля null. В playing result=null,
privateClues содержит только собственный последний answer/clueIndex/correct/points.
В reveal/finished privateClues=null, result раскрывает canonical answer и ответы
всех участников, включая null у неответивших. Неоткрытые подсказки не отправляются.

- `clues.start {}` — ведущий, 1–12 участников, пять неповторяющихся заданий.
- `clues.answer {answer,clueIndex}` — один ответ на открытый уровень, 1–120 символов;
  неверный ответ можно повторить после следующей подсказки. Верный фиксирует очки.
- `clues.hint {}` — ведущий открывает следующую подсказку; на последней явно
  завершает раунд. UI требует подтверждения преждевременного раскрытия.
- `clues.next {}` — ведущий переводит reveal в новое задание или finished.
- `clues.cancel {}` — ведущий возвращает всех в лобби.

Сохраняются checks actor/token, expectedVersion, sessionId, phase и атомарный ack.
Повтор принятого commandId не начисляет очки повторно. Дополнительно payload
clueIndex запрещает засчитать ответ за уже сменившуюся подсказку. Клиент не пишет
answer в persisted pending-команду: после неопределённой сети читает состояние.
Достоверный VERSION_CONFLICT допускает ограниченный повтор только той же попытки
в той же сессии/задании/подсказке. Фон/disconnect удаляют черновик с экрана.

Выход через старый протокол тоже отменяет активную новую игру. Вход после итогов
очищает завершённую партию перед изменением состава. Content/version выбранных
заданий сохраняются внутри JSONB комнаты; миграция таблиц не требуется.

Чтобы компания за одним Wi-Fi не блокировала сама себя, v4 использует отдельные
IP-бакеты720/мин для HTTP snapshot и command плюс120/мин на каждого guest.
Socket v4:360/мин на IP плюс60/мин на проверенного гостя. Create10/join30 и
прежние лимиты1/2/3 сохранены. В БД находятся только HMAC-ключи и счётчики.
