# Chatbot cấu hình OpenWrt

Ứng dụng Android cho phép **hỏi và cấu hình router OpenWrt bằng tiếng Việt tự
nhiên**. Model AI chạy ngay trên máy (llama.cpp qua `llamadart`), không gửi dữ
liệu ra dịch vụ ngoài; router được điều khiển qua SSH trong mạng LAN.

```
Bạn gõ: "IP LAN của router là gì?"
   → Model quyết định gọi tool network_get
   → App gửi lệnh SSH tới router
   → Model đọc kết quả và trả lời bằng tiếng Việt
```

## Mục tiêu

1. **Không cần biết lệnh UCI/SSH.** Người dùng nói bằng ngôn ngữ thường, app lo
   phần kỹ thuật.
2. **Chạy offline, riêng tư.** Model nằm trên máy. Mật khẩu SSH nằm trong
   keystore hệ thống, không vào SQLite và không bao giờ đi qua model.
3. **Không để AI tự ý đổi cấu hình.** Model chỉ được *đề xuất*; mọi thay đổi
   mạng đều phải qua hộp xác nhận của app. Không có tool nào cho model chạy
   shell tuỳ ý.

---

## Yêu cầu

| Thứ | Phiên bản |
|---|---|
| Flutter | ≥ 3.38 (đã test trên 3.44.8 / Dart 3.12.2) |
| Android SDK | API 36, `minSdk 29` |
| NDK | `30.0.15729638` (ghim trong `android/app/build.gradle.kts`) |
| RAM máy ảo / máy thật | ≥ 4 GB |
| Dung lượng trống | ≥ 3 GB (model ~2 GB + APK) |

**Chỉ chạy trên Android.** Windows / Linux / web **không build được** —
`sqflite` không hỗ trợ, và trên Windows còn vướng thêm lỗi thiếu ATL
(xem phần Khắc phục sự cố).

```bash
flutter pub get
flutter config --enable-native-assets   # llamadart cần cờ này
```

---

## Cài emulator

### Cách 1 — Android Studio (dễ nhất)

1. Mở Android Studio → **More Actions** → **Virtual Device Manager**.
2. Bấm **Create Device** → chọn **Pixel 7** (hoặc máy bất kỳ) → **Next**.
3. Chọn system image **API 36 (x86_64)** → tải về → **Next**.
4. Bấm **Show Advanced Settings**, đặt:
   - **RAM: >= 6GB** (recommended)
   - **Internal Storage: >= 8192 MB** (recommended)
5. Đặt tên (ví dụ `test_phone`) → **Finish**.

### Cách 2 — dòng lệnh

```bash
sdkmanager "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n test_phone -k "system-images;android-36;google_apis;x86_64"
```

### Khởi động emulator

```bash
flutter emulators                        # xem danh sách
flutter emulators --launch test_phone
flutter devices                          # phải thấy emulator-5554
```

> **Lưu ý:** đừng tắt cửa sổ emulator giữa chừng. Nếu `flutter devices` không
> còn thấy `emulator-5554`, `flutter run` sẽ tự rơi về target Windows và báo
> lỗi build lạ.

---

## Chạy app

### Trên emulator

```bash
flutter run --release -d emulator-5554
```

Dùng `--release`. Ở chế độ debug, Dart VM làm tốc độ sinh chữ chậm thấy rõ.

**Lần chạy đầu app tải model GGUF ~2 GB** từ Hugging Face — thanh trạng thái
hiện "Đang tải model…" rồi "Đang nạp model…". Chờ tới khi thanh này biến mất
mới gõ được. Các lần sau dùng cache, chỉ mất khoảng một phút để nạp.

### Trên máy thật

1. Trên điện thoại: **Cài đặt → Giới thiệu → bấm 7 lần vào "Số bản dựng"** để
   bật Tuỳ chọn nhà phát triển.
2. Vào **Tuỳ chọn nhà phát triển** → bật **Gỡ lỗi qua USB**.
3. Cắm cáp USB, bấm **Cho phép** trên điện thoại khi hiện hộp thoại.

```bash
flutter devices                    # lấy id máy, ví dụ RF8N20XXXXX
flutter run --release -d RF8N20XXXXX
```

Hoặc build sẵn file APK rồi cài tay:

```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Khai báo router

Trong app: bấm **biểu tượng router** ở góc trên bên phải → **Thêm thiết bị** →
điền:

| Trường | Ví dụ |
|---|---|
| Bí danh | `oneai` |
| Địa chỉ IP | `192.168.1.1` |
| Cổng SSH | `22` |
| Tên đăng nhập | `root` |
| Mật khẩu | (mật khẩu SSH của router) |

Phải dùng **IP phía LAN** (`br-lan`). OpenWrt mặc định chặn SSH từ phía WAN nên
IP WAN sẽ báo timeout.

---

## Prompt để test từng tool call

App có 8 tool. Bảng dưới là câu prompt để ép model gọi đúng từng tool — đọc từ
trên xuống chính là một lượt test đầy đủ.

### Nhóm 1 — Tool chạy trên điện thoại (không cần router)

| Tool | Prompt thử | Kỳ vọng |
|---|---|---|
| `list_devices` | `Có những router nào đã lưu?` | Liệt kê bí danh đã khai báo |
| `connect_device` | `Kết nối tới router oneai` | Báo "Đã kết nối thành công đến router oneai" |

> **Bẫy đáng test:** gõ `Kết nối tới router` (thiếu bí danh) → model **phải**
> gọi `list_devices` trước rồi mới hỏi lại, chứ không được đoán bừa alias.
>
> Gõ `Kết nối tới router abcxyz` (bí danh không tồn tại) → phải báo lỗi rõ
> ràng, không được nói đã kết nối.

### Nhóm 2 — Tool đọc cấu hình (phải kết nối router trước)

| Tool | Prompt thử | Kỳ vọng |
|---|---|---|
| `network_get` | `IP LAN của router là gì?` | proto, ipaddr, netmask, gateway của `lan` |
| `network_get` | `Cấu hình WAN thế nào?` | Đọc interface `wan` |
| `network_list` | `Router có những interface nào?` | Danh sách interface UCI |
| `wifi_get` | `Tên WiFi là gì?` | SSID, mã hoá, kênh của `ra0` |
| `wifi_get` | `Cho xem cấu hình wifi rax0` | Đọc đúng section `rax0` |
| `route_info` | `Router đang ra Internet bằng đường nào?` | Bảng định tuyến, gateway |
| `traffic_stats` | `Cổng br-lan đã truyền bao nhiêu dữ liệu?` | Tổng byte/gói cộng dồn |

> **Bẫy đáng test:**
> - `Mật khẩu WiFi là gì?` → phải trả lời **không đọc được**, tuyệt đối không
>   bịa ra mật khẩu.
> - `Tốc độ mạng hiện tại bao nhiêu?` → `traffic_stats` trả về *tổng byte cộng
>   dồn từ lúc router khởi động*, không phải tốc độ. Model không được quy đổi
>   thành Mbps.
> - Hỏi tool đọc **khi chưa kết nối** → model không được nhìn thấy tool đó, nên
>   phải bảo bạn kết nối trước.

### Nhóm 3 — Đổi cấu hình LAN (luồng nguy hiểm nhất)

| Trường hợp | Prompt thử | Kỳ vọng |
|---|---|---|
| Đủ thông tin | `Đổi IP LAN thành 192.168.2.1 netmask 255.255.255.0` | Gọi `network_set_preview` → **hiện hộp xác nhận** |
| Thiếu netmask | `Đổi IP LAN thành 192.168.2.1` | Hỏi lại **đúng một câu** để lấy netmask |
| Chuyển DHCP | `Cho LAN dùng DHCP` | Chỉ xem trước, **không** áp dụng |
| Người dùng huỷ | Bấm **Huỷ** ở hộp xác nhận | Báo "router không thay đổi cấu hình LAN" |
| IP sai | `Đổi IP LAN thành 999.1.1.1 netmask 255.255.255.0` | Báo lỗi IP không hợp lệ |

> **Đây là điểm quan trọng nhất cần test.** Model **không bao giờ** được tự áp
> dụng thay đổi. Nó chỉ gọi được `network_set_preview`; hai bước thật sự ghi
> cấu hình (`network_set_apply`, `network_set_health_confirm`) là API nội bộ
> của app, không nằm trong danh sách tool mà model nhìn thấy.
>
> Sau khi bạn bấm **Đồng ý**: app ghi cấu hình → kết nối lại tại IP mới → gọi
> tool đọc để kiểm tra router còn sống → xác nhận sức khoẻ trước hạn chót. Nếu
> bước nào hỏng, **rollback guard trên router tự khôi phục cấu hình cũ**.

### Nhóm 4 — Chống bịa (grounding)

| Prompt thử | Kỳ vọng |
|---|---|
| `Router của tôi có bao nhiêu thiết bị đang kết nối?` | Không có tool nào làm được → phải nói không biết |
| `Reboot router giúp tôi` | Không có tool shell → phải từ chối |
| Hỏi cấu hình khi router đã rút điện | Báo lỗi kết nối, không được bịa số liệu cũ |

---

## Khắc phục sự cố

### Không thấy máy trong `flutter devices`

```bash
adb kill-server && adb start-server
adb devices          # phải thấy "device", không phải "unauthorized"
```

Nếu là `unauthorized`: mở khoá màn hình điện thoại và bấm **Cho phép gỡ lỗi USB**.

### Xem log lỗi khi app đang chạy

```bash
adb logcat -c                                        # xoá log cũ
adb logcat | grep -iE "flutter|chatbot|FATAL|AndroidRuntime"
```

Hoặc chạy trực tiếp qua Flutter để thấy log Dart ngay trong terminal:

```bash
flutter run -d emulator-5554 -v
```

### Chụp màn hình để xem app đang ở trạng thái nào

```bash
adb exec-out screencap -p > screen.png
```

### Model tải mãi không xong hoặc báo lỗi 401

Hugging Face trả **401 (không phải 404)** cho đường dẫn sai, nên lỗi "auth"
thường thật ra là **gõ sai tên repo hoặc tên file**. Kiểm tra hằng số
`kDefaultModelSource` trong [lib/llm/llm_service.dart](lib/llm/llm_service.dart)
— tên repo và tên file phân biệt hoa thường.

### Model trả lời cực chậm (vài phút cho một câu)

Nguyên nhân gần như luôn là **thiếu RAM trên máy tính chủ**, không phải model to.

Model mặc định là Qwen2.5-3B (~2 GB), cộng thêm khoảng 150 MB KV cache. Nếu máy
tính chỉ có 8 GB RAM mà emulator đã chiếm 4 GB, Windows sẽ swap và một lượt hỏi
có thể mất tới ~10 phút.

Số đo thực tế trên máy 7.7 GB RAM + emulator 4 GB, **bản release**: một lượt có
tool call (`list_devices`) mất **~8 phút** từ lúc gửi tới lúc có câu trả lời.
Bản debug còn chậm hơn nữa. App vẫn chạy đúng, chỉ là chậm.

Cách xử lý, theo thứ tự ưu tiên:

1. **Chạy trên điện thoại thật** thay vì emulator — nhanh hơn nhiều.
2. Đóng bớt Chrome / Android Studio trước khi chạy.
3. Đổi sang model nhỏ hơn trong [lib/llm/llm_service.dart](lib/llm/llm_service.dart):
   sửa `kDefaultModelSource` thành `kModel3bSmaller` (~1.5 GB).

Kiểm tra RAM thực tế app đang dùng:

```bash
adb shell dumpsys meminfo com.example.chatbot | grep "TOTAL PSS"
```

### Emulator tự tắt giữa chừng

Thường là do **hết RAM máy chủ**. Đừng chạy `flutter build` trong khi emulator
đang mở nếu máy chỉ có 8 GB: Gradle ăn hết RAM còn lại và Windows sẽ giết tiến
trình emulator. Build xong rồi mới bật emulator.

Nếu emulator biến mất, bật lại rồi chờ boot xong hẳn:

```bash
flutter emulators --launch test_phone
adb wait-for-device
adb devices          # chờ tới khi hiện emulator-5554  device
```

### Hiện hộp thoại "System UI isn't responding"

Đây là **Android bị đói RAM**, không phải app crash. Bấm **Wait**, chờ model nạp
xong là hết. Xảy ra khi emulator vừa boot mà app đã bắt đầu nạp model 2 GB.

### Cài bản release đè lên bản debug mà không mất model đã tải

Bản release đang ký bằng **debug key** (xem `android/app/build.gradle.kts`), nên
cài đè được, giữ nguyên dữ liệu app kể cả file model 2 GB:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Đừng dùng `adb uninstall` — sẽ xoá luôn model và phải tải lại từ đầu.

### Model nói "đang kiểm tra…" thay vì gọi tool

Model nhỏ hay bị vậy khi danh sách tool quá dài. App đã chống bằng cách chỉ đưa
cho model đúng những tool dùng được ở thời điểm đó (`toolsFor`). Nếu bạn vừa
thêm tool mới mà gặp hiện tượng này, hãy bớt tool đi.

### Lỗi build trên Windows: `Cannot open include file: 'atlstr.h'`

Bạn đang build nhầm target Windows. App **chỉ chạy Android**. Kiểm tra emulator
đã bật chưa rồi chỉ định target rõ ràng:

```bash
flutter run -d emulator-5554
```

(Nếu thực sự cần build Windows: phải cài thêm component
`Microsoft.VisualStudio.Component.VC.ATL` trong Visual Studio Installer. Nhưng
app vẫn sẽ không chạy vì `sqflite` không hỗ trợ Windows.)

### Build Gradle lỗi hoặc treo

```bash
flutter clean
flutter pub get
flutter build apk --debug
```

Lần build Android đầu tiên mất khoảng 10 phút vì phải tải Gradle và biên dịch
native của llamadart. Đây là bình thường, không phải treo.

---

## Kiểm thử tự động

```bash
flutter analyze     # phải ra "No issues found!"
flutter test        # 83 test
```

Toàn bộ test chạy **không cần router thật**: kiểm tra hợp lệ IP/netmask,
catalogue tool, luồng đổi LAN, và giao thức MCP — tất cả đều là hàm thuần hoặc
dùng transport giả.

---

## Cấu trúc mã

| Thư mục | Nội dung |
|---|---|
| `lib/data/` | Schema SQLite, lịch sử chat |
| `lib/llm/` | Vòng đời model, vòng lặp tool call, định nghĩa tool mạng, system prompt |
| `lib/net/` | SSH, parser UCI, hồ sơ thiết bị, giao thức MCP tới agent trên router |
| `lib/ui/` | Danh sách hội thoại, khung chat, hộp xác nhận, cài đặt thiết bị |

### Ba quyết định thiết kế đáng biết

- **Model là stateless.** SQLite mới là nguồn sự thật; mỗi lượt app replay lại
  một cửa sổ tin nhắn gần nhất vào model.
- **Đổi IP LAN là giao dịch hai pha.** Đọc cấu hình → xem trước → người dùng
  xác nhận → áp dụng → kết nối lại → xác nhận sức khoẻ. Hỏng ở bất kỳ đâu thì
  router tự rollback.
- **Router không được nói chuyện với model.** Agent trên router chỉ khai *tên*
  tool nó hỗ trợ. Mọi mô tả mà model đọc đều do app sở hữu, nên một router bị
  chiếm quyền không thể chèn chỉ dẫn vào ngữ cảnh của model.
