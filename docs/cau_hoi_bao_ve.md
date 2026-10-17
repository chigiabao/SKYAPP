# Câu hỏi bảo vệ dự kiến và gợi ý trả lời

Số liệu lấy từ `notebooks/weather_forecasting.ipynb` (v2), `notebooks/global_model.ipynb` và `backend/models/v3/` (v3, gồm `extension_v3.json`). Chi tiết xem [bao_cao.md](bao_cao.md).

---

## A. Dữ liệu và hệ thống

**1. Sao không gọi thẳng một API thời tiết có sẵn mà phải tự làm backend và mô hình?**

Mục tiêu đồ án là làm được cả chuỗi dữ liệu → mô hình → API → ứng dụng, tức nhóm 11 của đề bài (nhập dữ liệu, huấn luyện, đánh giá, quản lý phiên bản). Gọi API có sẵn thì chỉ có phần giao diện. Có backend riêng cũng giúp kiểm soát định dạng dữ liệu và thay nguồn sau này mà không phải sửa app. Nếu làm sản phẩm thật, nhóm sẽ dùng API dự báo chuyên nghiệp làm nguồn chính và coi mô hình của mình là lớp bổ sung.

**2. Dữ liệu có phải số đo thật không?**

Không. Đây là đầu ra mô hình thời tiết của Open-Meteo trên lưới khoảng 8 km, theo giờ. Mô hình AI học cách dự báo lại chính bộ dữ liệu này, nên chưa biết độ chính xác so với thời tiết thực tế đo được ở TP.HCM. Báo cáo và app đều ghi rõ điều này.

**3. App bao phủ những đâu?**

TP.HCM mới sau sáp nhập 2025 với Bình Dương và Bà Rịa – Vũng Tàu: 168 phường/xã/đặc khu lấy từ OpenStreetMap, gộp thành 67 ô lưới Open-Meteo. Điểm `tsn` (gần Tân Sơn Nhất) của giai đoạn đầu là alias của một ô trong số đó. GPS ngoài ranh giới thành phố nhận thông báo "Ngoài vùng hỗ trợ (TP.HCM)".

**4. Danh sách theo giờ và theo ngày trong app có phải dự báo không?**

Một phần. Backend ghép theo thứ tự: các giờ đã có dữ liệu, rồi dự báo Open-Meteo mới nhất (cập nhật mỗi giờ), cuối cùng là trung bình nhiều năm nếu vẫn thiếu. Mỗi mục có trường `source` và app hiển thị huy hiệu nguồn tương ứng. Ô chưa đủ khoảng 2 năm dữ liệu (sau khi ghép lịch sử backfill) thì dùng trung bình nhiều năm của `tsn`.

**5. Dữ liệu được cập nhật thế nào?**

Backend chạy ingest khi khởi động rồi mỗi giờ vào phút 05, cho 68 chuỗi (67 ô + `tsn`). Chuỗi nào lỗi được ghi lại và lần sau tự bù. `/health` cho biết có bao nhiêu ô có dữ liệu trong 3 giờ qua. Lịch sử dài cho huấn luyện được tải riêng bằng `scripts/backfill_history.py`, có ngân sách gọi API theo phút/giờ/ngày và chạy tiếp được khi bị ngắt.

**6. App có thu thập vị trí người dùng không?**

App chỉ dùng GPS để hỏi backend phường/xã nào chứa vị trí, sau đó chỉ lưu **id phường/xã**, không lưu tọa độ. Backend nhận tọa độ trong yêu cầu nhưng không ghi lại. Mọi chức năng dùng được không cần đăng nhập; tài khoản là tuỳ chọn và dữ liệu đồng bộ không chứa tọa độ. Lịch sử chuyến đi chỉ lưu id phường đầu/cuối, không lưu vết GPS.

## B. Mô hình AI

**7. Làm sao biết mô hình không bị rò rỉ dữ liệu (data leakage)?**

- Chia theo thời gian, không xáo trộn. v3: train đến 30/06/2024, validation 08/07–24/12/2024, test từ 01/01/2025; đệm 7 ngày giữa các tập, và một dòng chỉ thuộc một tập khi cả *t* và *t+6h* nằm trong tập đó.
- Đặc trưng chỉ dùng lag về quá khứ và cửa sổ trượt về sau (không căn giữa).
- Kiểm tra nhiễu tương lai: thay mọi giá trị sau *t* bằng số ngẫu nhiên thì đặc trưng tại *t* không đổi (v3: 0/60 thời điểm thay đổi).
- Không dùng cột nhãn, `precipitation_probability` (bản thân là dự báo), `visibility`, `rain`.
- Early stopping và ngưỡng mưa chỉ dùng validation; test chỉ dùng để báo cáo.
- Đặc trưng tĩnh (tọa độ, độ cao, khoảng cách tới biển, vùng) không đổi theo thời gian nên không mang thông tin tương lai. Climatology cơ sở chỉ tính từ tập train.

**8. Kết quả v3 có tốt thật không?**

Trung bình trên 67 ô, MAE nhiệt độ là 0,344 / 0,579 / 0,699 °C ở 1 / 3 / 6 giờ, so với 0,691 / 1,774 / 3,046 của persistence và 1,024 của climatology. F1 mưa là 0,685 / 0,555 / 0,513, so với 0,668 / 0,464 / 0,347 của persistence. Tính cả MAE và F1 ở cả 3 tầm, v3 tốt hơn cả hai mô hình cơ sở ở 63/67 ô. Lưu ý đây là sai số so với dữ liệu mô hình Open-Meteo, không phải so với nhiệt kế thật.

**9. Sao mưa 1 giờ gần như không thắng persistence?**

Mưa thường kéo dài nhiều giờ, nên "giờ tới giống giờ này" đã rất mạnh ở tầm 1 giờ. Ở v3, 3 trong 4 ô thua chỉ thua F1 mưa 1 giờ với chênh 0,001–0,002. Lợi thế của mô hình rõ ở 3 và 6 giờ, nơi v3 thắng ở cả 67 ô.

**10. Accuracy mưa thấp hơn climatology nghĩa là mô hình tệ hơn?**

Không hẳn. Khoảng 82% số giờ là khô, nên climatology gần như luôn đoán "không mưa" vẫn có Accuracy cao nhưng bỏ sót phần lớn giờ mưa. Ngưỡng của mô hình được chọn để bắt được nhiều giờ mưa hơn, đổi lại có thêm báo động nhầm. Với dữ liệu mất cân bằng, F1 và Brier phản ánh tốt hơn (ví dụ v2 tại `tsn`: Brier 0,109 / 0,112 so với 0,120 của climatology).

**11. v3 so với v2 tại Tân Sơn Nhất thế nào?**

Trên cùng các giờ test từ 2025: MAE v3 là 0,360 / 0,623 / 0,753 so với 0,379 / 0,647 / 0,791 của v2; F1 mưa v3 là 0,670 / 0,552 / 0,514 so với 0,653 / 0,535 / 0,525. v3 tốt hơn ở nhiệt độ và mưa 1–3 giờ, kém một chút ở mưa 6 giờ.

**12. Tại sao chọn LightGBM mà không dùng LSTM/Transformer?**

Dữ liệu dạng bảng với đặc trưng lag và trượt tạo thủ công. Gradient boosting huấn luyện nhanh (v3 với khoảng 2,3 triệu dòng mất khoảng 8 phút cho cả 12 mô hình), ít cần tinh chỉnh và dễ giải thích qua độ quan trọng đặc trưng. Nhóm chưa thử mô hình học sâu nên không khẳng định mô hình nào tốt hơn.

**13. Đã tinh chỉnh siêu tham số chưa?**

Chưa. v3 dùng một bộ tham số cố định (learning_rate 0,05, num_leaves 63, …) với early stopping trên validation. Chỉ ngưỡng mưa được chọn theo F1 trên validation (0,39 / 0,33 / 0,32), dùng chung cho mọi ô.

**14. Làm sao đảm bảo mô hình trong backend giống lúc huấn luyện?**

Huấn luyện và backend dùng chung hàm tạo đặc trưng trong `backend/ai_model.py`; đặc trưng tĩnh của ô được đọc từ cùng file `cell_static.json`. Backend kiểm tra `feature_columns.json` khớp với code khi nạp mô hình, nếu không thì dùng v2. Notebook gọi đúng hàm suy luận của backend trên 15 cửa sổ 48 giờ; chênh lệch lớn nhất là 0,0047, chỉ do làm tròn.

## C. Đa địa điểm và mô hình toàn cục

**15. Vì sao gộp 168 phường thành 67 ô lưới?**

Open-Meteo trả dữ liệu theo ô lưới (ở đây khoảng 0,07° × 0,08°, cỡ 8 km), không theo phường. Nhiều phường nhỏ ở nội thành rơi vào cùng một ô nên nhận về số liệu giống hệt nhau. Gộp lại giúp chỉ lưu, cập nhật và dự báo 67 chuỗi thay vì 168 chuỗi trùng lặp, tiết kiệm ngân sách API và dung lượng. Đổi lại, các phường trong một ô có cùng số liệu; app nói rõ đánh giá là "tại ô lưới này".

**16. Vì sao dùng một mô hình toàn cục thay vì 67 mô hình riêng?**

Hầu hết ô chỉ có dữ liệu từ 2023, train khoảng 18 tháng, ít để huấn luyện riêng từng ô. Quy luật vật lý (chu kỳ ngày, mưa kéo dài, xu hướng áp suất) giống nhau giữa các ô, nên một mô hình học chung trên khoảng 930 nghìn dòng train sẽ ổn định hơn. Đặc trưng tĩnh (tọa độ, độ cao, khoảng cách tới biển, vùng) cho phép mô hình điều chỉnh theo vị trí. Một mô hình cũng dễ quản lý phiên bản hơn 67 mô hình. Kết quả: tại `tsn`, v3 tốt hơn v2 vốn được huấn luyện riêng cho điểm này về nhiệt độ.

**17. Spatial holdout là gì và cho kết quả gì?**

Là huấn luyện một mô hình riêng **không có** một nhóm ô, rồi đánh giá trên chính các ô đó, để biết mô hình làm được gì ở vùng chưa từng thấy. Nhóm giữ lại 31 ô: toàn bộ Bà Rịa – Vũng Tàu cũ (gồm Côn Đảo) và cụm ô quanh Thủ Dầu Một. Mô hình holdout vẫn tốt hơn cả hai mô hình cơ sở ở mọi chỉ số tại 23/31 ô; MAE nhiệt độ trung bình 0,355 / 0,615 / 0,751 so với 0,335 / 0,562 / 0,675 của mô hình đã thấy các ô này. Nghĩa là ở vùng đất liền, sai số chỉ tăng nhẹ.

**18. Vì sao Côn Đảo kém?**

Côn Đảo là đảo cách đất liền khoảng 180 km. Nhiệt độ trên biển biến đổi rất ít trong ngày nên persistence đã rất mạnh: ngay mô hình đầy đủ cũng thua persistence về MAE ở 1 và 3 giờ. Khi bị holdout, MAE 6 giờ là 1,56°C so với 0,52°C của persistence, vì trong dữ liệu huấn luyện không còn ô đảo xa bờ nào để mô hình học cách cư xử đó. Kết luận: mô hình không tổng quát tốt sang một đảo chưa thấy. App không giấu điều này: tại Côn Đảo, trường `evaluation` có `beats_baselines = false` và app hiện "Tại ô lưới này, AI chưa vượt mô hình cơ sở".

**19. Khoảng cách tới biển ước lượng tay có giới hạn gì?**

Nguồn đường bờ biển tự động không có sẵn lúc huấn luyện, nên nhóm vẽ tay một đường gấp khúc (Cần Giờ – Vũng Tàu – Bình Châu và một vòng quanh Côn Đảo) và tính khoảng cách haversine tới điểm gần nhất. Sai số cỡ vài km, không tính sông lớn, cửa sông hay đảo nhỏ khác. Ảnh hưởng hiện không lớn vì đặc trưng này chỉ chiếm khoảng 1% gain của mô hình nhiệt độ 6 giờ, nhưng nếu lấy đường bờ biển chuẩn (ví dụ từ OSM) thì cần huấn luyện lại vì giá trị đặc trưng sẽ thay đổi.

## D. Ứng dụng và phạm vi

**20. Đề bài có 11 nhóm chức năng, nhóm đã làm được bao nhiêu?**

Đối chiếu 42 mục con của đề bài với code (18/10/2026): 40 đã xong, 2 một phần, không còn mục chưa làm. Hai mục một phần: radar/vệ tinh (Open-Meteo không có radar, thay bằng khung dự báo theo giờ); widget chỉ có trên Android, chưa có đồng hồ thông minh.

**21. Cảnh báo trên bản đồ có đáng tin không?**

Đó là ngưỡng đơn giản trên dữ liệu mô hình: ô có mã thời tiết dông hoặc tổng mưa ≥ 10 mm trong 3 giờ tới. Không phải cảnh báo chính thức. Cảnh báo chính thức xem tại Đài KTTV khu vực Nam Bộ.

**22. Ứng dụng đã chạy trên điện thoại thật chưa? Có dùng được cho an toàn không?**

Android và web chạy được. iOS mới được kiểm chứng bằng build CI (IPA build thành công trên GitHub Actions), chưa có nhật ký chạy trên iPhone thật; chế độ chuyến đi chưa được thử trên đường thật. Kiểm thử tự động chạy ngày 18/10/2026: backend 196 passed, Flutter 457 passed và 4 skipped. Dự báo AI là thử nghiệm, không dùng cho mục đích an toàn.

## E. Cảnh báo, thói quen và bản đồ

**23. Vì sao cảnh báo chạy trên máy thay vì trên server?**

Mỗi người có ngưỡng riêng (ví dụ mưa ≥ 70% hay ≥ 50%), giờ yên lặng riêng và danh sách địa điểm riêng. Chạy luật trên máy thì không phải gửi các cài đặt và địa điểm đó lên server, không cần tài khoản hay hệ thống push. Luật nằm trong `lib/models/weather_alerts.dart`, viết bằng Dart thuần và không gọi mạng nên test được độc lập. Đổi lại, việc kiểm tra khi app ở nền phụ thuộc vào `workmanager`: khoảng mỗi giờ và hệ điều hành có thể giãn ra, nên cảnh báo có thể đến muộn.

**24. Chống trùng thông báo thế nào?**

Các giờ liên tiếp cùng loại được gộp thành một cảnh báo. Nếu đã có thông báo cùng loại, cùng địa điểm, khung giờ giao nhau thì không gửi lại; chỉ gửi "Cập nhật:" khi mức độ tăng (Lưu ý → Cảnh báo → Nguy hiểm). Mặc định chỉ gửi từ mức Cảnh báo. Trong giờ yên lặng (mặc định 22:00–06:00) chỉ mức Nguy hiểm được gửi. Bản lưu của app đang mở và của tác vụ nền được gộp theo khoá loại + địa điểm + giờ bắt đầu.

**25. Vì sao bản đồ không có radar?**

Open-Meteo, nguồn dữ liệu duy nhất của đồ án, không cung cấp ảnh radar. Thay vào đó, `/weather/map?offset_hours=0..72` trả các khung dự báo theo giờ từ lần dự báo mới nhất, kèm `source` và `valid_time` để ghi rõ đó là dự báo chứ không phải quan trắc. App có thanh thời gian 0–72 giờ với nút phát và lớp gió.

**26. Chế độ xem lại tránh "nhìn trước đáp án" thế nào?**

Mọi endpoint nhận `at` chỉ dùng dữ liệu đến `at`. Riêng bản đồ, xem lại chỉ cho `offset_hours = 0`, giá trị khác trả 400, vì khung tương lai cần dữ liệu phát hành sau `at`. Phần mưa 3 giờ tới không lấy dự báo Open-Meteo (có thể phát hành sau `at`) mà lấy dự báo AI v3 phát hành đúng tại `at` (`outlook_source = "ai"`). Ở chế độ này, app cũng không gửi thông báo và không ghi lịch sử cảnh báo.

**27. Dữ liệu thói quen có rời khỏi máy không?**

Không. Học thói quen mặc định tắt và chỉ chạy khi người dùng bật. App chỉ đếm số lần mở app và số lần bấm "Đã làm" theo giờ trong ngày (0–23), không ghi vị trí, lưu trong bộ nhớ của app trên máy và không gửi lên server. Tắt thì app ngừng ghi; nút Xoá đưa dữ liệu về 0. Khung giờ được cộng điểm nhờ thói quen luôn ghi rõ "Hợp giờ quen".

## F. Chức năng mới, bảo mật và nền tảng

**28. Vì sao app không gọi thẳng OSRM mà đi qua backend?**

- App chỉ cần biết một địa chỉ máy chủ; đổi nhà cung cấp tuyến đường không phải phát hành lại app.
- Backend ghép tuyến với thời tiết: lấy mẫu khoảng mỗi 2 km, tính giờ đến dự kiến, tìm ô lưới và lấy thời tiết đúng giờ đó từ dữ liệu của chính backend. Làm trên máy thì phải tải dữ liệu của nhiều ô.
- Tôn trọng giới hạn của máy chủ công cộng: backend gom yêu cầu, tối đa 1 yêu cầu/giây, có cache 256 tuyến và User-Agent riêng, và đếm số lần gọi để hiện ở `/admin/monitor`.
- Chọn đúng máy chủ theo phương tiện: lái xe dùng `router.project-osrm.org`; xe đạp và đi bộ dùng `routing.openstreetmap.de`, vì máy chủ demo luôn tính đường cho ô tô.

Hạn chế: máy chủ OSRM công cộng không cam kết hoạt động liên tục. Khi nó lỗi, chỉ chế độ có tuyến bị ảnh hưởng. Tọa độ điểm đi/đến vẫn được chuyển tới máy chủ OSRM.

**29. Mật khẩu và token được bảo vệ thế nào?**

- Mật khẩu: bcrypt 12 vòng trên base64(sha256(mật khẩu)). Bước sha256 tránh việc bcrypt cắt mật khẩu dài quá 72 byte. Tối đa 5 lần đăng nhập sai mỗi email trong 15 phút. Thông báo lỗi không cho biết email có tồn tại hay không, và email không tồn tại vẫn chạy một lần bcrypt để thời gian phản hồi như nhau.
- Token: chuỗi ngẫu nhiên 32 byte, gửi qua header `Authorization: Bearer`. Máy chủ **chỉ lưu sha256 của token**, nên lộ cơ sở dữ liệu cũng không dùng lại được token. Token hết hạn sau 30 ngày; đăng xuất thì xoá ngay.
- Trên máy: iOS lưu token trong Keychain, Android trong Keystore. **Web lưu trong localStorage**: nếu trang bị chèn mã độc (XSS) thì token có thể bị đọc. Đây là rủi ro đã biết; vì không dùng cookie nên không có lỗ hổng CSRF.

**30. Hai thiết bị cùng sửa dữ liệu thì đồng bộ thế nào?**

Mỗi tài khoản có một tài liệu JSON kèm số `version`. Khi lưu, app gửi `base_version` là phiên bản nó đã sửa từ đó. Nếu thiết bị khác đã lưu trước, máy chủ trả **409** kèm bản hiện tại. App gộp hai bản: địa điểm và lịch hoạt động gộp theo id (lấy hợp hai bên, bản sửa mới hơn thắng), cài đặt lấy bản có `updated_at` mới hơn, rồi gửi lại một lần. Khi xoá một địa điểm, app ghi một **tombstone** (id + thời điểm, giữ 30 ngày), để bản gộp hoặc thiết bị khác không làm địa điểm đó xuất hiện lại. Mất mạng thì app giữ thay đổi và gửi lại sau.

**31. Khoảng nhiệt độ trong app có nghĩa gì, và nó có phủ đúng 90% không?**

Đó là khoảng mức tin cậy 90%: nhiệt độ thực (theo dữ liệu Open-Meteo) được kỳ vọng rơi vào khoảng này trong khoảng 90% số lần. Trên test (từ 01/01/2025), độ phủ trung bình theo ô là **91,1 / 90,2 / 90,4%** ở tầm 1 / 3 / 6 giờ, ô thấp nhất 88,3 / 87,4 / 87,6%. Khoảng cũ p10–p90 (mục tiêu 80%) chỉ phủ 77,2 / 75,5 / 74,9%, vì độ nới conformal được chọn trên validation chỉ có nửa mùa mưa.

Cách làm mới: hai mô hình LightGBM phân vị q05/q95, rồi hiệu chỉnh bằng conformal (CQR, α = 0,1) với độ nới riêng cho từng nhóm tầm × vùng (đất liền / ven biển / đảo) × tháng, tính trên **cả năm 2024** (đủ mùa khô và mùa mưa). Mô hình dự báo điểm v3 không đổi.

Đánh đổi là khoảng rộng hơn: trung bình 1,48 / 2,50 / 3,03 °C, so với 0,93 / 1,63 / 1,97 °C của khoảng cũ. Vẫn còn chỗ yếu: tháng 7–8 và tháng 1 ở tầm 3 và 6 giờ chỉ 84–87%, ngày có mưa 88,8–90%. Với ô chưa thấy lúc huấn luyện (spatial holdout 31 ô), độ phủ trung bình 88,8 / 87,7 / 87,6%; riêng Côn Đảo khi bị giữ lại chỉ 75,9 / 67,3 / 59,6%, bỏ Côn Đảo thì ô thấp nhất vẫn ≥ 85,7%. 90% là bảo đảm trung bình, không phải cho từng giờ; app ghi "khoảng 90%" kèm độ phủ kiểm chứng của ô, và câu ghi chú của API nói rõ "Đây là mức bất định, không phải điểm độ chính xác".

**32. Làm sao đảm bảo 90% mà không gian lận trên tập test?**

- **Ba khoảng thời gian tách rời, đệm 7 ngày:** mô hình phân vị học trên dữ liệu đến 24/12/2023; độ nới tính trên năm 2024; test từ 01/01/2025. Mỗi mẫu dùng 6 giờ tới làm nhãn, đệm 7 ngày đảm bảo nhãn của phần trước không chồng lên phần sau.
- **Chọn cấu hình không nhìn test:** cách nhóm, kiểu độ nới và mức hiệu chỉnh được chọn bằng backtest lùi đúng một năm (train ≤ 2022, calibration 2023, kiểm tra 2024). Tiêu chí đặt trước: hẹp nhất trong các cấu hình có độ phủ trung bình ≥ 90% và mọi ô ≥ 85% ở cả 3 tầm. Kết quả là nhóm vùng × tháng với mức hiệu chỉnh 0,93 (ở backtest, mọi cấu hình mức 0,90–0,92 đều có ô dưới 85%). Test chỉ dùng để báo cáo kết quả, không quay lại chỉnh.
- **Không dùng dự báo điểm khi hiệu chỉnh:** mô hình điểm v3 đã học trên nửa đầu 2024, nên độ nới không dựa vào nó; dự báo điểm chỉ dùng để nới khoảng cho chứa chính nó. Bỏ bước này thì độ phủ trên test gần như không đổi.
- **Kiểm tra thêm trên vùng chưa thấy:** spatial holdout 31 ô (số liệu ở câu 31), báo cả kết quả xấu ở Côn Đảo.

Toàn bộ nằm trong `backend/scripts/train_global_v3_interval.py`; kết quả backtest ở `backend/models/v3/interval_backtest_grid.csv`, kết quả test ở khoá `interval` của `extension_v3.json`.

**33. Quy tắc "chỉ bật mục tiêu AI khi thắng mô hình cơ sở" cụ thể là gì?**

Đề bài yêu cầu chỉ mở rộng dự báo lượng mưa, độ ẩm, gió **sau khi kiểm chứng chất lượng**. Với mỗi mục tiêu mới, một ô được tính là thắng khi mô hình tốt hơn **cả persistence lẫn climatology ở cả 3 tầm** 1 / 3 / 6 giờ trên test (độ ẩm, gió, gió giật dùng MAE; lượng mưa dùng RMSE). Mục tiêu chỉ được API trả về khi thắng ở **≥ 80% số ô**. Kết quả: độ ẩm 66/67, tốc độ gió 66/67 (ô thua là Côn Đảo), gió giật 67/67, lượng mưa 67/67, nên cả bốn được bật. Mục tiêu không qua cổng vẫn được đánh giá và ghi lại nhưng không trả về. Hạn chế: chưa có spatial holdout cho các mục tiêu này. App hiển thị các mục tiêu đã bật trên thẻ AI ở trang chủ.

**34. Nhóm không có máy Mac, làm sao cài app lên iPhone?**

GitHub Actions có runner macOS. Workflow `.github/workflows/ios-ipa.yml` chạy `flutter build ios --release --no-codesign`, đóng gói file IPA chưa ký và đưa lên làm artifact. Người dùng tải IPA, ký bằng Apple ID trong 3uTools rồi cài, sau đó tin cậy nhà phát triển trong Cài đặt của iPhone (iOS 16 trở lên phải bật Chế độ nhà phát triển). Lần build gần nhất (17/10/2026) thành công. Với Apple ID miễn phí, app hết hạn sau 7 ngày, không có push từ server, không có widget iOS. Địa chỉ máy chủ đổi được trong app (Cài đặt → Máy chủ dữ liệu). Bản iOS mới được kiểm chứng bằng build CI, chưa có nhật ký chạy trên iPhone thật.
