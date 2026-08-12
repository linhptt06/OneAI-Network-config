# Từ điển thuật ngữ trong dự án

Giải thích các thuật ngữ xuất hiện trong mã nguồn, kèm chỗ chúng được dùng.
Sắp theo nhóm, mỗi mục có ví dụ lấy từ chính dự án này.

---

## 1. Thuật ngữ về mô hình ngôn ngữ (LLM)

### LLM
*Large Language Model* — mô hình ngôn ngữ lớn. Chương trình đoán chữ tiếp theo
dựa trên chữ đã có. Chatbot là một vòng lặp gọi LLM liên tục.

### On-device / inference
**Inference** (suy luận) là quá trình mô hình sinh ra câu trả lời.
**On-device** nghĩa là chạy ngay trên điện thoại, không gửi ra máy chủ nào.

### Token
Đơn vị mô hình đọc và sinh ra — không phải ký tự, cũng không hẳn là từ. Tiếng
Việt trung bình 1 từ ≈ 2–3 token. Câu *"tên wifi là gì"* khoảng 8 token.

Mọi giới hạn trong dự án đều tính bằng token, không phải ký tự.

### Context window (`contextSize`)
Lượng token tối đa mô hình "nhìn thấy" cùng lúc, gồm cả câu hỏi lẫn câu trả
lời. Dự án đặt **4096**.

Đây là nguồn gốc của phần lớn vấn đề đã gặp: mô tả 8 công cụ đã chiếm khoảng
1200 token, hệ thống prompt ~250, còn lại mới đến hội thoại. Vượt quá thì phần
cũ nhất bị đẩy ra và mô hình "quên".

> Xem `contextSize` trong `lib/llm/llm_service.dart`

### Prompt / system prompt
**Prompt** là toàn bộ văn bản đưa vào mô hình. **System prompt** là phần chỉ
dẫn đặt ở đầu, quy định vai trò và quy tắc.

System prompt của dự án nằm ở `kSystemPrompt` trong `lib/llm/chat_controller.dart`,
có dòng cấm mô hình trả lời *"đang kiểm tra…"* thay vì gọi công cụ.

### Multi-turn
Hội thoại nhiều lượt. Mô hình không tự nhớ — mỗi lượt phải gửi lại toàn bộ lịch
sử. Dự án lưu lịch sử trong SQLite rồi phát lại 10 tin nhắn gần nhất.

### Tool call / function calling
Cơ chế cho mô hình **gọi hàm** thay vì chỉ trả lời bằng chữ. Mô hình sinh ra
một cấu trúc kiểu:

```json
{ "name": "set_wifi", "arguments": { "ssid": "NhaToi" } }
```

Ứng dụng nhận cấu trúc đó, chạy hàm Dart tương ứng, rồi đưa kết quả **ngược lại**
cho mô hình để nó diễn giải cho người dùng.

### Tool definition
Bản khai báo một công cụ, gồm 4 phần:

| Phần | Vai trò |
|---|---|
| `name` | Định danh mô hình phát ra |
| `description` | **Quan trọng nhất** — văn bản duy nhất mô hình dựa vào để quyết định có gọi hay không |
| `parameters` | Kiểu dữ liệu các tham số |
| `handler` | Hàm Dart chạy thật |

> Xem `lib/llm/net_tools.dart`

### GBNF grammar
Kỹ thuật **ép** mô hình chỉ sinh ra văn bản đúng khuôn. llamadart chuyển schema
tham số thành grammar, rồi chặn ngay ở tầng sinh token.

Ví dụ thực tế: `encryption` khai bằng `ToolParam.enumType` với danh sách
`['none', 'psk2', 'psk2+ccmp', 'sae', ...]`. Mô hình **không thể** sinh ra giá
trị ngoài danh sách — không phải "được nhắc không nên", mà là *bất khả thi*.

> Danh sách ở `kWifiEncryptionModes` trong `lib/net/validation.dart`

### GGUF
Định dạng file chứa mô hình đã nén, dùng bởi llama.cpp. File dự án tải về:
`qwen2.5-1.5b-instruct-q4_k_m.gguf` (~1 GB).

### Quantization (Q4_K_M, Q3_K_M)
Nén trọng số mô hình để giảm dung lượng và RAM, đổi lại chất lượng giảm nhẹ.

| Ký hiệu | Nghĩa |
|---|---|
| `Q4` | Mỗi trọng số còn ~4 bit thay vì 16 |
| `Q3` | ~3 bit — nhỏ hơn, kém chính xác hơn |
| `_K_M` | Biến thể "K-quant, Medium" — cân bằng tốt |

Cùng mô hình 3B: Q4_K_M nặng 2007 MB, Q3_K_M nặng 1517 MB.

### KV cache
Bộ nhớ đệm mô hình dùng để khỏi tính lại phần hội thoại cũ. Kích thước tỉ lệ
thuận với `contextSize`. Ở 4096 token, mô hình 1.5B tốn khoảng 150 MB RAM chỉ
riêng cho phần này.

### Prefill
Giai đoạn mô hình "đọc" prompt trước khi bắt đầu sinh chữ. Prompt càng dài
prefill càng lâu — đây là lý do mô tả công cụ dài làm chậm **mọi** lượt.

### Streaming / chunk / delta
Mô hình trả lời từng mẩu một thay vì đợi xong hết. Mỗi mẩu gọi là **chunk**,
phần chữ mới trong mẩu đó gọi là **delta**. Nhờ vậy chữ hiện dần trên màn hình.

> Xem vòng `await for (final chunk in ...)` trong `lib/llm/llm_service.dart`

### `maxTokens`, `temperature`
`maxTokens` giới hạn độ dài câu trả lời. `temperature` điều khiển độ ngẫu
nhiên: thấp thì đều đặn, cao thì sáng tạo và dễ bịa.

### Chat template
Khuôn văn bản riêng của từng mô hình để phân biệt lời người dùng, lời trợ lý và
kết quả công cụ. Qwen2.5 dùng các thẻ `<tool_call>` và `<tool_response>` — đây
chính là điều kiện để tool calling hoạt động.

---

## 2. Thuật ngữ về OpenWrt và mạng

### OpenWrt
Hệ điều hành Linux cho router, thay thế firmware của hãng.

### UCI
*Unified Configuration Interface* — hệ thống cấu hình của OpenWrt. Mọi thiết
lập nằm trong `/etc/config/`, thao tác bằng lệnh `uci`.

Cấu trúc ba tầng:

```
wireless   .   ra0     .   ssid    =  'oneai'
   │            │           │
 package     section     option
```

| Tầng | Là gì | Ví dụ |
|---|---|---|
| **package** | Một file cấu hình | `wireless`, `network`, `firewall` |
| **section** | Một khối trong file | `ra0`, `rax0`, `MT7993_1_1` |
| **option** | Một thiết lập | `ssid`, `key`, `encryption` |

### `uci set` / `changes` / `commit` / `revert`
Bốn lệnh tạo nên cơ chế **hai pha** mà toàn bộ phần ghi của dự án dựa vào:

| Lệnh | Làm gì |
|---|---|
| `uci set` | Ghi vào **vùng chờ** — hệ thống chưa đổi gì |
| `uci changes` | Liệt kê những gì đang chờ |
| `uci commit` | Áp dụng thật |
| `uci revert` | Vứt bỏ vùng chờ, khôi phục nguyên trạng |

Nhờ `uci set` chỉ ghi vào vùng chờ, ứng dụng mới hiện được hộp xác nhận với nội
dung **do chính router báo về**, và bấm Hủy thì thiết bị sạch tuyệt đối.

### Staged / staging (vùng chờ)
Trạng thái "đã chuẩn bị nhưng chưa áp dụng". Giống việc soạn tin nhắn mà chưa
bấm gửi.

### `wifi-device` / `wifi-iface`
Hai loại section trong `/etc/config/wireless`:

- **wifi-device** = một **radio** (phần cứng phát sóng). Router của bạn có hai:
  `MT7993_1_1` (2.4 GHz) và `MT7993_1_2` (5 GHz)
- **wifi-iface** = một **mạng WiFi** phát ra từ radio đó. Một radio phát được
  nhiều mạng cùng lúc

### SSID
Tên mạng WiFi mà người dùng nhìn thấy. Router của bạn: `oneai`.

### Encryption: PSK, WPA2, WPA3, SAE, CCMP
Các kiểu bảo mật WiFi:

| Ký hiệu | Nghĩa |
|---|---|
| `none` | Không mật khẩu |
| `psk` | WPA cũ |
| `psk2` | **WPA2** — phổ biến nhất |
| `sae` | **WPA3** — mới hơn, an toàn hơn |
| `+ccmp` | Chỉ định thuật toán mã hoá là AES-CCMP |

**PSK** = *Pre-Shared Key*, tức mật khẩu dùng chung.
**SAE** = cơ chế bắt tay của WPA3.

Router của bạn dùng `psk2+ccmp` **và** bật `sae='1'` — chấp nhận cả WPA2 lẫn
WPA3. Vì thế mật khẩu được lưu ở **hai chỗ**: `key` (cho WPA2) và
`sae_password` (cho WPA3). Ghi thiếu một chỗ là client WPA3 vẫn dùng mật khẩu cũ.

### Mode: `ap` / `sta`
- **ap** (*Access Point*) — phát sóng cho máy khác kết nối vào
- **sta** (*Station*) — ngược lại, router **kết nối vào** một WiFi khác, dùng
  làm đường lên (repeater/mesh)

Dự án **từ chối** sửa section chế độ `sta`: đó là đường lên của router, sửa
nhầm là cắt đứt kết nối. Trên máy bạn đó là `apcli0` và `apclix0`.

### Mesh backhaul
Đường truyền nối các router mesh với nhau, ẩn với người dùng thường. Trên máy
bạn là `ra2` với SSID `Temporary_backhaul`.

### WAN / LAN
- **WAN** — cổng nối **ra ngoài** (Internet, mạng cấp trên)
- **LAN** — mạng **bên trong** nhà

Router bạn: `br-wan` ở `10.2.204.211`, `br-lan` ở `192.168.88.1`.

### `br-lan`, `br-wan` (bridge)
**Bridge** gộp nhiều cổng vật lý thành một mạng logic. `br-lan` gộp các cổng LAN
và WiFi lại, để máy nối dây và máy nối WiFi thấy nhau như cùng một mạng.

### Proto: `dhcp` / `static` / `pppoe`
Cách một interface lấy địa chỉ IP:

| Giá trị | Nghĩa |
|---|---|
| `dhcp` | Xin IP tự động từ mạng cấp trên |
| `static` | Đặt IP cố định bằng tay |
| `pppoe` | Quay số bằng tài khoản nhà mạng (ADSL/FTTH) |

### Netmask / subnet mask
Cho biết phần nào của địa chỉ IP là "mạng", phần nào là "máy".
`255.255.255.0` nghĩa là ba nhóm số đầu xác định mạng, nhóm cuối xác định máy —
tức mạng đó chứa được 254 máy.

Mask hợp lệ phải là dãy bit 1 liên tục rồi đến bit 0. `255.255.0.255` **không**
hợp lệ — đây chính là thứ hàm `isValidIpv4Netmask` kiểm tra.

### Gateway
Địa chỉ router mà máy gửi gói tin ra ngoài qua đó.

### VLAN
*Virtual LAN* — chia một switch vật lý thành nhiều mạng logic tách biệt.

### Tagged / untagged, PVID
Cách đánh dấu gói tin thuộc VLAN nào:

- **untagged** — cổng nối máy tính thường, gói không mang nhãn
- **tagged** — cổng nối switch khác, gói mang nhãn VLAN
- **PVID** — VLAN mặc định gán cho gói không nhãn đi vào cổng

### DSA và swconfig
**Hai cơ chế cấu hình VLAN không tương thích nhau** trong OpenWrt:

| | swconfig (cũ) | DSA (mới, từ 21.02) |
|---|---|---|
| Section | `config switch_vlan` | `config bridge-vlan` |
| Ghi cổng | `'0 1 3t 5t'` | `'lan1:u*' 'lan2:t'` |
| Dấu hiệu | Có lệnh `swconfig` chạy được | Mỗi cổng là một netdev `lan1`, `lan2`… |

Router của bạn **không dùng cơ chế nào** — chỉ có `eth0`/`eth1`, không có
switch. Nên dự án trả về `unknown` và **từ chối** tạo VLAN thay vì đoán.

> Xem `lib/net/agent_side/vlan_backend.dart`

### netdev (network device)
Một "card mạng" theo cách Linux nhìn — có thể là phần cứng thật (`eth0`) hoặc
ảo (`br-lan`, `ra0`). Xem bằng `ls /sys/class/net`.

### SSH, dropbear
**SSH** là giao thức điều khiển máy từ xa qua dòng lệnh, có mã hoá.
**Dropbear** là phần mềm SSH nhỏ gọn mà OpenWrt dùng.

### KEX (key exchange)
Bước hai bên thoả thuận khoá mã hoá khi bắt đầu kết nối SSH. Nếu hai bên không
có thuật toán chung thì kết nối hỏng ngay — đây là rủi ro đã kiểm tra trước khi
dùng `dartssh2`.

### Host key
"Vân tay" định danh máy chủ SSH, để phát hiện bị giả mạo. Dự án tắt kiểm tra
này vì router LAN truy cập bằng IP và chưa có vân tay lưu sẵn — đánh đổi có chủ
ý cho công cụ quản trị mạng nội bộ.

### ubus / rpcd
Hệ thống "bus" nội bộ của OpenWrt để các chương trình gọi nhau bằng JSON.
**rpcd** là dịch vụ cho phép viết plugin phơi ra các hàm — đây chính là cơ chế
agent tương lai sẽ dùng.

### TR-069 / cwmp
Giao thức cho phép nhà mạng cấu hình router **từ xa**. Router bạn có bật
(`/etc/config/cwmp`), nghĩa là VNPT có thể đẩy cấu hình xuống và ghi đè thay đổi
của bạn bất cứ lúc nào.

---

## 3. Thuật ngữ lập trình

### `async` / `await` / `Future`
**Future** là "kết quả sẽ có sau" — ví dụ đọc file, gọi mạng. `await` nghĩa là
"chờ có kết quả rồi đi tiếp", nhưng **không đóng băng giao diện**.

### `Stream` / `async*` / `yield`
**Stream** là chuỗi giá trị đến dần theo thời gian, khác Future chỉ có một giá
trị. Hàm khai `async*` sinh ra Stream, dùng `yield` để đẩy từng giá trị ra.

Dự án dùng Stream cho việc mô hình sinh chữ dần dần.

### Callback
Một hàm được truyền vào hàm khác để "gọi lại sau". Ví dụ `ToolHost.confirm` là
callback mà công cụ gọi để hiện hộp xác nhận rồi chờ người dùng bấm.

### `enum`
Kiểu dữ liệu chỉ nhận một trong vài giá trị định sẵn. `VlanBackend` chỉ có thể
là `swconfig`, `dsa` hoặc `unknown` — không thể là gì khác.

### `sealed class`
Giống enum nhưng mỗi nhánh mang được dữ liệu riêng. `TurnEvent` là sealed class
với các nhánh `TextDelta` (mang chuỗi chữ), `ToolCallRequested` (mang tên và
tham số)…

Lợi ích: khi viết `switch` mà quên xử lý một nhánh, trình biên dịch báo lỗi ngay.

### `extension`
Cách thêm hàm vào một lớp có sẵn mà không sửa lớp đó. Dự án dùng `extension
UciOps on OpenWrtSession` để `OpenWrtSession` giữ vai trò thuần kênh truyền,
còn các thao tác UCI nằm riêng trong thư mục `agent_side/`.

### Handler
Hàm xử lý một sự kiện hoặc một lời gọi. Trong tool definition, `handler` là hàm
Dart chạy khi mô hình gọi công cụ đó.

### Serialize / JSON codec
**Serialize** là biến đối tượng trong bộ nhớ thành chuỗi văn bản để gửi đi hoặc
lưu lại. **Codec** là cặp hàm chuyển qua lại (`toJson` / `fromJson`).

### stdin / stdout
Hai "ống" chuẩn của mọi chương trình dòng lệnh: **stdin** là đầu vào, **stdout**
là đầu ra. Giao thức agent đẩy JSON vào stdin và đọc JSON từ stdout.

### Shell injection / quoting
**Shell** là trình thông dịch dòng lệnh. Nếu ghép chuỗi người dùng nhập thẳng
vào câu lệnh, một mật khẩu như `abc'; reboot; #` sẽ khiến router **khởi động
lại**. **Quoting** là bọc giá trị lại để shell coi nó là dữ liệu, không phải lệnh.

> Xem `shellQuote` trong `lib/net/agent_side/uci_parser.dart`

### Whitelist (danh sách trắng)
Chỉ cho phép những gì có tên trong danh sách, chặn tất cả phần còn lại. An toàn
hơn blacklist (liệt kê cái bị cấm) vì cái chưa nghĩ tới sẽ mặc định bị chặn.

### Validate
Kiểm tra dữ liệu có hợp lệ không **trước khi** dùng. Dự án validate ở cả hai
phía — ứng dụng để báo lỗi sớm, agent vì "không bao giờ tin client".

### Unit test / fake
**Unit test** kiểm tra một hàm nhỏ, chạy trong vài mili-giây, không cần thiết bị
thật. **Fake** là bản thay thế giả của một thành phần để test — ví dụ
`FakeAgentTransport` trả về JSON dựng sẵn thay vì gọi router thật.

### Refactor
Sắp xếp lại mã mà **không đổi hành vi**. Việc tách `agent_side/` vừa rồi là một
lần refactor: mã chuyển chỗ, chức năng giữ nguyên.

### Adapter
Lớp trung gian dịch giữa hai bên không nói cùng "ngôn ngữ". Kế hoạch
`RouterAdapter` là để mỗi dòng router (OpenWrt, MikroTik, Cisco) có một bản
dịch riêng, còn phần còn lại của ứng dụng không cần biết.

### Contract / protocol version
**Contract** là thoả thuận về định dạng dữ liệu giữa hai bên. **Version** để hai
bên phát hiện khi không còn hiểu nhau, thay vì hỏng giữa chừng.

---

## 4. Tên riêng của dự án

### `agent_side/`
Thư mục chứa mã **sẽ chuyển sang chạy trên router**. Xem `README.md` trong đó.

### `ToolHost`
Vật giữ hai thứ dùng chung cho các công cụ: phiên SSH đang mở, và callback hiện
hộp xác nhận.

### `StagedChange`
Một thay đổi đã ghi vào vùng chờ nhưng chưa commit, kèm mã `token` để lệnh
commit sau đó biết đang nói về thay đổi nào.

### `CommitVerdict`
Kết quả của việc áp dụng thay đổi, có **ba** trạng thái chứ không phải hai:

| Giá trị | Nghĩa |
|---|---|
| `applied_and_live` | Đã ghi **và** đã có hiệu lực thật |
| `committed_not_live` | Đã ghi nhưng **chưa** có hiệu lực |
| `failed` | Không áp dụng được, thiết bị nguyên trạng |

Trạng thái giữa là quan trọng nhất: `uci commit` thành công mà lệnh nạp lại
thất bại thì cấu hình nằm im trong file. Gộp nó vào "xong" là để trợ lý báo cáo
sai.

### Secret marker / redaction
**Marker** là dấu hiệu đánh vào giá trị nhạy cảm (mật khẩu WiFi).
**Redaction** là thay giá trị đó bằng chỗ giữ trước khi ghi vào lịch sử chat.

Mô hình đọc giá trị thật ngay trong lượt đó để trả lời bạn, còn bản lưu trên đĩa
đã được che.

> Xem `lib/llm/secrets.dart`

### Capability negotiation
Bước thiết bị khai báo nó hỗ trợ những công cụ nào, rồi ứng dụng chỉ nạp những
công cụ đó vào prompt.

Điểm mấu chốt về bảo mật: thiết bị chỉ được khai **tên**, không được khai **mô
tả**. Mô tả là thứ mô hình đọc, nên nếu nhận từ thiết bị thì một router bị chiếm
quyền có thể chèn chỉ dẫn vào đầu mô hình.

> Xem `negotiateTools` trong `lib/net/agent_client.dart`
