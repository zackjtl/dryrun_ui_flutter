# dryrun_ui_flutter

MPTool Dry Run 測試工具，以 Flutter Desktop（Windows）實作的桌面 GUI。

管理測試用的 Part Number 群組，自動解壓 MPTool.7z 並執行 Dry Run，
測試完成後可產生 HTML 測試報告。

## 環境需求

- [Flutter SDK](https://flutter.dev/docs/get-started/install) 3.3.3+
- Windows 10 64-bit 以上

## 安裝依賴

```bash
cd dryrun_ui_flutter
flutter pub get
```

## 開發模式執行

```bash
flutter run -d windows
```

## 編譯 Release 版本

```bash
flutter build windows --release
```

編譯產出位於 `build/windows/x64/runner/Release/`（整個 `build/` 目錄不納入版本控制）。

## Modules 資料夾

執行檔目錄下需放置 `Modules/` 資料夾，結構如下：

```
Modules/
└── <Module Name>/
    ├── JSON/       ← FlashConfigUI Export JSON 產生的 *.json 模組檔
    └── Recipes/    ← FlashConfigUI Generate 產生的、以 Flash Vendor 命名的資料夾
```

若執行時目錄下找不到 `Modules/`，程式會詢問是否從 O 槽自動載入。

如需手動準備 Modules 資料夾，請參閱根目錄 [README.md](../README.md) 的步驟 2–3。

## 操作流程

1. 開啟執行檔，確認 Modules 已正確載入
2. 選取要測試的 Part Number（可儲存為群組）
3. 選取要測試的 `MPTool.7z` 壓縮包
4. 勾選 **Report** 以在測試完成後產生 HTML 報告
5. 按下 **Run Dry Run** 開始測試

## 相關腳本

| 腳本 | 說明 |
|------|------|
| `scripts/run_dryrun.py` | 執行 MPTool Dry Run 的主腳本 |
| `scripts/read_feature.py` | 從 MPTool.exe 讀取 PE resource |
