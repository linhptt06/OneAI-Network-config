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
- **Ghi cấu hình luôn hai pha.** `uci set` chỉ ghi vào vùng chờ; ứng dụng hiện
  `uci changes` do router báo về để người dùng duyệt, rồi mới `uci commit` hoặc
  `uci revert`. Bấm Hủy là thiết bị nguyên vẹn.
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
| Đọc | `list_devices`, `connect_device`, `get_wifi_info`, `get_network_info`, `get_vlan_info` |
| Ghi *(cần xác nhận)* | `set_wifi`, `set_wan`, `set_vlan` |

Không có công cụ nào nhận lệnh thô dạng chuỗi. Mọi giá trị ghi xuống thiết bị đi
qua `shellQuote`, và tham số dạng liệt kê được ràng buộc bằng GBNF grammar nên
model không sinh được giá trị ngoài danh sách.

`set_vlan` tự phát hiện cơ chế VLAN (DSA hay swconfig) và **từ chối chạy** khi
không xác định được, thay vì đoán — đoán sai ở đây là mất kết nối tới router.

## Agent trên router (đang phát triển)

`lib/net/agent_*.dart` hiện thực phía client của một giao thức JSON qua
stdin/stdout, để sau này logic dựng lệnh chuyển sang một agent chạy trên chính
router. Agent chưa được viết; đường thực thi hiện tại vẫn là dựng lệnh UCI trong
Dart.

Điểm cốt lõi của giao thức: thiết bị chỉ được khai **tên** công cụ nó hỗ trợ.
Mọi mô tả mà model đọc đều do ứng dụng sở hữu, nên một router bị chiếm quyền
không thể chèn chỉ dẫn vào ngữ cảnh của model.

## Kiểm thử

```bash
flutter analyze
flutter test
```

Toàn bộ test chạy không cần router: parser UCI, kiểm tra hợp lệ IP/netmask/SSID,
che bí mật, và giao thức agent đều là hàm thuần hoặc dùng transport giả.
