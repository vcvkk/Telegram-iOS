<!-- Approved plan, not started. Precondition: master green on 12.9.2.
     Context and decisions: see HANDOFF.md section 8. -->

# Android-паритет: структура модулей exteraGram

## Context

Цель — чтобы пользователю, переходящему с exteraGram под Android, структура форка
была узнаваема. Задача разбивалась на две части; после разбора реального APK
(июль 2026) и декомпилированных исходников одна из них отпала.

**Что дал разбор APK.** Пользователь прислал APK (159 МБ) и декомпилированные
исходники от 14 июля 2026 — это актуальная версия, в отличие от гитхабовского
зеркала, которое стоит на июне 2023. Корневой пакет — `com.exteragram.messenger`,
в нём 25 топ-уровневых пакетов и ~430 файлов (против 9 пакетов и 51 файла в
версии 2023 года).

**Часть 1 — папки сохранения медиа: снята с задачи.** Разбор показал, что в
актуальной Android-версии медиа сохраняются в `Pictures/Telegram` и
`Download/Telegram`; имя exteraGram осталось только у альбома съёмки
(`AndroidUtilities.getAlbumDir` → `Pictures/exteraGram`) и у легаси-корня
`<ExternalStorage>/exteraGram/{exteraGram Images, exteraGram Video}`. То есть
раскладку 2023 года («exteraGram» везде) сами разработчики Android откатили.
Пользователь решил на iOS это не переносить: сохранение остаётся как есть, в
галерею без альбома. Хранение собственных данных форка (`Documents/EGPlugins` и
прочее) тоже остаётся как есть — оно видно в Файлах, если включить File Sharing
в Feather, и это ожидаемое поведение.

**Часть 2 — структура модулей: это и есть задача.** Сейчас форк держит 56 плоских
директорий в `exteraGram/`. Нужно превратить их в дерево
`exteraGram/messenger/<пакет>/`, повторяющее Android, слив мелкие Swift-модули в
один модуль на пакет (выбор пользователя из трёх вариантов).

**Ключевое ограничение — не сломать мерджи.** Форк регулярно подтягивает релизы
апстрима, и прошлый бамп (12.8) стоил 15 раундов CI. Поэтому переименование
обязано оставить работающими старые пути и метки. Настоящие симлинки директорий
для этого не годятся: Bazel-glob подхватил бы файлы дважды и получилась бы
редекларация типов. Вместо них — `alias()` на старых метках плюс карта путей для
`merge3.py`.

## Scope

**Делаем:** перенос `exteraGram/*` в `exteraGram/messenger/<пакет>/` со слиянием
модулей; `alias()` на всех старых метках; `path_map.json` для merge-tools;
обновление форк-инструментов, которые ходят по старой раскладке.

**Не делаем:** альбомы в Фото, папки сохранения медиа, `UIFileSharingEnabled`,
переименование самой директории `exteraGram/` (её имя зашито в `Make.py`,
`ProjectGeneration.py` и в имя продукта — трогать незачем).

**Предусловие:** ветка `master` должна собираться зелёной на 12.9.2. Начинать
реструктуризацию поверх незелёного дерева нельзя — иначе ошибки бампа и ошибки
переезда смешаются, и разбирать их придётся вместе.

## Целевая структура

25 пакетов Android: `adblock, ai, api, backup, badges, camera, components,
config, debug, drawer, export, feed, forward, icons, maps.yandex, nowplaying,
pillstack, plugins, preferences, proxy, regdate, speech, translators, updater,
utils`.

13 из них на iOS не имеют соответствия (`adblock, ai, backup, camera, drawer,
export, feed, forward, maps.yandex, nowplaying, pillstack, proxy, speech`) —
пустых директорий-заглушек под них не создаём.

### Имена модулей

Имя Swift-модуля = имя пакета Android, **в нижнем регистре**: `utils`, `config`,
`plugins`. Это допустимо — в репозитории уже есть `import sqlcipher` и
`import libprisma`. Проверено, что риск затенения минимален: обращений вида
`Модуль.Тип` во всём дереве всего 5, а `EGSimpleSettings` — это *тип* внутри
одноимённого модуля, поэтому все 314 обращений `EGSimpleSettings.shared`
переименование модуля переживают без правок.

Исключение: `maps.yandex` содержит точку и валидным идентификатором не является —
но iOS-соответствия у него нет, так что вопрос не встаёт.

### Черновая раскладка

Подлежит машинной проверке на ацикличность (см. фазу 0), не применять как есть.

| Пакет | Что переезжает |
|---|---|
| `api` | EGAPI, EGAPIToken, EGAPIWebSettings, EGRequests, EGDeviceToken, EGRecentSessionApiId |
| `config` | EGSimpleSettings, EGConfig, EGGHSettings, EGGHSettingsScheme, EGWebSettings, EGWebSettingsScheme, EGAppGroupIdentifier |
| `preferences` | EGSettingsUI, EGItemListUI, EGSettingsBundle |
| `plugins` | EGPluginEngine (+ objc-подцель EGPluginEngineBridge) |
| `translators` | EGGTranslate, EGTranslationLangFix |
| `badges` | EGBadges, EGAppBadgeAssets, EGAppBadgeOffset |
| `debug` | EGDebugUI, EGShowMessageJson, EGDBReset, FLEX |
| `regdate` | EGRegDate, EGRegDateScheme |
| `components` | EGInputToolbar, EGSwiftUI, EGNY |
| `utils` | EGSwiftSignalKit, Wrap, SwiftSoup, SFSafariViewControllerPlus, EGKeychainBackupManager, EGActionRequestHandlerSanitizer, EGContentAnalysis, EGTabBarHeightModifier, EGEmojiKeyboardDefaultFirst, EGIQTP, EGExternalVideoPlayer, EGDoubleTapMessageAction, EGChatListSimpleSettingsSignal, EGSharedAccountContextMigration, ChatControllerImplExtension |

Пакеты, которых нет в Android, — по решению пользователя заводятся рядом:
`logging` (EGLogging, EGLoggingComposer), `strings` (EGStrings), `iap` (EGIAP),
`paywall` (EGPayWall), `pro` (EGProUI), `status` (EGStatus), `webapp`
(EGWebAppExtensions).

Вне переезда остаются `Playground` (отдельный app-таргет) и
`FixConcurrencyBackport` (патч, не модуль).

### Важно: не всё сливается в Swift-модуль

15 директорий — не модули, а `filegroup`-ы, чьи `.swift` компилируются **в чужой**
модуль через переменную `egsrcs` (ChatControllerImplExtension, EGDBReset,
EGShowMessageJson, EGSharedAccountContextMigration и др.). Их нельзя влить в
слитый `swift_library` — они переезжают в новое дерево, но остаются
`filegroup`-ами. То же для `EGSettingsBundle` (`apple_bundle_import`) и `FLEX`
(build-файл внешнего репозитория, на который ссылается `MODULE.bazel`).

## Совместимость

1. **`alias()` на старых метках.** Для каждого перенесённого модуля в
   `exteraGram/<СтароеИмя>/BUILD` остаётся только
   `alias(name = "<СтароеИмя>", actual = "//exteraGram/messenger/<пакет>:<Модуль>")`.
   Это позволяет не править 194 вхождения `//exteraGram/...` в 66 BUILD-файлах в
   одном коммите: внешние ссылки продолжают работать, а переписываются они
   отдельным поздним коммитом. Ретируются алиасы только после того, как
   `check_build_deps.py` подтвердит, что на них никто не ссылается.

2. **`build-system/merge-tools/path_map.json`** — карта префиксов «старый путь →
   новый путь». `merge3.py` должен применять её при сопоставлении наших файлов с
   апстримными и легаси-путями, чтобы правка, пришедшая на старый путь,
   приземлялась на новый. Точка интеграции определяется по коду `merge3.py`.

3. **Swift-имена модулей.** Слияние убирает границу модуля между объединяемыми
   единицами, поэтому `import` внутри группы становятся лишними, а снаружи —
   переименовываются. Файл, импортирующий два модуля из одной группы, должен
   получить один `import`, а не два одинаковых.

## Фазы

**Фаза 0 — посчитать, а не прикинуть.** Новый инструмент
`build-system/merge-tools/plan_module_merge.py`:
1. строит граф зависимостей 56 директорий, разворачивая `egdeps`/`egsrcs`
   (логика уже есть в `check_build_deps.py`: `VAR_ASSIGN_RE`, `resolve_deps()`,
   `strip_build_comments()`);
2. стягивает каждую предложенную группу в одну вершину и ищет циклы
   (`find_cycle()` оттуда же). Слияние вершин — ровно та операция, которая
   превращает корректную цепочку в цикл, поэтому проверять надо после стягивания,
   а не до;
3. прогоняет `check_duplicate_types.py` по объединённым `srcs` каждой группы —
   слияние снимает границу модуля, и два одноимённых типа из разных модулей
   становятся редекларацией;
4. печатает порядок применения групп «от листьев к корню».

Если группа даёт цикл — раскладка правится здесь, до единой правки в дереве.
Этот коммит трогает только `build-system/merge-tools/**`, который в
`paths-ignore`, поэтому CI он не запускает — прогон нужно инициировать вручную
через `workflow_dispatch`.

**Фаза 1..N — по группе за коммит, от листьев.** Для каждой группы: перенос
`Sources/` в `exteraGram/messenger/<пакет>/`, один `swift_library` с
`module_name = "<пакет>"`, `alias()` на каждой старой метке, правка `import` в
файлах группы (внутригрупповые — удалить, дубликаты — схлопнуть). Внешние BUILD
не трогаем: они ходят через алиасы. После каждой группы — прогон `validate.yml`.

**Фаза N+1 — переписать 194 внешние метки** на новые пути и удалить алиасы.
Отдельным коммитом, чтобы при откате не терять переезд.

**Фаза N+2 — инструменты и карта путей.**

## Инструменты, которые придётся обновить

- `build-system/merge-tools/fork_inventory.py` — `eg_root` и перечисление модулей
  по наличию `BUILD`; счётчики форк-хуков должны пережить переезд
- `build-system/merge-tools/check_duplicate_types.py` — `SCAN_ROOTS`
- `build-system/merge-tools/check_build_deps.py` — уже умеет разворачивать
  `egdeps` и искать циклы (`find_cycle()`); менять не нужно, но именно он
  проверяет результат
- `build-system/merge-tools/merge3.py` — пропуск `exteraGram/` + новая карта путей
- `build-system/merge-tools/fork_registry.json` — пути форк-специфики

## Verification

1. `python3 build-system/merge-tools/check_build_deps.py` — главная проверка:
   ловит и «no such module», и циклы зависимостей (`find_cycle()`). Цикл — это
   отказ на фазе анализа Bazel, который `--keep_going` не смягчает.
2. `python3 build-system/merge-tools/check_duplicate_types.py` — коллизии имён
   типов внутри слитых модулей.
3. `python3 build-system/merge-tools/fork_inventory.py` — ни одно форк-объявление
   и ни один EG-модуль не потерялся при переезде.
4. `python3 build-system/merge-tools/check_api_drift.py --upstream /tmp/upstream/release-12.9.2`
   — переезд не должен трогать мосты в `AccountContext`.
5. Прогон `validate.yml` после каждой фазы. `build-system/merge-tools/**` попадает
   в `paths-ignore`, поэтому коммит, меняющий только инструменты, CI не запускает —
   это нужно учитывать при разбиении на фазы.
6. Финальная проверка — полный `main.yml` (release + IPA).
