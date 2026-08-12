# Đặc tả agent — thư mục này đã trống

Mã từng nằm ở đây đã bị xoá khỏi ứng dụng. Nó thuộc về agent chạy trên router,
và agent chưa được viết. Tài liệu này ghi lại **agent phải làm gì** để thay thế.

Bản mã đã xoá còn trong lịch sử git tại commit `e0a1705`, dùng làm tham chiếu:

```bash
git show e0a1705:chatbot/lib/net/agent_side/uci_writer.dart
```

## Ba file đã xoá và phần việc chúng để lại

| File cũ | Agent phải làm gì thay thế |
|---|---|
| `uci_parser.dart` | Không cần. Agent đọc UCI qua thư viện cục bộ, không bóc tách văn bản `uci show` |
| `uci_writer.dart` | Toàn bộ method `stage` / `commit` / `revert`, và phần ánh xạ tham số sang lệnh `uci` |
| `vlan_backend.dart` | Phần nhận diện cơ chế VLAN, khai báo trong `list` |

Hàm `shellQuote` biến mất hoàn toàn: agent nhận tham số JSON đã có kiểu, không
có chuỗi shell nào để nội suy vào.

## Hợp đồng phải đáp ứng

Agent là một file thực thi, gọi dạng `netagent call <method>`. Nhận **một object
JSON trên stdin**, trả **một object JSON trên stdout**.

Định nghĩa đầy đủ ở `../agent_protocol.dart`. Tóm tắt:

```
{ "ok": true,  "result": { ... } }
{ "ok": false, "error": { "code": "...", "message": "..." } }
```

### `list`

Trả về danh sách **tên** công cụ hỗ trợ, và thiết bị tự mô tả:

```json
{
  "contract_version": 1,
  "agent_version": "lua-0.1",
  "board": "mediatek,mt7987b-spim-snand-362s",
  "release": "21.02-SNAPSHOT",
  "target": "mediatek/mt7987",
  "tools": ["get_wifi_info", "get_network_info", "set_wifi"]
}
```

**Không được trả về mô tả công cụ.** Mô tả là thứ đi thẳng vào ngữ cảnh của mô
hình; ứng dụng sở hữu toàn bộ chữ nghĩa đó. Thiết bị chỉ được nói nó hỗ trợ
*tên* nào. Lý do ở `negotiateTools` trong `../agent_client.dart`.

Chỉ khai những công cụ **thực sự chạy được**. Router không có switch thì đừng
khai `set_vlan` — công cụ không khai sẽ không tốn token nào trong prompt.

### `call` — thao tác chỉ đọc

Nhận `{"tool": "get_wifi_info", "args": {...}}`, trả kết quả nguyên dạng. Không
staging, không xác nhận.

Trường tên `password`, `key`, `sae_password` sẽ được ứng dụng che khi lưu vào
lịch sử chat.

### `stage` — chuẩn bị thay đổi

Nhận `{"tool": "set_wifi", "args": {...}}`. Phải:

1. **Validate lại toàn bộ tham số.** Ứng dụng đã validate nhưng không được tin
   client.
2. Chạy `uci revert <package>` trước, để lần staging bỏ dở trước đó không lẫn vào.
3. Ánh xạ tham số sang lệnh `uci set`.
4. Trả về:

```json
{ "token": "...", "diff": "<uci changes>", "summary": "...", "warning": "..." }
```

`token` định danh lần staging này, để `commit` không áp nhầm thay đổi khác.
`diff` là output `uci changes` nguyên văn — ứng dụng hiện đúng chuỗi đó cho
người dùng duyệt.

### `commit` — áp dụng và **kiểm chứng**

Nhận `{"token": "..."}`. Phải:

1. `uci commit`
2. Chạy lệnh áp dụng (`wifi reload`, `/etc/init.d/network reload`…)
3. **Đọc lại config** vừa ghi, so với ý định
4. **Kiểm tra trạng thái sống** — `iwinfo`, `ubus call network.wireless status`
5. Trả bằng chứng:

```json
{
  "verdict": "applied_and_live",
  "config_readback": { "wireless.ra0.ssid": { "expected": "X", "actual": "X" } },
  "runtime_state": { "ra0.up": true }
}
```

`verdict` chỉ nhận ba giá trị:

| Giá trị | Nghĩa |
|---|---|
| `applied_and_live` | Đã ghi **và** kiểm chứng thấy có hiệu lực |
| `committed_not_live` | Đã ghi nhưng kiểm chứng **không** xác nhận |
| `failed` | Không áp dụng được, thiết bị nguyên trạng |

Bước 3 và 4 là lý do chính agent tồn tại. Ứng dụng chỉ thấy exit code, nên
không phân biệt được `applied_and_live` với `committed_not_live`. Firmware
MediaTek đang dùng có `/sbin/wifi` viết bằng Lua và chưa rõ nó hỗ trợ `reload`
hay không — đúng tình huống trạng thái giữa xảy ra.

### `revert`

Nhận `{"token": "..."}`, chạy `uci revert`, trả result rỗng. Gọi hai lần phải
an toàn.

## Lưu ý khi hiện thực

- Viết bằng **Lua**: router đang dùng đã có sẵn (`/sbin/wifi` chính là Lua), và
  có thư viện JSON tử tế. Nếu cần phủ bản OpenWrt tối giản không có Lua thì
  viết bản shell dùng `jshn`, hợp đồng không đổi.
- Đặt tại `/usr/libexec/rpcd/netagent` theo chuẩn plugin rpcd, để sau này phơi
  qua `ubus` mà không phải viết lại.
- Nên có **tự hoàn tác theo thời gian chờ** cho thay đổi WAN và VLAN: commit
  rồi hẹn giờ; nếu ứng dụng không xác nhận lại kịp — tức kết nối đã đứt vì
  chính thay đổi đó — thì tự khôi phục.

## Khi agent xong

Xoá luôn thư mục này. Ứng dụng không cần thay đổi gì: `net_tools.dart` đã gọi
`AgentClient` sẵn rồi.
