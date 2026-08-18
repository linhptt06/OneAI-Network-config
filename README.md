# Chatbot cấu hình OpenWrt

Ứng dụng Android chạy LLM **on-device** (llama.cpp qua `llamadart`), cho phép đọc và
cấu hình router OpenWrt bằng câu lệnh tiếng Việt tự nhiên. Không gửi dữ liệu ra
dịch vụ ngoài: model chạy trên máy, router được điều khiển qua SSH trong mạng LAN.

> Chưa quen thuật ngữ? Xem [docs/THUAT-NGU.md](docs/THUAT-NGU.md) — giải thích
> mọi thuật ngữ dùng trong mã nguồn, kèm ví dụ lấy từ chính dự án.
>
> Mới tải mã về? Xem [docs/HUONG-DAN-MA-NGUON.md](docs/HUONG-DAN-MA-NGUON.md) —
> đi qua từng tệp trong `lib/` và `test/`: chứa gì, làm gì, vì sao viết như vậy.

## Kiến trúc

```
Người dùng → UI chat
                │
                ▼
        LlmService (llamadart)  ──► tool call
                │                        │
                │                 xác nhận của người dùng
                │                        ▼
        ChatDatabase (SQLite)      OpenWrtSession (SSH)
        lịch sử + hồ sơ thiết bị          │
                                          ▼
                                   router OpenWrt (uci)
```

- **Model là stateless.** `ChatSession` của llamadart chỉ giữ lịch sử trong RAM,
  nên SQLite là nguồn sự thật; mỗi lượt replay lại một cửa sổ tin nhắn gần nhất.
- **Đổi IP LAN là giao dịch hai pha.** App đọc cấu hình hiện tại, yêu cầu agent
  lập diff và hiện cảnh báo mất kết nối. Sau khi người dùng xác nhận, app áp
  dụng thay đổi, kết nối lại tại IP mới và health-confirm trước deadline; lỗi
  hoặc quá hạn để rollback guard trên router khôi phục cấu hình.
- **Mật khẩu không đi qua model.** Model chỉ thấy bí danh thiết bị; mật khẩu SSH
  nằm trong keystore hệ thống (`flutter_secure_storage`), không vào SQLite.

## Cấu trúc mã

| Thư mục | Nội dung |
|---|---|
| `lib/data/` | Schema SQLite, `StoredMessage` và ánh xạ ngược về `LlamaChatMessage` |
| `lib/llm/` | Vòng đời engine, vòng lặp tool call, định nghĩa tool mạng, che bí mật |
| `lib/net/` | SSH, parser UCI, hồ sơ thiết bị, giao thức agent |
| `lib/ui/` | Danh sách hội thoại, khung chat, hộp xác nhận, cài đặt thiết bị |

## Chạy

```bash
flutter pub get
flutter run --release
```

Dùng `--release`: ở chế độ debug, Dart VM làm tốc độ sinh token chậm thấy rõ.

Lần chạy đầu tải model GGUF (~1 GB) từ Hugging Face vào bộ nhớ riêng của ứng
dụng; các lần sau dùng cache.

### Yêu cầu

- Flutter ≥ 3.38, Dart ≥ 3.10.7
- Android `minSdk 29`, NDK theo `android/app/build.gradle.kts`
- `flutter config --enable-native-assets` (llamadart tải runtime llama.cpp qua
  cơ chế native assets)
- Thiết bị/emulator RAM ≥ 4 GB

### Nền tảng

Android là mục tiêu chính. iOS/macOS chạy được nhưng cần nâng deployment target
lên 16.4/14.0 và thêm `llamadart_llama_cpp_flutter`. **Windows, Linux và web
không chạy được** vì `sqflite` không hỗ trợ chúng.

## Khai báo router

Trong ứng dụng: biểu tượng router ở góc phải → **Thêm thiết bị** → nhập bí danh,
IP LAN, cổng SSH, tài khoản và mật khẩu.

Dùng **IP phía LAN** (`br-lan`). OpenWrt mặc định chặn SSH từ phía WAN, nên IP
WAN sẽ báo timeout.

## Công cụ model được phép gọi

| Nhóm | Công cụ |
|---|---|
| Cục bộ | `list_devices`, `connect_device` |
| Đọc router | `network_get`, `network_list`, `wifi_get`, `route_info`, `traffic_stats` |
| Preview LAN | `network_set_preview` |

`network_set_apply` và `network_set_health_confirm` là API nội bộ: không nằm
trong system prompt hoặc catalogue LLM, và LLM không nhận token của chúng.
`network_apply_enabled` là cờ thuộc app, không do LLM điều khiển. Khi bật, app
giữ token ngoài lịch sử chat, kết nối SSH lại tại IP mới, gọi tool đọc để kiểm
tra agent còn hoạt động, rồi health-confirm bằng token riêng trước deadline.
Nếu lỗi hoặc quá hạn, rollback guard trên router tự phục hồi cấu hình; app giữ
nguyên IP đã lưu.

Không có tool nào cho model chạy shell command. Schema, mô tả tool và router
state đều do app tạo; agent chỉ cung cấp tên capability để app lọc catalogue.

## Agent trên router (đang phát triển)

`lib/net/mcp_*.dart` hiện thực MCP JSON-RPC qua SSH tới agent C chạy trên
router. App không tin mô tả/schema từ agent; chỉ dùng danh sách tên tool agent
khai báo để lọc catalogue do app sở hữu.

Điểm cốt lõi của giao thức: thiết bị chỉ được khai **tên** công cụ nó hỗ trợ.
Mọi mô tả mà model đọc đều do ứng dụng sở hữu, nên một router bị chiếm quyền
không thể chèn chỉ dẫn vào ngữ cảnh của model.

## Kiểm thử

```bash
flutter analyze
flutter test
```

Toàn bộ test chạy không cần router: kiểm tra hợp lệ IP/netmask, catalogue LLM,
router state không chứa secret, và giao thức MCP đều là hàm thuần hoặc dùng
transport giả.
