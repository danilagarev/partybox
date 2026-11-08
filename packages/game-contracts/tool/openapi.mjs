import { format } from 'prettier';
import { readFile, writeFile } from 'node:fs/promises';
const schema = JSON.parse(
  await readFile(new URL('../schemas/rooms-v1.schema.json', import.meta.url), 'utf8'),
);
const convert = (value) =>
  JSON.parse(JSON.stringify(value).replaceAll('#/$defs/', '#/components/schemas/'));
const ref = (name) => ({ $ref: `#/components/schemas/${name}` });
const json = (schema) => ({ 'application/json': { schema } });
const error = (description) => ({ description, content: json(ref('Error')) });
const responses = (name, created = false) => ({
  [created ? '201' : '200']: { description: 'Успех', content: json(ref(name)) },
  400: error('Некорректный запрос'),
  401: error('Требуется токен участника'),
  404: error('Комната недоступна'),
  409: error('Конфликт команды, версии или заполненная комната'),
  410: error('Комната закрыта или истекла'),
  413: { description: 'JSON больше 8 KiB; стандартный ответ HTTP middleware' },
  429: error('Превышен минутный лимит'),
  503: error('Сервис комнат недоступен'),
});
const roomParameter = {
  in: 'path',
  name: 'roomId',
  required: true,
  schema: { type: 'string', format: 'uuid' },
};
const body = (name) => ({ required: true, content: json(ref(name)) });
const authenticated = [{ guestToken: [] }];
const spec = {
  openapi: '3.1.0',
  info: {
    title: 'PartyBox — комнаты',
    version: '1.0.0',
    description:
      'Только серверное лобби PB-040. Игровые команды ещё не реализованы. JSON ≤ 8 KiB. TLS обязателен вне localhost. Не логировать Authorization, retryKey, guestToken и тела запросов.',
  },
  paths: {
    '/rooms': {
      post: {
        operationId: 'createRoom',
        description:
          '10 запросов/мин/IP. requestId UUID v4 и retryKey из 32 случайных байт base64url сохраняются клиентом до ответа; повторить без изменений при потере ответа. Комната на 24 часа.',
        requestBody: body('Enrollment'),
        responses: responses('EnrollmentResult', true),
      },
    },
    '/rooms/join/{pin}': {
      post: {
        operationId: 'joinRoom',
        description:
          '30 запросов/мин/IP, включая несуществующие PIN. PIN создаёт нового участника, токен восстанавливает прежнего. 1–12 участников в лобби.',
        parameters: [
          {
            in: 'path',
            name: 'pin',
            required: true,
            schema: { type: 'string', pattern: '^[0-9]{6}$' },
          },
        ],
        requestBody: body('Enrollment'),
        responses: responses('EnrollmentResult', true),
      },
    },
    '/rooms/{roomId}': {
      get: {
        operationId: 'roomSnapshot',
        description:
          '120 запросов/мин/IP. Актуальная публичная часть и только собственная личная часть; Cache-Control: no-store.',
        security: authenticated,
        parameters: [roomParameter],
        responses: responses('Snapshot'),
      },
    },
    '/rooms/{roomId}/commands': {
      post: {
        operationId: 'leaveRoom',
        description:
          '120 запросов/мин/IP. Только room.leave. commandId сохраняется до ack; accepted-результат дедуплицируется до проверки версии. Изменённый payload с тем же ID даёт COMMAND_CONFLICT. Повтор принятого выхода разрешён даже от вышедшего участника, до TTL. Явный выход передаёт ведущего следующему по порядку входа. Отказ не сохраняется как принятый ack.',
        security: authenticated,
        parameters: [roomParameter],
        requestBody: body('LeaveRoom'),
        responses: responses('Ack', true),
      },
    },
  },
  components: {
    securitySchemes: { guestToken: { type: 'http', scheme: 'bearer' } },
    schemas: convert(schema.$defs),
  },
};
await writeFile(
  new URL('../openapi-rooms-v1.json', import.meta.url),
  await format(JSON.stringify(spec), { parser: 'json', printWidth: 100 }),
);
