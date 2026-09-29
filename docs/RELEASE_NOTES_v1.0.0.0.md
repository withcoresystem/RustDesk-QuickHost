# RustDesk QuickHost v1.0.0.0

## English

Initial public release of RustDesk QuickHost.

RustDesk QuickHost is a lightweight RustDesk-compatible host-only remote support client for Windows. It is rewritten from the ground up in native C++ and is designed for computers that only need to be remotely controlled.

### Highlights

- Native C++ Win32 host-only implementation
- Lightweight single executable
- Supports Windows XP / Windows 7 / Windows 10 / Windows 11
- System tray resident mode
- Auto start with Windows
- Fixed password support
- Option to disable random one-time password
- Custom RustDesk ID support
- INI-based RustDesk server configuration
- Self-hosted RustDesk server support
- Built-in Traditional Chinese and English language templates
- Custom `.txt` language file support
- First run automatically generates `rustdesk_cpp_host.ini`, `en.txt`, and `tw.txt`

### Self-hosted server

The default `rustdesk_cpp_host.ini` connects to the official RustDesk public server. You can edit `id_server`, `relay_server`, `api_server`, and `key` to use your own self-hosted RustDesk server.

### Custom language files

You can copy the built-in `tw.txt` or `en.txt`, translate only the values, save it as another file such as `jp.txt`, and set `language_file=jp.txt` in the INI file.

> This project is compatible with RustDesk-style remote support usage, but it is not an official RustDesk client.

---

## 繁體中文

RustDesk QuickHost 首次公開版本。

RustDesk QuickHost 是一個輕量化的 RustDesk 相容 Host-only 被控端遠端協助工具。本專案使用原生 C++ 從底層重新實作，主要設計給只需要被遠端連線控制的 Windows 電腦使用。

### 功能特色

- 原生 C++ Win32 Host-only 被控端實作
- 輕量化單一執行檔
- 支援 Windows XP / Windows 7 / Windows 10 / Windows 11
- 支援右下角常駐
- 支援開機自動啟動
- 支援固定密碼
- 支援停用隨機一次性密碼
- 支援自訂 RustDesk ID
- 支援透過 INI 設定 RustDesk 伺服器
- 支援自架 RustDesk Server
- 內建繁體中文與英文語言模板
- 支援外部 `.txt` 自定義語言檔
- 第一次執行會自動產生 `rustdesk_cpp_host.ini`、`en.txt`、`tw.txt`

### 自架伺服器

預設產生的 `rustdesk_cpp_host.ini` 目前會連到 RustDesk 官方公開伺服器。使用者可以自行修改 `id_server`、`relay_server`、`api_server` 與 `key`，改成自己的 RustDesk 自架伺服器專用版本。

### 自定義語言檔

可複製內建的 `tw.txt` 或 `en.txt`，只翻譯右邊文字，另存成 `jp.txt` 等語言檔，並在 INI 設定 `language_file=jp.txt` 即可切換介面語言。

> 本專案相容 RustDesk 風格的遠端協助用途，但不是 RustDesk 官方用戶端。
