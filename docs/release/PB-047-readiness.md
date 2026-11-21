# PB-047 — готовность Android/iOS к магазинам

Проверено 2026-11-21. Это технический аудит и инструкция следующего релиза,
а не подтверждение допуска Google Play или App Store. Публикация, регистрация
приложений, создание ключей и изменение app IDs в эту работу не входят.

## Вывод

Приложение пригодно для продолжения телефонных тестов. Исходный
`partybox-test.apk` — debug-сборка 155 979 212 байт; её размер объясняется
отладочным Flutter runtime, тремя ABI и JIT-данными. Для телефона нужно выдавать
оптимизированный release APK под ABI устройства, для Play — подписанный AAB.
Размер APK сам по себе не измеряет RAM, плавность или установленный размер.

Пользователь попросил оставить контакты разработчика и policy незавершёнными.
До отправки в магазины остаются обязательные данные владельца, политика
конфиденциальности и проверка реальных нативных release-сборок. iOS в Linux
собрать и проверить нельзя. Юридические реквизиты и ответы магазинных анкет
за владельца не заполнены.

## Реальное содержимое старого APK

Измерен файл до пересборки. SHA-256:
`b715d92dab18fb8b7e83f0f6774f011cf5a303bca8c577949a7162c80ba800fa`.
ZIP CRC исправен. Полный размер — 155,98 MB / 148,75 MiB.

| Часть                           | Занимает в ZIP, байт | Причина                                      |
| ------------------------------- | -------------------: | -------------------------------------------- |
| `lib/arm64-v8a`                 |           52 106 280 | Debug engine, JNI, Vulkan validation         |
| `lib/x86_64`                    |           38 047 096 | Ещё один debug engine для другой архитектуры |
| `lib/armeabi-v7a`               |           31 337 424 | Ещё один debug engine для ARM32              |
| Flutter assets                  |           27 065 974 | Включая JIT/kernel и snapshots               |
| `classes.dex` + `classes10.dex` |            6 570 937 | Неоптимизированные JVM-зависимости           |

Только три native-каталога занимают 121 490 800 байт (77,9% APK).
Внутри них `libVkLayer_khronos_validation.so` — 15 253 960 байт.
`kernel_blob.bin` — 69 651 248 байт до сжатия / 22 035 535 в ZIP;
`isolate_snapshot_data` — 10 953 198 / 4 172 735 байт.
Это отладочные данные; удалять вручную файлы из APK нельзя.
Три Manrope-шрифта и игровой JSON несопоставимо меньше.

Фактический manifest: `dev.partybox.prototype.partybox`, версия `0.1.0 (5)`,
min SDK 24, target/compile SDK 36, `debuggable=true`, `allowBackup=false`.
`usesCleartextTraffic=true` приходит из debug overlay, а не main manifest.
Разрешения: INTERNET и собственное signature-разрешение
`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (AndroidX); камеры, микрофона,
контактов, геолокации, уведомлений и advertising ID нет.
Подпись — Android Debug, SHA-256 сертификата:
`d24cabb57d4c837d3b6c88a8c76d052fa11447ca0ed45a043ed3fd27eb617761`.

Проверки исходного APK: `aapt dump badging`, `aapt dump xmltree`,
`apksigner verify --print-certs`, `zipalign -c -P 16 4`, Python `zipfile.testzip()`.
Zipalign прошёл; это не заменяет ELF-проверку и запуск на 16 KiB устройстве.

## Компактная сборка для существующих тестеров

Скрипт [build-android-release.sh](../../scripts/build-android-release.sh) создаёт
release APK с AOT/tree shaking и отдельным runtime только своего ABI.
Существующий debug keystore обязателен: скрипт откажется создавать новый.
Не меняется идентификатор приложения; для обновления нужны тот же сертификат
и больший versionCode. Перед установкой нового файла сверить сертификаты.

Из корня репозитория с установленными SDK:

```bash
source .tools/android-toolchain/env.sh
export FLUTTER_BIN="$PWD/.tools/flutter/bin/flutter"
scripts/build-android-release.sh test-release 6 --universal
```

`.tools/` — локальная среда текущего workspace; для другой машины задать
собственные `FLUTTER_BIN`, `JAVA_HOME`, `ANDROID_HOME`. Не удалять старый
keystore при очистке build cache. Артефакты с SHA-256 появятся в
`output/android/test-release-6/`; они игнорируются Git.
Обычному современному Android-телефону нужен `partybox-arm64-v8a-test-release.apk`.
ARM32 — для старого телефона, x86_64 — преимущественно эмулятор.
Universal APK удобнее для неизвестного телефона, но снова содержит три ABI.
Без `--universal` сборка создаёт только три отдельных APK. Важно: wrapper
собирает каждую архитектуру через `--target-platform`, сохраняя один versionCode.
Обычный Flutter `--split-per-abi` добавляет 1000/2000/4000 к versionCode и
мешает последующему обновлению универсальным APK с меньшим номером.
Dart debug-символы вынесены в `symbols/` рядом с артефактами; хранить их для
`flutter symbolize`, в APK их не возвращать.

Режим test-release намеренно подписан debug-сертификатом, **не для магазина**.
Gradle получает явный `partyboxTestSigning=true`; обычный release без этого
флага требует локальный store keystore. Debug-запуск и тесты не требуют ключа
публикации. Оптимизация release не означает готовность магазинных документов.

Для распределения сравнивать фактические APK-байты; для магазинной загрузки —
оценку Play Console/bundletool под конкретное устройство. AAB не устанавливается
на телефон напрямую; он содержит все ABI, а магазин формирует нужные APK.
Установленный размер дополнительно включает native-код, данные, кеш и ART.
RAM/плавность проверяются отдельно на устройстве в profile/release через DevTools
и Android profiler. Замер debug и браузера не подтверждает нативную производительность.
[Flutter: размер](https://docs.flutter.dev/perf/app-size),
[сборки Android](https://docs.flutter.dev/deployment/android).

## Актуальные технические пороги

| Магазин   | Официальное требование на дату аудита                                                                                | Состояние проекта                                                                        |
| --------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Play      | Новые приложения/обновления с 2026-08-31: Android 16 / API 36+                                                       | Старый APK уже target36; проверять каждый новый artifact                                 |
| Play      | Поддержка 16 KiB страниц для API35+; текущая документация указывает блокировку несовместимых обновлений с 2027-02-01 | AGP8.11.1 подходит; нужны ZIP+ELF и реальное устройство                                  |
| App Store | С 2026-04-28: Xcode26+ и iOS26 SDK+                                                                                  | На Linux не проверено; Flutter3.38.5 не доказывает совместимость со всеми будущими Xcode |
| App Store | С 2026-09-09 minimum deployment iOS13+                                                                               | Проект iOS13.0; проверка плагинов и archive на macOS впереди                             |

Источники:
[Google target API](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en),
[Android 16 KiB](https://developer.android.com/guide/practices/page-sizes),
[Apple upcoming requirements](https://developer.apple.com/news/upcoming-requirements/).
В актуальной статье Android срок отличается от старых публикаций 2025 года;
при отправке заново открыть первоисточник. ZIP alignment проверяется
`zipalign -c -P 16 4`; для каждого `lib/arm64-v8a/*.so` и `lib/x86_64/*.so`
нужно проверить ELF `LOAD` alignment >= 2**14 через `readelf -lW`/официальный
`check_elf_alignment.sh`, затем запуск на системе `adb shell getconf PAGE_SIZE`
со значением `16384`. Для store AAB отдельно проверить `PAGE_ALIGNMENT_16K`
через `bundletool dump config` и созданные из AAB APK.

## Подпись и iOS packaging

Android debug fallback заменён явным тестовым режимом. Для store нужны настоящие
локальные `apps/mobile/android/key.properties` по
[образцу](../../apps/mobile/android/key.properties.example) и существующий
keystore владельца. Пароли и ключи уже исключены из Git. `storeFile` — абсолютный
путь либо путь относительно `apps/mobile/android`. Команда после настройки:

```bash
scripts/build-android-release.sh store-aab 7
```

Номер 7 — пример следующего выпуска, нужно выбрать больше уже выпущенных номеров.
Перед upload сверить signing certificate с выбранным upload key, убедиться,
что debuggable=false и настроить Play App Signing. Debug key не переносится
в production. Store-подпись обычно не обновит установленную debug-версию;
миграцию тестеров планировать отдельно, предупреждая о потере локальных данных
при удалении приложения. Package name в Play постоянен, поэтому решение о
`dev.partybox.prototype.partybox` принимается **до** первой регистрации.
Такой ID синтаксически допустим; слово prototype само по себе не нарушение.
[Play: создание и подпись](https://support.google.com/googleplay/android-developer/answer/9859152?hl=en).

В iOS team, provisioning profiles и distribution certificate не настроены.
Добавлены Podfile из закреплённого Flutter3.38.5 и optional Pods xcconfig includes:
`flutter_secure_storage9.2.4` использует CocoaPods и не имеет Swift Package.
Это воспроизводимая подготовка; Flutter на macOS также умеет создать эти файлы
автоматически. Ни `pod install`, ни Xcode archive здесь не запускались.
Не утверждаем, что исходное отсутствие Podfile неизбежно ломало Flutter build.

На macOS: закреплённый Flutter → `flutter pub get --enforce-lockfile` →
`cd ios && pod install` → открыть `Runner.xcworkspace`, выбрать действительную
Team/Bundle ID → `flutter build ipa --release --build-number <новый номер>` →
Validate App в Xcode → TestFlight после разрешения владельца.
Нужно проверить плагины, Keychain (запись/чтение/очистка гостевого токена,
перезапуск/блокировка), ATS/HTTPS, доступность, iPhone/iPad и privacy report.
[Flutter: iOS](https://docs.flutter.dev/deployment/ios).

У плагинов уже есть privacy manifests: `shared_preferences_foundation2.5.7`
декларирует UserDefaults с причиной `1C8F.1`, `flutter_secure_storage9.2.4` —
свой manifest. Поэтому отсутствие отдельного app `PrivacyInfo.xcprivacy`
само по себе не доказывает нарушение. Проверить **состав собранного archive**,
privacy report Xcode и необходимые причины API; не добавлять фиктивные причины
или декларацию «данные не собираются» в обход аудита backend.
[Apple: required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

## Данные, конфиденциальность и удаление

В приложении пока нет доступной политики конфиденциальности и подтверждённых
публичных privacy/support URL. Это блокирует отправку: политика нужна обоим
магазинам даже без рекламы и аналитики; Apple требует ссылку внутри приложения,
Google допускает внутри приложения ссылку либо текст. Нужны реальные сведения
владельца, privacy contact, цели обработки, получатели, безопасность, сроки
хранения/удаления и доступный HTTPS URL. Нельзя подставить выдуманный email.
[Google User Data](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en),
[Apple review](https://developer.apple.com/app-store/review/guidelines/).

Фактическая карта для подготовки анкет, **не готовые юридические ответы**:

| Данные                                                    | Где и зачем                                            | Реальное удаление/ограничение                                                                 |
| --------------------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Локальные имена/пакет/время                               | SharedPreferences, подготовка Pass & Play              | Кнопка очистки подготовки; активные секреты не сохраняются                                    |
| Адрес выбранного сервера                                  | Локальные настройки                                    | Смена адреса/сброс; учесть сервер, выбранный пользователем                                    |
| Guest token/retry credentials                             | Secure storage, возврат в комнату                      | Локальная очистка не равна удалению PostgreSQL                                                |
| Имя участника, случайный player ID, room/игровые действия | HTTPS/Socket.IO → PostgreSQL, сетевой игровой сценарий | Комната истекает через 24 часа **с создания**, затем cleanup; не «через 24 часа после выхода» |
| IP/защита от перебора                                     | Сервер видит IP; rate limit хранит HMAC-ключ           | TTL записи rate limit; реальные Caddy/host-логи и backups проверить владельцу                 |

`room.leave` помечает участника `left`, оставляет имя/идентификатор для состояния
и идемпотентности до удаления комнаты. Это **не** немедленное стирание серверных
персональных данных. Retention backups и инфраструктурных логов в policy нельзя
приравнивать к TTL основной БД без подтверждения владельца.
Нет интегрированных SDK рекламы/аналитики/crash reporting; наличие сети и
псевдонимных идентификаторов всё равно исключает автоматический ответ
«данные не собираются». Данные в PostgreSQL на 24 часа не ephemeral processing
в смысле Play (там речь о кратком хранении в памяти для текущего запроса).
Data safety нужна closed/open/production tracks; исключительно internal track
освобождён от этой анкеты.
[Google Data safety](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).

**Отдельное решение до store submission — гостевой участник и удаление.** Apple
прямо пишет про automatically generated/guest accounts:
“People should have the option to delete automatically generated accounts”.
В PartyBox участник привязан к одной временной комнате, нет постоянного профиля
или общего аккаунта между устройствами. Применимость определения account к
этому механизму требует осознанного решения, а не утверждения о гарантированном
отказе. Если гостевой участник считается account, одного leave+TTL недостаточно:
нужен доступный путь запроса удаления с понятными сроками, для Google также
веб-путь. Даже если это только временная сессия, policy должна точно описывать
retention и механизм запроса удаления. Не обещать hard delete, которого нет.
[Apple: guest accounts](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion),
[Google: определение account и удаление](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).

## Что нужно владельцу и физической приёмке

1. Название PartyBox подтверждено пользователем; Android/iOS display labels
   обновлены без смены технических IDs. Подтвердить Android package/iOS Bundle ID, регионы,
   владельца/контакты и условия распространения. Developer accounts/agreements
   и права на название не проверяются локальным build.
2. Разместить настоящую privacy policy/support, добавить доступ к policy в UI;
   согласовать retention и трактовку временного гостя; заполнить Data safety,
   App Privacy, encryption/export compliance и content rating по фактам.
3. Завершить launcher/store assets и сделать снимки **текущего приложения**.
   До PB-047 Android launcher совпадал с Flutter template (проверен SHA-256).
   В PB-047 шаблонные иконки заменены собственным SVG-знаком «Полночного клуба»:
   Android mipmap, iOS AppIcon, PNG 512/1024 для магазинов. Подготовлены
   [мастер и экспорт](../../apps/mobile/assets/branding/partybox-icon.svg);
   установку на launcher проверять на устройстве в итоговой сборке.
4. Продукт рассчитан на взрослую компанию; согласованное направление карточек —
   бытовые взрослые ситуации без explicit-контента. Это не подтверждает
   автоматически ни низкий рейтинг, ни обязательные 18+: заполнить анкету по
   **фактически вошедшему** контенту, включая бар/алкоголь, отношения, грубые
   формулировки, пользовательские имена и социальные функции. Если владелец
   выбирает минимальную аудиторию 18+, применить доступный override рейтинга
   и согласовать с текстом магазина; не отмечать приложение «для детей».
   Само упоминание бытовых взрослых отношений не равно наличию dating-сервиса.
   У Apple новая шкала 4+/9+/13+/16+/18+; с ноября 2026
   появились вопросы Shared Location и Dating and Relationships. Игровая
   «локация» не означает доступ к геолокации, анкета заполняется по функциям.
   [Рейтинг](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/),
   [новые вопросы](https://developer.apple.com/help/app-store-connect/release-notes/).
5. Подготовить review notes на русском/английском: создать комнату без аккаунта,
   три дополнительных устройства/участника для сетевой партии, 4 имени для
   локальной. Не выдавать короткоживущий PIN за постоянный demo access. Backend
   должен быть доступен ревьюеру весь период; отдельный demo-режим сейчас не
   реализован. По [Apple 2.1](https://developer.apple.com/app-store/review/guidelines/)
   нужны полная функциональность и понятный доступ ревьюеру.
6. Пройти Android release install/update поверх code5 с тем же сертификатом,
   локальный offline цикл, обе сетевые игры, reconnect/фон/убийство процесса,
   privacy/очистку, TalkBack/крупный шрифт/маленький экран, low-end performance.
   На iOS отдельно TestFlight/iPhone/iPad/VoiceOver/Keychain/ATS. Автоматические
   widget/server-тесты не заменяют этих действий.
7. Play Console internal → closed → production только после закрытия пунктов.
   Для personal account, созданного после 2023-11-13, нужен closed test минимум
   12 testers continuously opted-in 14 дней и заявка на production access.
   Статус/возраст аккаунта владельца неизвестен; не обещать мгновенный выпуск.
   [Google testing](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en).

## Проверено в этой части работы

Исходный debug APK: ZIP CRC/состав/размер, native ABI, manifest, сертификат,
16 KiB ZIP alignment. `bash -n` и `--help` release wrapper; отрицательный
`store-aab 6` без ключей отказывает до сборки. Gradle/release-build проверяются
интегратором в итоговой проверке; здесь параллельные Flutter build не запускались.
Ruby/CocoaPods/macOS/Xcode, магазинные аккаунты, физические устройства,
установленный размер/RAM и store upload в этой Linux-сессии не проверены.

## Итоговые проверочные APK 0.1.0+6

Все варианты собраны в release, подписаны **прежним тестовым** сертификатом,
versionCode=6, app ID сохранён. Обычный store build по-прежнему требует ключей.

| Вариант                               |       Байт | Уменьшение относительно debug +5 |
| ------------------------------------- | ---------: | -------------------------------: |
| partybox-arm64-v8a-test-release.apk   | 17 846 839 |                            88.6% |
| partybox-armeabi-v7a-test-release.apk | 15 261 287 |                            90.2% |
| partybox-universal-test-release.apk   | 50 016 989 |                            67.9% |
| partybox-x86_64-test-release.apk      | 19 263 603 |                            87.6% |

Универсальный файл скопирован атомарно в `partybox-test.apk`, ARM64 — в
`partybox-arm64.apk`. Оригиналы, `SHA256SUMS`, `build-info.json` и Dart `symbols/`
хранятся в игнорируемом `output/android/test-release-6/`. Все APK проверены:
CRC, подпись v2/тот же certificate SHA256, versionCode6, min24/target36,
PartyBox label, debuggable=false, отсутствие cleartext override и JIT/kernel/
Vulkan validation, ровно заявленные ABI. AOT каждой архитектуры совпадает между
single-ABI и universal, поэтому сохранённые symbols применимы к обоим вариантам.
В APK входят три Spy pack по60; «Шкала» получает контент с сервера.
Production origin найден в AOT; приоритет сохранённого origin сохранён.
Для всех 64-bit `.so` проверен ELF LOAD alignment >=16384; ZIP alignment16K прошёл.
Физический запуск на системе с PAGE_SIZE16384 не выполнялся.

Реальный Gradle task graph подтвердил: assembleRelease без store signing
отклоняется, release unit test dry-run без store signing проходит.
Расход RAM, установленный размер, native touch/haptics/TalkBack/VoiceOver,
iOS archive и одобрение магазинов этими проверками не подтверждаются.

Для локального получения с телефона в той же сети раздача двух известных APK
доступна на порту8724. Она не публикует содержимое каталога или другие файлы.
