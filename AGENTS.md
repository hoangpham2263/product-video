# Product Video – hướng dẫn

Repo `hoangpham2263/product-video` (tách từ tool Grok Video của Tools Hub). Máy chủ `src/server.mjs` phục vụ `ui/index.html` cho cả macOS và Windows.

## Cấu trúc

- Gốc repo là app: `src/`, `ui/`, `data/`, `workspace/` (Git bỏ qua: cấu hình, ảnh kho đã tải, kết quả, log, ffmpeg). `core/` là hạ tầng: gọi AI (`core/ai`), bridge (`core/bridge`, cổng 8785) và extension Chrome Product Video (`core/extension`), Cấu hình (`core/setup`: Node.js, extension, Grok), cửa sổ Windows (`core/launch.ps1`, WebView2), cập nhật (`core/update.ps1`), nút Cập nhật/Cấu hình/Tải lại (`core/assets/hub.js`).
- Kho: repo công khai `hoangpham2263/product-video-sources`, `manifest.json` liệt kê nhóm theo loại (`products`, `models`, `videos`), file ở `<loại>/<nhóm>/<tên>`. Ô ảnh sản phẩm, người mẫu và video mẫu có nút **Từ kho** (`src/library.mjs`): chọn thì tải một lần vào `workspace/library/`.
- Kết quả chỉ lưu trên máy (`workspace/output/`), không đẩy lên đâu. Không Drive, không mật khẩu, không Worker.
- Phát hành: push tag `vX.Y.Z` → Release `product-video.zip`; Cập nhật thay file, giữ `workspace/`, `core/bridge/node_modules`. Trang tải `docs/index.html` (GitHub Pages) chỉ có nút tải.
- Commit chỉ đứng tên người dùng, không thêm dòng Claude.

## Tạo video

Làm theo video mẫu: người dùng chọn ảnh sản phẩm (người mẫu tuỳ chọn) và một video mẫu (tải lên hoặc **Từ kho**, nhóm `videos`), app quay sản phẩm theo đúng cách quay của video mẫu. Không còn thư viện góc, không tự xếp cảnh (người dùng bỏ ngày 04/11/2026). Grok web chạy trong Chrome chính đã đăng nhập grok.com, qua extension Product Video và bridge (`core/bridge`, cổng 8785).

1. **Đọc video mẫu** (ffmpeg): tách cảnh theo chỗ cắt (`sceneThreshold`), cảnh ngắn hơn `minShot` gộp vào cảnh trước, cảnh dài hơn 15 giây chia đều thành đoạn nối tiếp; chỉ lấy `maxSeconds` giây đầu, tối đa `maxParts` đoạn (`data/video.json`). Tỷ lệ khung lấy theo video mẫu (9:16, 16:9, 1:1).
2. **Khung hình** (Grok ảnh): khung đầu mỗi cảnh và khung cuối mỗi đoạn của video mẫu, vẽ lại với sản phẩm thay món đồ chính của cảnh; cùng máy, phòng, ánh sáng. Ảnh 1 là khung mẫu, ảnh 2 sản phẩm, ảnh 3 người mẫu (thay người trong video mẫu nếu có). Quy tắc giữ đúng sản phẩm: `src/product-rules.ps1`.
3. **Video từng đoạn** (Grok video): từ khung đầu tới khung cuối, nên máy đi như video mẫu; đoạn nối tiếp bắt đầu từ khung cuối thật của đoạn trước. Mỗi cảnh chia đoạn dài tối đa `partSeconds` (3 giây), cuối mỗi đoạn là một khung lấy từ video mẫu nên máy bám đường đi của mẫu; khung sau của một cảnh lấy khung đầu đã vẽ làm chuẩn cho sản phẩm. Grok chỉ làm 6/10/15 giây: mỗi clip được tăng/giảm tốc (trộn khung) cho đúng độ dài đoạn mẫu.
4. **Ghép** (`src/ffmpeg.ps1`): cùng cỡ, 30 fps, H.264, không tiếng. ffmpeg trên PATH, nếu không có thì tải bản tĩnh một lần vào `workspace/tools/ffmpeg`.

Kết quả ở `workspace/output/<thời điểm>-<tên>/`: `mau-<i>.png` (khung video mẫu), `khung-<i>.png`, `clip-<i>-grok.mp4` (bản Grok), `clip-<i>.mp4` (đã chỉnh độ dài), `video-<tên>.mp4`, `logs/` (`mau.json`: các đoạn; prompt từng bước). Lượt chạy: `src/run-video.ps1` → `Invoke-VideoRun` (`src/video.ps1`), sự kiện `@@EVENT` (`start`, `frame`, `clip`, `final`, `warning`, `done`, `fatal`).

Lỗi: bận hoặc hết giờ thử lại một lần; đăng nhập, hết lượt, bridge dừng cả lượt; Grok từ chối (kiểm duyệt) chỉ mất bước đó.

### Trang Grok (đã kiểm chứng 02/11/2026)

- Mọi việc dùng ô nhập của `/imagine`: ô file trong form (multiple) đính ảnh vào ô nhập, mỗi ảnh có nút `Remove image`; nút gửi `Submit`. Chế độ là radio `aria-label` Image/Video/Agent; bấm lại đến khi `aria-checked="true"` (trang chưa sẵn sàng thì bỏ qua cú bấm). Ô file ngoài form (mở bài `/imagine/post/<id>`) thay đổi theo chế độ Grok nhớ lần trước: không dùng.
- Chế độ Video, có ảnh đính kèm: `Add last frame`, `Add intermediate frame`, menu `Video duration` (6s/10s/15s), `Video resolution` (480p/720p/1080p), `Aspect Ratio` (Auto, 2:3, 3:2, 1:1, 9:16, 16:9), nút `Video audio` (`aria-pressed`). Menu Radix mở bằng `pointerdown`, chọn bằng click vào `menuitemradio`. Không gửi Escape: Escape rời bài.
- `Add last frame` mở hộp chọn file từ một input tạm: `sites/grok-main.js` (world MAIN) chặn `input.click()` và đưa file vào.
- Sau khi gửi, địa chỉ đổi sang bài mới; kết quả ở `assets.grok.com/users/<uid>/generated/<id>/image.jpg` hoặc `.../generated_video.mp4`. Chữ "100%" trên trang là nút zoom, không phải tiến độ.

## Chưa làm hoặc chưa kiểm chứng

- Chưa có test offline (`tests/`) cho lượt chạy với AI giả.
- Video không tiếng; nhạc nền thêm sau (CapCut).
