# AGENTS.md — Dynamite / Pocket

Инструкции для агентов, работающих в этом репозитории.

## Что это

Умная macOS-шторка (notch) с вкладками и гибкими настройками.


| Источник                                                     | Роль                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| [boring.notch](https://github.com/theboredteam/boring.notch) | Основа приложения (`boring notch/`)                          |
| [Maccy](https://github.com/p0deje/Maccy)                     | Донор ядра буфера обмена (только читать; UI не портируем)    |
| [CodexBar](https://github.com/steipete/CodexBar)             | Планируемая вкладка usage AI-подписок (ещё не интегрирована) |


## Обязательный workflow после изменений

После **каждого** изменения, которое должно быть видно пользователю:

1. Собрать Debug:
  ```bash
   cd "boring notch"
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
     -configuration Debug -destination 'platform=macOS' \
     -derivedDataPath "../build/DerivedData" build
  ```
2. Задеплоить в `/Applications` и перезапустить:
  ```bash
   APP_SRC="../build/DerivedData/Build/Products/Debug/boringNotch.app"
   APP_DST="/Applications/boringNotch.app"
   pkill -x boringNotch 2>/dev/null || true
   rm -rf "$APP_DST"
   ditto "$APP_SRC" "$APP_DST"
   xattr -cr "$APP_DST" 2>/dev/null || true
   open "$APP_DST"
  ```
3. Убедиться, что процесс жив (`pgrep -x boringNotch`).

Пользователь смотрит `**/Applications/boringNotch.app**`, не build product из DerivedData.

## Вкладки шторки


| Вкладка             | Состояние                                                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Home                | Медиа / live activities                                                                                                                                                                                 |
| Shelf               | Drag-and-drop файловый трей                                                                                                                                                                             |
| Clipboard           | История буфера (карточки)                                                                                                                                                                               |
| CodexBar / AI usage | **Планируется** — отдельная вкладка, подключение провайдеров в Settings, статус-бары usage с логотипами; автопоиск установленных агентов в системе (референс: [orca](https://github.com/stablyai/orca)) |


## Границы

**Не** commit/push/PR без явной просьбы пользователя.



