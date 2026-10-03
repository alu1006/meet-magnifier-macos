# Meet 放大鏡

macOS 簡報輔助工具，將全螢幕縮放、大型滑鼠游標、箭頭與方框直接顯示在螢幕覆蓋層，因此 Google Meet 分享「整個螢幕」時也能讓觀眾看到。

## 宣傳影片

https://github.com/user-attachments/assets/ddc44b32-fe4f-48a5-8810-8568c99cb6d3

影片依序展示全螢幕放大、大型游標、箭頭與方框，解析度為 1080p。

## 下載

前往 [Releases](../../releases/latest) 下載適合的版本：

- macOS：`Meet-Magnifier-1.1.0-macOS.zip`
- Windows 10/11 x64：`Meet-Magnifier-1.2.0-Windows-x64.zip`

Windows 版解壓縮後直接執行 `MeetMagnifier.exe`。若 SmartScreen 顯示未知發行者，請檢查檔案來自本專案的 Release；目前公開版本未購買 Windows 程式碼簽署憑證。

本程式目前未經 Apple 公證。第一次開啟時，請在 Finder 對 App 按右鍵選「打開」，再確認開啟。

## 快捷鍵

| 操作 | 功能 |
| --- | --- |
| `Control + 滾輪` | 全螢幕放大／縮小，方向與 macOS 原生縮放一致 |
| `Control + M` | 切換大型高對比滑鼠游標 |
| `Control + A` | 進入箭頭模式，拖曳滑鼠畫箭頭 |
| `Control + R` | 進入方框模式，拖曳滑鼠框選 |
| `Control + 0` | 清除標註並強制回到 1 倍 |

## 首次設定

### macOS

App 需要以下兩項權限：

1. 「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」：允許擷取畫面以產生放大內容。
2. 「系統設定 → 隱私權與安全性 → 輔助使用」：允許攔截 `Control + 滾輪`。

授權後若系統詢問，選擇「結束並重新打開」。為避免兩套縮放同時觸發，可在「系統設定 → 輔助使用 → 縮放」關閉原生的「使用捲動手勢搭配變更鍵來縮放」。

Google Meet 分享時請選擇「整個螢幕」。分享單一分頁或單一視窗不會包含覆蓋層。

### Windows

Windows 版不需管理員權限。啟動後會常駐通知區，快捷鍵與 macOS 版相同。Google Meet 也必須分享「整個螢幕」。

## 從原始碼建置

需要 macOS 14 或更新版本，以及 Xcode Command Line Tools：

```sh
chmod +x work/MeetMagnifier/build.sh
work/MeetMagnifier/build.sh
```

App 會輸出至 `outputs/Meet 放大鏡.app`。Windows 版可在 Windows 10/11 使用：

```powershell
dotnet publish windows/MeetMagnifier.Windows/MeetMagnifier.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist
```

## 限制

- 未經 Apple 公證，第一次啟動需要手動確認。
- 放大覆蓋層的點擊位置仍依照底下原始畫面座標，不會像系統縮放一樣重新映射點擊。
- Meet 必須分享整個螢幕才能讓遠端觀眾看到效果。

## License

MIT
