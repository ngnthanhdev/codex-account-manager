# Codex Account Manager

Ứng dụng macOS local-first để quản lý nhiều account Codex Desktop trên cùng một máy Mac. App giúp bạn lưu từng account thành profile riêng, switch qua lại nhanh, xem token hiện tại khi cần debug, và tự lưu lại token mới sau khi bạn đăng nhập lại.

Codex Account Manager được thiết kế cho workflow dùng nhiều tài khoản như personal, work, team hoặc client account mà không phải tự copy `auth.json` thủ công.

## Điểm nổi bật

- Quản lý nhiều profile Codex trên macOS.
- Switch account Codex Desktop chỉ bằng một nút.
- Lưu và khôi phục `~/.codex/auth.json`.
- Lưu và khôi phục state của Codex Desktop tại `~/Library/Application Support/Codex`.
- Xem metadata account: auth mode, email/account id, thời điểm refresh token.
- Token Vault có chế độ ẩn token mặc định, reveal thủ công và copy vào clipboard.
- Tự động lưu token mới vào active profile sau khi bạn đăng nhập lại.
- Chạy hoàn toàn local, không gửi token hoặc profile data lên server.

## Yêu cầu

- macOS.
- Đã cài Codex Desktop App.
- Đã có Swift compiler, thường đi kèm Xcode Command Line Tools.

Kiểm tra Swift:

```bash
swift --version
```

Nếu chưa có Command Line Tools:

```bash
xcode-select --install
```

## Cài đặt

Clone repo:

```bash
git clone https://github.com/ngnthanhdev/codex-account-manager.git
cd codex-account-manager
```

Build app:

```bash
chmod +x build-app.sh codex-account-switcher.sh
./build-app.sh
```

Mở app:

```bash
open "build/Codex Account Switcher.app"
```

Sau khi mở, app sẽ hiện cửa sổ **Codex Account Manager**. Nếu cửa sổ chưa hiện, bấm app trên Dock hoặc chọn menu **Window > Show Manager**.

## Cách sử dụng

### 1. Lưu account đầu tiên

1. Mở Codex Desktop.
2. Đăng nhập account đầu tiên.
3. Mở Codex Account Manager.
4. Nhập tên profile, ví dụ:

```text
personal
```

5. Bấm **Capture**.

App sẽ lưu login state hiện tại thành profile `personal`.

### 2. Thêm account khác

1. Trong Codex Desktop, log out account hiện tại.
2. Đăng nhập account khác.
3. Quay lại Codex Account Manager.
4. Nhập tên profile mới, ví dụ:

```text
work
```

5. Bấm **Capture**.

### 3. Switch account

1. Chọn profile trong danh sách bên trái.
2. Bấm **Switch to Selected**.

Khi switch, app sẽ:

- Quit Codex Desktop.
- Lưu state hiện tại vào active profile.
- Khôi phục profile được chọn.
- Mở lại Codex Desktop.

## Token Vault

Token Vault đọc token từ `auth.json` của profile đang chọn.

- Token luôn bị ẩn mặc định.
- Bật **Reveal** để xem token.
- Bấm **Copy** để copy token đang chọn vào clipboard.
- Token không được in ra terminal, không ghi log, không gửi qua network.

Các token thường thấy:

- `access_token`
- `refresh_token`
- `id_token`

## Xử lý lỗi refresh token bị revoke

Nếu Codex báo lỗi:

```text
Your access token could not be refreshed because your refresh token was revoked.
Please log out and sign in again.
```

nghĩa là refresh token trong profile đó đã bị OpenAI revoke. App không thể tự refresh một token đã bị revoke. Cách xử lý:

1. Switch tới profile bị lỗi.
2. Trong Codex Desktop, log out.
3. Đăng nhập lại đúng account đó.
4. Đợi vài giây, app sẽ tự lưu token mới vào active profile.
5. Nếu muốn lưu ngay, bấm **Save Token**.

Nếu bạn cũng muốn cập nhật lại toàn bộ state Codex Desktop sau khi login lại, bấm **Save Active**.

## CLI

App sử dụng script local `codex-account-switcher.sh` phía sau. Bạn cũng có thể dùng trực tiếp:

```bash
./codex-account-switcher.sh capture personal
./codex-account-switcher.sh switch work
./codex-account-switcher.sh save-auth personal
./codex-account-switcher.sh list
./codex-account-switcher.sh active
```

## Đóng góp

Bug fix và cải thiện dự án được welcome qua pull request.

- Báo bug bằng GitHub Issues.
- Gửi fix bằng Pull Request vào branch `main`.
- Không gửi token, `auth.json`, cookie, profile folder hoặc dữ liệu đăng nhập thật.
- Xem chi tiết trong [CONTRIBUTING.md](CONTRIBUTING.md).

Để mọi thay đổi đều cần owner review trước khi merge, bật branch protection cho `main` trong GitHub:

1. Vào **Settings > Branches**.
2. Tạo rule cho branch `main`.
3. Bật **Require a pull request before merging**.
4. Bật **Require approvals**.
5. Bật **Require review from Code Owners**.

## Dữ liệu local

Profile được lưu tại:

```text
~/Library/Application Support/CodexAccountSwitcher
```

Cấu trúc mỗi profile:

```text
profiles/<name>/auth/auth.json
profiles/<name>/app-support/Codex
profiles/<name>/profile.env
```

Không commit hoặc chia sẻ thư mục profile này. Nó chứa token, cookie và state đăng nhập của Codex Desktop.

## Bảo mật

Codex Account Manager là app local-only:

- Không upload token.
- Không gửi request đến server riêng.
- Không lưu token vào Git.
- Không log token ra file hoặc terminal.

Bạn vẫn nên coi profile folder là dữ liệu nhạy cảm, giống như password hoặc browser session.

## Build output

Sau khi build thành công:

```text
build/Codex Account Switcher.app
```

Thư mục `build/` được ignore khỏi Git.

## License

MIT License. Xem [LICENSE](LICENSE).
