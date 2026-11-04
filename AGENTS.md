# Product Video – hướng dẫn

Repo `hoangpham2263/product-video` (tách từ tool Grok Video của Tools Hub). Máy chủ `src/server.mjs` phục vụ `ui/index.html` cho cả macOS và Windows.

## Cấu trúc

- Gốc repo là app: `src/`, `ui/`, `data/`, `workspace/` (Git bỏ qua: cấu hình, ảnh kho đã tải, kết quả, log, ffmpeg). `core/` là hạ tầng: gọi AI (`core/ai`), bridge (`core/bridge`, cổng 8785) và extension Chrome Product Video (`core/extension`), Cấu hình (`core/setup`: Node.js, extension, Grok), cửa sổ Windows (`core/launch.ps1`, WebView2), cập nhật (`core/update.ps1`), nút Cập nhật/Cấu hình/Tải lại (`core/assets/hub.js`).
- Kho: repo công khai `hoangpham2263/product-video-sources`, `manifest.json` liệt kê nhóm theo loại (`products`, `models`, `videos`), file ở `<loại>/<nhóm>/<tên>`. Ô ảnh sản phẩm, người mẫu và video mẫu có nút **Từ kho** (`src/library.mjs`): chọn thì tải một lần vào `workspace/library/`.
- Kết quả chỉ lưu trên máy (`workspace/output/`), không đẩy lên đâu. Không Drive, không mật khẩu, không Worker.
- Phát hành: push tag `vX.Y.Z` → Release `product-video.zip`; Cập nhật thay file, giữ `workspace/`, `core/bridge/node_modules`. Trang tải `docs/index.html` (GitHub Pages) chỉ có nút tải.
- Commit chỉ đứng tên người dùng, không thêm dòng Claude.

## Tạo video

Một cách làm duy nhất (người dùng chốt 04/11/2026, sau khi thử các cách khác): video là chuỗi **cảnh ngắn** (tối đa `shotSeconds`, 2,6 giây), mỗi cảnh một góc và một kiểu máy chạy. **Codex CLI** vẽ khung góc từ ảnh sản phẩm, **Grok** quay mỗi cảnh một clip 6 giây từ khung đó, lấy phần đầu ở tốc độ thật, hoà hình `fadeSeconds` (0,4 giây). Người dùng gửi ảnh sản phẩm (bắt buộc), người mẫu (tuỳ chọn, giới thiệu ở cảnh đầu) và **video mẫu (tuỳ chọn)**: chỉ học **cách làm** (nhịp cắt, chuỗi góc, máy chạy), không lấy hình hay phòng của mẫu; bối cảnh luôn là phòng trong ảnh sản phẩm. Grok web chạy trong Chrome chính đã đăng nhập grok.com, qua extension Product Video và bridge (`core/bridge`, cổng 8785).

Vì sao như vậy (thử 04/11/2026): Grok giữ sản phẩm đúng trong 2–3 giây đầu rồi trôi (clip 15 giây làm bàn cong, đổi dáng; ghim khung mỗi 3 giây làm sản phẩm đổi dáng ở chỗ nối; vẽ lại khung của video mẫu làm đồ trong phòng tự xê dịch). Grok tự vẽ góc mới làm sản phẩm to nhỏ khác nhau so với phòng (bàn trà cao hơn mặt ngồi sofa); Codex giữ đúng. Cắt thẳng sang góc khác thấy giật nên dùng hoà hình.

Mã nguồn:
- `src/plan.ps1`: **kế hoạch cảnh**, không gọi AI; lượt chạy và trang phân tích dùng chung. Có video mẫu: chỗ cắt theo kế hoạch `<video>.json` nếu có (`{ note?, shots: [{ start, angle }] }`, góc theo `data/angles.json`), không thì ffmpeg tách theo điểm cảnh giữa các khung cách nhau nửa giây (`sceneThreshold`; so từng khung thì hoà hình không bị bắt), cảnh ngắn hơn `minShot` gộp vào cảnh trước, chỉ lấy `maxSeconds` giây đầu (`Get-SampleScenes`). Mỗi cảnh chia đều thành cảnh ngắn (`Get-SampleShots`): cảnh ngắn đầu lấy góc của kế hoạch, còn lại lần lượt theo `angles` (không lặp liền nhau, không trùng góc kế hoạch của cảnh sau, mở đầu `as-photo`). Máy chạy: `vidstabdetect` (5 khung/giây, rộng 720) + `src/motion.mjs` (dấu của vidstab ngược, đã đảo). Không có video mẫu: `defaultShots` lần lượt, mỗi cảnh có sẵn góc và chuyển động (`Get-DefaultShots`). Độ dài `lengths` (0 = như mẫu; không mẫu thì `defaultLength`), giãn đều mọi cảnh; tối đa `maxShots` cảnh. Prompt máy chạy (`Get-ShotMoveText`): lượng chuyển động của cảnh rải ra cả clip 6 giây (vì chỉ lấy phần đầu), ghi rõ to lên bao nhiêu %, trượt bao nhiêu % khung, giới hạn `maxZoom`, `maxPan` (mẫu đi xuyên sang phòng khác mà chỉ nói "đẩy vào rõ" thì Grok tự vẽ phòng mới). Khổ (`Get-VideoAspect`): `aspects`, auto theo video mẫu, không mẫu thì 2:3; Codex chỉ vẽ 2:3, 3:2, 1:1 và Grok video giữ khổ ảnh đầu, nên chỉ có ba khổ này.
- `src/prompts.ps1`: câu lệnh khung người mẫu, khung góc (đoạn SIZE: giữ tỷ lệ sản phẩm so với ghế, sofa, quầy xung quanh) và clip.
- `src/video.ps1`: lượt chạy `Invoke-VideoRun` (gọi từ `src/run-video.ps1`): (1) kế hoạch, (2) khung Codex cho mọi góc cần (và người mẫu) chạy `codexParallel` tiến trình cùng lúc (`Invoke-CodexFrames`, `Start-Job`, mỗi khung 1–2 phút; `as-photo` chỉ vẽ khi ảnh khác khổ video), (3) clip Grok 6 giây mỗi cảnh (`Invoke-GrokClip`; bận hoặc hết giờ thử lại một lần; đăng nhập, hết lượt, bridge dừng cả lượt; kiểm duyệt chỉ mất cảnh đó), (4) cắt phần đầu (`Set-HubVideoCut`), ghép hoà hình (`Join-ShotClips`, về yuv420p cho điện thoại phát được). Sự kiện `@@EVENT`: `start` (folder, frames, shots, seconds, aspect), `frame`, `clip`, `final`, `warning`, `done`, `fatal`.
- `src/analyze-reference.ps1` + trang **Phân tích video mẫu**: đọc video mẫu đúng như lượt chạy (cảnh, máy chạy, góc, mỗi cảnh thành bao nhiêu cảnh ngắn, hình giữa cảnh); sửa góc rồi **Lưu kế hoạch** ghi `<video>.json` cạnh video để lần tạo sau dùng. Video trong kho có thể kèm sẵn kế hoạch (`build-manifest.mjs` của kho đưa vào `manifest.json`, chọn từ kho thì app lưu cạnh file).
- `src/ffmpeg.ps1`: ffmpeg trên PATH, nếu không có thì tải bản tĩnh một lần vào `workspace/tools/ffmpeg`.

Kết quả ở `workspace/output/<thời điểm>-<tên>/`: `khung-<góc>.png`, `clip-<i>-grok.mp4` (bản Grok 6 giây), `clip-<i>.mp4` (phần dùng), `video-<tên>.mp4`, `logs/` (`ke-hoach.json`, `mau.trf`, prompt từng bước).

### Trang Grok (đã kiểm chứng 02/11/2026)

- Mọi việc dùng ô nhập của `/imagine`: ô file trong form (multiple) đính ảnh vào ô nhập, mỗi ảnh có nút `Remove image`; nút gửi `Submit`. Chế độ là radio `aria-label` Image/Video/Agent; bấm lại đến khi `aria-checked="true"` (trang chưa sẵn sàng thì bỏ qua cú bấm). Ô file ngoài form (mở bài `/imagine/post/<id>`) thay đổi theo chế độ Grok nhớ lần trước: không dùng.
- Chế độ Video, có ảnh đính kèm: `Add last frame`, `Add intermediate frame`, menu `Video duration` (6s/10s/15s), `Video resolution` (480p/720p/1080p), `Aspect Ratio` (Auto, 2:3, 3:2, 1:1, 9:16, 16:9), nút `Video audio` (`aria-pressed`). Menu Radix mở bằng `pointerdown`, chọn bằng click vào `menuitemradio`. Không gửi Escape: Escape rời bài.
- `Add last frame` mở hộp chọn file từ một input tạm: `sites/grok-main.js` (world MAIN) chặn `input.click()` và đưa file vào.
- Sau khi gửi, địa chỉ đổi sang bài mới; kết quả ở `assets.grok.com/users/<uid>/generated/<id>/image.jpg` hoặc `.../generated_video.mp4`. Chữ "100%" trên trang là nút zoom, không phải tiến độ.

## Chưa làm hoặc chưa kiểm chứng

- Test offline: `node --test tests/*.test.mjs` (kho, `motion.mjs`, `plan.ps1`); chưa có test lượt chạy với AI giả.
- Video không tiếng; nhạc nền thêm sau (CapCut).
