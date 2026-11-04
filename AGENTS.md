# Product Video – hướng dẫn

Repo `hoangpham2263/product-video` (tách từ tool Grok Video của Tools Hub). Máy chủ `src/server.mjs` phục vụ `ui/index.html` cho cả macOS và Windows.

## Cấu trúc

- Gốc repo là app: `src/`, `ui/`, `data/`, `workspace/` (Git bỏ qua: cấu hình, ảnh kho đã tải, kết quả, log, ffmpeg). `core/` là hạ tầng: gọi AI (`core/ai`), bridge (`core/bridge`, cổng 8785) và extension Chrome Product Video (`core/extension`), Cấu hình (`core/setup`: Node.js, extension, Grok), cửa sổ Windows (`core/launch.ps1`, WebView2), cập nhật (`core/update.ps1`), nút Cập nhật/Cấu hình/Tải lại (`core/assets/hub.js`).
- Kho: repo công khai `hoangpham2263/product-video-sources`, `manifest.json` liệt kê nhóm theo loại (`products`, `models`, `videos`), file ở `<loại>/<nhóm>/<tên>`. Ô ảnh sản phẩm, người mẫu và video mẫu có nút **Từ kho** (`src/library.mjs`): chọn thì tải một lần vào `workspace/library/`.
- Kết quả chỉ lưu trên máy (`workspace/output/`), không đẩy lên đâu. Không Drive, không mật khẩu, không Worker.
- Phát hành: push tag `vX.Y.Z` → Release `product-video.zip`; Cập nhật thay file, giữ `workspace/`, `core/bridge/node_modules`. Trang tải `docs/index.html` (GitHub Pages) chỉ có nút tải.
- Commit chỉ đứng tên người dùng, không thêm dòng Claude.

## Tạo video

Theo phong cách video mẫu: người dùng chọn ảnh sản phẩm (người mẫu tuỳ chọn) và một video mẫu (tải lên hoặc **Từ kho**, nhóm `videos`). App lấy của video mẫu cách máy chạy, độ dài từng cảnh và chỗ cắt cảnh; bối cảnh là phòng trong ảnh sản phẩm, không dùng gì của phòng trong video mẫu (người dùng chốt 04/11/2026: "cần style chứ không giữ y video"). Grok web chạy trong Chrome chính đã đăng nhập grok.com, qua extension Product Video và bridge (`core/bridge`, cổng 8785).

1. **Đọc video mẫu** (ffmpeg): tách cảnh theo điểm cảnh giữa các khung cách nhau nửa giây (`sceneThreshold`; so từng khung thì chuyển hoà hình không bị bắt), cảnh ngắn hơn `minShot` gộp vào cảnh trước, cảnh dài hơn 15 giây chia thành đoạn nối tiếp; chỉ lấy `maxSeconds` giây đầu, tối đa `maxParts` đoạn (`data/video.json`). Tỷ lệ khung theo video mẫu. `vidstabdetect` (5 khung/giây, rộng 720; chậm hơn thì máy chạy chậm đọc thành đứng yên) đo máy chạy, `src/motion.mjs` ra độ trượt ngang/dọc và đẩy/kéo cho từng chặng khoảng `phaseSeconds` giây của mẫu; prompt ghi lượng cụ thể (to lên bao nhiêu %, trượt bao nhiêu % khung) và giới hạn `maxZoom`, `maxPan` mỗi chặng (thử 04/11/2026: mẫu đi xuyên sang phòng khác, chỉ nói "đẩy vào rõ" thì Grok vòng quanh bàn, tự vẽ phòng mới, bàn đổi dáng). **Độ dài video**: như mẫu hoặc `lengths` (30/45/60 giây), giãn đều mọi cảnh, máy chạy chậm hơn. Lưu ý dấu: vidstab ghi chuyển động ngược (đã kiểm bằng khung đầu/cuối). **Kế hoạch cảnh**: video trong kho có thể kèm `<video>.json` (`{ shots: [{ start, angle }] }`, góc theo `data/angles.json`); có kế hoạch thì cảnh và góc lấy từ đó thay vì tự tách. `build-manifest.mjs` của kho đưa kế hoạch vào `manifest.json`, chọn video từ kho thì app lưu kế hoạch cạnh file.
2. **Khung mở đầu** (Grok ảnh): có ảnh người mẫu thì khung người mẫu đứng cạnh sản phẩm; cảnh có góc khác `as-photo` trong kế hoạch thì khung phòng của ảnh sản phẩm nhìn từ góc đó (mỗi góc một khung, đều tạo từ ảnh gốc). `data/angles.json` là thư viện góc (người dùng muốn giữ làm tham khảo).
3. **Video từng đoạn** (Grok video): từ khung góc của cảnh, nếu không thì ảnh sản phẩm (đoạn đầu: khung người mẫu nếu có), prompt tả máy chạy từng chặng bằng lời; đoạn nối tiếp bắt đầu từ khung cuối thật của đoạn trước. Không có khung đích: thử 04/11/2026, vẽ lại khung của video mẫu nhiều lần làm đồ trong phòng tự xê dịch, đổi dáng.
4. **Ghép**: mỗi clip tăng/giảm tốc cho đúng độ dài đoạn mẫu bằng trộn khung (`framerate`; lặp khung thì giật mỗi nửa giây, `minterpolate` mượt nhưng mất vài phút mỗi clip); đoạn nối tiếp trộn mờ `fadeSeconds` (Grok vẽ lại ảnh đầu ở khung thứ hai nên nối thẳng bị nảy), cảnh mới hoà hình `shotFadeSeconds` (0,5 giây; người dùng thấy cắt thẳng sang góc khác bị giật, 04/11/2026). Mỗi clip dài thêm đúng phần trộn với clip sau nên tổng độ dài vẫn khớp. ffmpeg trên PATH, nếu không có thì tải bản tĩnh một lần vào `workspace/tools/ffmpeg`.

Kết quả ở `workspace/output/<thời điểm>-<tên>/`: `clip-<i>-grok.mp4` (bản Grok), `clip-<i>.mp4` (đúng độ dài), `video-<tên>.mp4`, `logs/` (`mau.json`: các đoạn và máy chạy đo được, `mau.trf`, prompt từng bước). Lượt chạy: `src/run-video.ps1` → `Invoke-VideoRun` (`src/video.ps1`), sự kiện `@@EVENT` (`start`, `frame`, `clip`, `final`, `warning`, `done`, `fatal`).

Lỗi: bận hoặc hết giờ thử lại một lần; đăng nhập, hết lượt, bridge dừng cả lượt; Grok từ chối (kiểm duyệt) chỉ mất bước đó.

### Trang Grok (đã kiểm chứng 02/11/2026)

- Mọi việc dùng ô nhập của `/imagine`: ô file trong form (multiple) đính ảnh vào ô nhập, mỗi ảnh có nút `Remove image`; nút gửi `Submit`. Chế độ là radio `aria-label` Image/Video/Agent; bấm lại đến khi `aria-checked="true"` (trang chưa sẵn sàng thì bỏ qua cú bấm). Ô file ngoài form (mở bài `/imagine/post/<id>`) thay đổi theo chế độ Grok nhớ lần trước: không dùng.
- Chế độ Video, có ảnh đính kèm: `Add last frame`, `Add intermediate frame`, menu `Video duration` (6s/10s/15s), `Video resolution` (480p/720p/1080p), `Aspect Ratio` (Auto, 2:3, 3:2, 1:1, 9:16, 16:9), nút `Video audio` (`aria-pressed`). Menu Radix mở bằng `pointerdown`, chọn bằng click vào `menuitemradio`. Không gửi Escape: Escape rời bài.
- `Add last frame` mở hộp chọn file từ một input tạm: `sites/grok-main.js` (world MAIN) chặn `input.click()` và đưa file vào.
- Sau khi gửi, địa chỉ đổi sang bài mới; kết quả ở `assets.grok.com/users/<uid>/generated/<id>/image.jpg` hoặc `.../generated_video.mp4`. Chữ "100%" trên trang là nút zoom, không phải tiến độ.

## Chưa làm hoặc chưa kiểm chứng

- Chưa có test offline (`tests/`) cho lượt chạy với AI giả.
- Video không tiếng; nhạc nền thêm sau (CapCut).
