# AutoClicker TextMacro Addon

Addon dylib cho AutoClicker TrollFools — ghi lại cả keyboard input lẫn touch.

## Download dylib

Vào tab **Actions** → chọn build mới nhất → kéo xuống **Artifacts** → download `AutoClicker-TextMacroAddon`.

## Deploy

Dùng **TrollFools** inject cả 2 file vào app target:
- `AutoClicker-TrollFools.dylib` (bản gốc của bạn)
- `AutoClicker-TextMacroAddon.dylib` (file này)

## Cách dùng

Giao diện giữ nguyên như AutoClicker gốc:
1. Bấm **RECORD** → thao tác bình thường, gõ chữ thoải mái
2. Bấm **STOP**
3. Bấm **PLAY** → replay cả touch lẫn text đồng bộ
