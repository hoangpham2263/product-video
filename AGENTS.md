# Product Video – hướng dẫn

Repo `hoangpham2263/product-video` (tách từ tool Grok Video của Tools Hub). Máy chủ `src/server.mjs` phục vụ `ui/index.html` cho cả macOS và Windows.

## Cấu trúc

- Gốc repo là app: `src/`, `ui/`, `data/`, `workspace/` (Git bỏ qua: cấu hình, ảnh kho đã tải, kết quả, log, ffmpeg). `core/` là hạ tầng: gọi AI (`core/ai`), bridge (`core/bridge`, cổng 8785) và extension Chrome Product Video (`core/extension`), Cấu hình (`core/setup`: Node.js, extension, Grok), cửa sổ Windows (`core/launch.ps1`, WebView2), cập nhật (`core/update.ps1`), nút Cập nhật/Cấu hình/Tải lại (`core/assets/hub.js`).
- Kho: repo công khai `hoangpham2263/product-video-sources`, `manifest.json` liệt kê nhóm theo loại (`products`, `models`, `videos`), file ở `<loại>/<nhóm>/<tên>`. Ô ảnh sản phẩm và người mẫu có nút **Từ kho** (`src/library.mjs`): chọn ảnh thì tải một lần vào `workspace/library/`. Video trong kho chưa có chỗ dùng trong app.
- Kết quả chỉ lưu trên máy (`workspace/output/`), không đẩy lên đâu. Không Drive, không mật khẩu, không Worker.
- Phát hành: push tag `vX.Y.Z` → Release `product-video.zip`; Cập nhật thay file, giữ `workspace/`, `core/bridge/node_modules`. Trang tải `docs/index.html` (GitHub Pages) chỉ có nút tải.
- Commit chỉ đứng tên người dùng, không thêm dòng Claude.

## Tạo video

Một ảnh sản phẩm (và ảnh người mẫu nếu có) thành một video khoảng 1 phút đi quanh sản phẩm, các cảnh nối liền. Grok web chạy trong Chrome chính đã đăng nhập grok.com, qua extension Product Video và bridge (`core/extension/sites/grok.js`, `Invoke-HubAI -Ai grok -Kind image|video`).

1. **Khung hình** (Grok ảnh, ~10 giây mỗi ảnh): khung 0 là ảnh gốc vẽ lại sạch, nét (góc `as-photo`), hoặc người mẫu đứng cạnh sản phẩm giới thiệu (ảnh sản phẩm + ảnh mẫu); khung i là cùng căn phòng nhìn từ góc của cảnh i, chỉ cho các góc trong `keyframeAngles` (`data/video.json`). Mọi khung tạo từ ảnh sản phẩm gốc, không từ khung trước, để sản phẩm không trôi. Quy tắc giữ đúng sản phẩm: `src/product-rules.ps1` (`Get-VideoProductRules`). Góc lấy từ thư viện riêng của tool, `data/angles.json`.
   Thử 02/11/2026 (kệ đĩa than): Grok sửa ảnh làm tốt cận chi tiết và góc cao; với nghiêng trái/phải nó trả lại gần như góc gốc, góc thấp làm mất đĩa trên kệ, toàn phòng làm kệ cao và hẹp đi. Model video thì xoay máy quanh sản phẩm tốt và giữ dáng. Vì vậy các góc đó không có khung ảnh: video tự đi máy.
2. **Video từng cảnh** (Grok video, ~1 phút mỗi cảnh): cảnh i bắt đầu từ khung cuối thật của video cảnh i-1 (ffmpeg; cảnh 1 từ khung 0), kết thúc ở khung i nếu có (khung cuối của Grok), nên các cảnh nối liền. Cảnh mở đầu có người mẫu: người mẫu giới thiệu rồi đi ra khỏi khung. Sau một cảnh cận (`closeAngles`), cảnh tiếp theo không có khung đích riêng thì kết thúc ở khung 0 (máy lùi ra để lộ toàn bộ sản phẩm): lượt thử 02/11/2026 không có quy tắc này, Grok đi từ cận chi tiết sang nghiêng phải và biến kệ thành một đồ khác. Tỷ lệ khung (9:16, 16:9, 1:1) đặt mỗi lần cho cả ảnh và video, vì Grok nhớ tỷ lệ dùng lần trước.
3. **Ghép** (`src/ffmpeg.ps1`): bỏ khung đầu trùng của mỗi cảnh sau, đưa về cùng cỡ, 30 fps, H.264, không tiếng. ffmpeg trên PATH, nếu không có thì tải bản tĩnh một lần vào `workspace/tools/ffmpeg`.

Kết quả ở `workspace/output/<thời điểm>-<tên>/`: `khung-<i>-<góc>.png`, `clip-<i>.mp4`, `video-<tên>.mp4`, `logs/` (prompt từng bước). Lượt chạy: `src/run-video.ps1` → `Invoke-VideoRun` (`src/video.ps1`), sự kiện `@@EVENT` (`start`, `frame`, `clip`, `final`, `warning`, `done`, `fatal`). Bộ cảnh mặc định, độ phân giải, tỷ lệ khung: `data/video.json`. Độ dài mỗi cảnh mặc định là Tự động: theo loại chuyển động của góc (`secondsByGroup`, `secondsByAngle`: đi máy xa 10 giây, cận và bố cục 6 giây); trang cộng ra video dự kiến và thời gian chờ ngay khi chọn góc, lượt chạy tính lại từ cùng dữ liệu (`Test-VideoJob`). Người dùng vẫn đặt được mọi cảnh 6/10/15 giây. Máy luôn đi nhẹ: cảnh không có khung đích chỉ nghiêng một cung nhỏ 15–20° hoặc đẩy/kéo/lia về phía góc đã chọn, không quay sang phần phòng ảnh không chụp (Grok chỉ có một ảnh, máy xoay càng xa thì càng tự vẽ thêm phòng: sofa mới, cửa sổ và tranh đổi). Người dùng đã bỏ chế độ xoay mạnh; các góc phải ra sau hoặc sang hông 90° (`hiddenAngles`: mặt sau, nghiêng sau, hông trái/phải) không có trong danh sách và bị từ chối khi chạy. Mọi prompt video coi căn phòng là bối cảnh cố định: đồ vật giữ chỗ với nhau, phần ảnh không thấy để trơn, không thêm đồ. Không có bộ thời lượng dựng sẵn: người dùng thấy chọn tổng thời lượng rồi phải khớp góc là ngược.

Lỗi: bận hoặc hết giờ thử lại một lần; đăng nhập, hết lượt, bridge dừng cả lượt; Grok từ chối (kiểm duyệt) chỉ mất bước đó.

### Trang Grok (đã kiểm chứng 02/11/2026)

- Mọi việc dùng ô nhập của `/imagine`: ô file trong form (multiple) đính ảnh vào ô nhập, mỗi ảnh có nút `Remove image`; nút gửi `Submit`. Chế độ là radio `aria-label` Image/Video/Agent; bấm lại đến khi `aria-checked="true"` (trang chưa sẵn sàng thì bỏ qua cú bấm). Ô file ngoài form (mở bài `/imagine/post/<id>`) thay đổi theo chế độ Grok nhớ lần trước: không dùng.
- Chế độ Video, có ảnh đính kèm: `Add last frame`, `Add intermediate frame`, menu `Video duration` (6s/10s/15s), `Video resolution` (480p/720p/1080p), `Aspect Ratio` (Auto, 2:3, 3:2, 1:1, 9:16, 16:9), nút `Video audio` (`aria-pressed`). Menu Radix mở bằng `pointerdown`, chọn bằng click vào `menuitemradio`. Không gửi Escape: Escape rời bài.
- `Add last frame` mở hộp chọn file từ một input tạm: `sites/grok-main.js` (world MAIN) chặn `input.click()` và đưa file vào.
- Sau khi gửi, địa chỉ đổi sang bài mới; kết quả ở `assets.grok.com/users/<uid>/generated/<id>/image.jpg` hoặc `.../generated_video.mp4`. Chữ "100%" trên trang là nút zoom, không phải tiến độ.

## Chưa làm hoặc chưa kiểm chứng

- Chưa có test offline (`tests/`) cho lượt chạy với AI giả.
- Video không tiếng; nhạc nền thêm sau (CapCut).
