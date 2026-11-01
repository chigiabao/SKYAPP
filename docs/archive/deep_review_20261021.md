# Đánh giá chuyên sâu Sky Weather ngày 21/10/2026

## 1. Kết luận và phương pháp chấm

**Điểm kỹ thuật tổng hợp: 7,5/10 (74,9/100 trước làm tròn).** Đây là nhận định theo rubric bên dưới, không phải điểm của giảng viên, chứng nhận bảo mật hoặc phần trăm chính xác dự báo. Chưa nhận được rubric học phần hoặc dữ liệu nghiên cứu người dùng. Giả định đối tượng chính là người dùng điện thoại tại khu vực TP.HCM được app hỗ trợ, cần xem thời tiết, mưa và lập kế hoạch ra ngoài.

Sản phẩm có nền tảng tốt cho một đồ án: frontend và backend thật, model riêng, cache/replay, bản đồ, cảnh báo và kiểm thử đáng kể. Điểm bị giới hạn bởi lỗi đồng bộ/quyền riêng tư đã tái hiện, độ chặt của kiểm chứng ML và khoảng trống vận hành/thiết bị. **Chưa nên xem bản hiện tại là sẵn sàng phát hành rộng rãi.**

| Hạng mục | Trọng số | Điểm /10 | Đánh giá chính |
|---|---:|---:|---|
| Chức năng và giá trị sử dụng | 15% | 8,7 | Có luồng thời tiết, địa điểm, bản đồ, hoạt động, chuyến đi, tài khoản |
| Giao diện thị giác | 15% | 8,1 | Phân cấp nhiệt độ tốt, icon/cảnh thời tiết có chủ đích, responsive |
| UX và khả năng tiếp cận | 10% | 7,5 | Có trạng thái lỗi, nhãn điều hướng, chữ lớn; thông tin chính còn xuống sâu |
| Kiến trúc và khả năng bảo trì | 15% | 8,0 | Provider/service/model rõ; màn hình lớn và quản lý vòng đời cần cải thiện |
| Kiểm thử và kiểm soát chất lượng | 15% | 8,3 | Nhiều regression test đạt; vẫn thiếu các tình huống cạnh tranh và release gates |
| Dữ liệu, AI và bằng chứng khoa học | 15% | 6,0 | Pipeline thật; verify hồi cứu, test-selection, provenance và baseline còn hạn chế |
| Bảo mật và quyền riêng tư | 10% | 6,0 | Có bảo vệ hữu ích nhưng còn lỗi token/server, HTTP và xóa dữ liệu cạnh tranh |
| Vận hành và phát hành | 5% | 5,5 | Health không phản ánh freshness, dữ liệu local cũ, ký phát hành chưa xác minh |

Điểm chức năng phản ánh các luồng đã thấy trong source/test, không phải khẳng định hoàn thành mọi yêu cầu học phần. Không suy ra hiệu năng điện thoại, độ chính xác khí tượng hoặc khả năng chịu tải từ số lượng test.

## 2. Các phát hiện cần xử lý trước

Mức P2 bên dưới là lỗi trung bình, có điều kiện tái hiện cụ thể; không đồng nghĩa mọi người dùng đang bị ảnh hưởng. Vấn đề kiểm chứng ML được ưu tiên cao về tính đúng đắn khoa học, không phải lỗ hổng thực thi mã.

### F1. P2: Phiên đăng nhập không gắn với máy chủ

- Source: `lib/services/account_service.dart:296`, `:386`, `:388`; `lib/screens/settings_screen.dart:1423`; `lib/services/account_service.dart:93`.
- `AccountService` đọc URL động từ `ApiConfig`, nhưng `AuthSession` không lưu origin. Đổi máy chủ không đăng xuất hoặc yêu cầu đăng nhập lại.
- Probe dùng dữ liệu giả: khởi tạo session ở server A, đổi URL sang server B, gọi `AccountProvider.syncNow()`. Request đến B vẫn mang Bearer token của A. Không có token thật hoặc request mạng trong probe.
- Hậu quả: máy chủ mới nhận được thông tin xác thực của máy chủ cũ; tài liệu đồng bộ cũng có thể bị gửi nếu máy chủ mới chấp nhận request. Điều kiện là người dùng đổi endpoint khi còn đăng nhập, không phải tấn công tự động không cần tương tác.
- Đề xuất: gắn session và sync metadata với origin; đổi origin phải xóa phiên hoặc chuyển sang phiên riêng, hủy request/retry cũ và yêu cầu xác thực mới.
- Nghiệm thu: server B không nhận token/tài liệu của A, kể cả khi còn retry hoặc request đang chạy.

### F2. P2: Lớp đăng nhập cho phép gửi mật khẩu qua HTTP

- Source: `lib/config/api_config.dart:38`; `lib/services/account_service.dart:302`, `:386`.
- Probe xác nhận `login()` tạo request HTTP và chứa mật khẩu nguyên văn trong JSON. Đây là kiểm tra lớp service bằng MockClient; không phải khẳng định mọi OS/browser đều cho request đó đi qua.
- Rủi ro xuất hiện khi cấu hình HTTP được nền tảng cho phép. Tài liệu khuyên dùng HTTPS nhưng service không cưỡng chế.
- Đề xuất: chặn auth/sync không mã hóa trong bản phát hành; nếu cần HTTP cho phát triển, giới hạn rõ vào cấu hình debug có chủ đích.
- Nghiệm thu: auth từ chối HTTP trước khi gửi request trong chế độ phát hành; HTTPS hoạt động bình thường.

### F3. P2: Xóa tài khoản vẫn có thể để lại dữ liệu đồng bộ

- Source: `backend/routers/sync.py:105`, `:131`; `backend/routers/auth.py:251`; `backend/database.py:149`.
- PUT đã xác thực có thể chờ body; DELETE tài khoản hoàn tất trước, rồi PUT tiếp tục ghi bằng user id đã lấy. Bảng `user_data` không có foreign key ràng buộc user.
- Probe DB tạm: DELETE trả 204, PUT sau đó trả 200; cuối cùng users=0, sessions=0 nhưng user_data=1 chứa hoạt động riêng tư. Không tác động DB thật.
- Hậu quả: thao tác xóa tài khoản không bảo đảm xóa hết dữ liệu khi có request cạnh tranh. Chưa có bằng chứng rò dữ liệu sang tài khoản khác.
- Đề xuất: kiểm tra lại user/session trong transaction ghi, thêm foreign key có enforcement/cascade và migration phù hợp.
- Nghiệm thu: request chậm sau DELETE bị từ chối; không còn hàng dữ liệu mồ côi.

### F4. P2: Sync commit số không hữu hạn rồi trả lỗi 500

- Source: `backend/routers/sync.py:44`, `:110`, `:129`, `:141`.
- Payload có giá trị số `1e309` trong alert_thresholds trở thành Infinity, vượt qua validation hiện tại và được commit. Serialization response nghiêm ngặt không trả được giá trị này.
- Probe: PUT, GET dữ liệu, export và retry base_version=0 đều trả 500; bản lỗi đã nằm trong DB.
- Phạm vi đã xác minh là tài khoản gửi payload, không phải toàn bộ tài khoản.
- Đề xuất: từ chối NaN/Infinity/overflow trong toàn document, kể cả trường mở rộng; xác minh serialize trước commit và có cách sửa dữ liệu lỗi đã lưu.
- Nghiệm thu: trả 422, revision và dữ liệu cũ không thay đổi, GET/export vẫn dùng được.

### F5. P2: Login giữ khóa ghi SQLite trong lúc kiểm tra mật khẩu

- Source: `backend/routers/auth.py:115`, `:205`, `:214`.
- `purge_expired()` chạy DELETE, mở write transaction trước bcrypt. Bước tốn CPU giữ write lock lâu hơn cần thiết.
- Probe chủ động tạm dừng password check: connection khác ghi gặp database is locked. Đây là kiểm tra khóa có kiểm soát, chưa phải benchmark tải hoặc chứng minh outage ở lưu lượng cụ thể.
- Đề xuất: chạy bcrypt ngoài write transaction, transaction ghi ngắn, thêm rate limit trước xử lý tốn tài nguyên.
- Nghiệm thu: login chậm không giữ khóa chặn ghi sync; thử tải đồng thời với giới hạn chấp nhận đã định nghĩa.

### F6. P2: Giới hạn 256 KiB không chặn việc đọc body lớn vào RAM

- Source: `backend/routers/sync.py:106`.
- `await request.body()` nhận hết body rồi mới kiểm tra độ dài. Probe đọc đủ 1.310.720 byte/20 chunk trước khi trả 413.
- Rủi ro: nhiều request lớn đã xác thực tiêu tốn bộ nhớ. Chưa kiểm tra giới hạn reverse proxy thực tế nên không kết luận deployment nào cũng phơi bày toàn bộ rủi ro.
- Đề xuất: đếm byte khi đọc stream, ngắt ngay vượt ngưỡng; đặt giới hạn tương ứng tại ingress.
- Nghiệm thu: ngừng tiêu thụ stream gần ngưỡng cho phép, không phụ thuộc Content-Length hợp lệ.

### F7. P2: Health báo khỏe khi dữ liệu toàn vùng đã cũ

- Source: `backend/main.py:164`.
- Tại khoảng 17:49 ngày 21/10/2026, UTC+7, backend local trả healthy nhưng tuổi dữ liệu 41,8 giờ, fresh=0/68 chuỗi, timestamp mới nhất 00:00 ngày 20/10/2026. Source hiện tại cũng được probe độc lập, không chỉ dựa phiên bản server đang chạy.
- `/weather/bundle` local trả hourly=[], daily=[] và forecast_error cho biết thiếu đầu vào trong ba giờ gần nhất. Không suy ra một server công khai nào khác cũng đang lỗi.
- Hậu quả: giám sát chỉ nhìn status có thể bỏ sót việc chức năng dự báo không sẵn sàng.
- Điểm tốt: app/backend không bịa dự báo để che việc thiếu dữ liệu.
- Đề xuất: tách liveness/readiness, readiness xét tuổi dữ liệu/coverage/model, cảnh báo khi ingest ngừng.
- Nghiệm thu: DB truy cập được nhưng toàn vùng cũ phải có readiness degraded và lý do cụ thể.

### F8. Ưu tiên cao: Kiểm chứng v3 không phải dự báo đã được lưu lúc phát hành

- Source: `backend/routers/weather.py:744`; `backend/ai_model.py:396`; `backend/models/v3/metadata_v3.json:341`.
- `/ai-verify` gọi lại model hiện tại trên lịch sử; không đọc forecast archive. v3 không có guard cutoff tương tự long-range cho issue trước giai đoạn train/selection/calibration.
- GET local với issue 12:00 ngày 10/06/2024 trả model `lgbm-hcmc-global-v3-20261017` và sai số so với nhãn 2024. Ngày này nằm trong giai đoạn train, nên không được diễn giải kết quả là kiểm chứng ngoài mẫu hay dự báo đã phát hành vào năm 2024.
- Với issue sau thời gian train, tính lại hồi cứu vẫn không chứng minh model/đầu vào đó đã có sẵn ở thời điểm phát hành.
- Đề xuất: tách rõ mô phỏng hồi cứu và kiểm chứng dự báo đã lưu; dùng ai_forecast_log cho kiểm chứng vận hành; guard đầy đủ cutoff và model version.
- Nghiệm thu: không thể trình bày issue trong train như out-of-sample; forecast đã lưu không đổi khi thay model hiện tại.

### F9. Đánh giá khoa học v3 còn sử dụng test để quyết định sản phẩm

- Source: `backend/scripts/train_global_v3_ext.py:274`.
- Gate bật mục tiêu mở rộng dựa trên tỷ lệ ô thắng baseline tính từ test. Đây là lựa chọn sau khi xem test, không phải bằng chứng target bị đưa trực tiếp vào feature.
- Source bổ sung: `backend/scripts/train_global_v3_interval.py:213`, `:257`, `:301`. Thí nghiệm spatial holdout của interval còn dùng point model toàn vùng ở các bước chọn/bao khoảng; chưa tách sạch toàn pipeline khỏi vùng giữ lại.
- Đề xuất: selection/gating/calibration chỉ dùng validation; giữ final test độc lập; spatial holdout loại vùng khỏi mọi bước fit/tune liên quan. Không phủ định temporal point-model test chỉ vì finding spatial interval này.
- Nghiệm thu: mọi quyết định sản phẩm được đóng băng trước final test và có artifact/provenance tái lập.

### F10. P2: Nhãn MAE dễ bị hiểu nhầm thành khoảng sai số

- Source: `lib/widgets/ai_forecast_card.dart:318`.
- UI viết ±MAE. MAE là sai số tuyệt đối trung bình, không phải biên bảo đảm chứa một dự báo cụ thể.
- Đề xuất: ghi rõ MAE kiểm chứng và giai đoạn/ô lưới; khoảng dự báo hiển thị riêng với mức bao phủ và giới hạn.
- Nghiệm thu: không dùng ký hiệu cộng/trừ để diễn đạt MAE như prediction interval.

## 3. AI: kết quả tốt ở đâu, chưa chứng minh điều gì

Hai luồng khác nhau: long-range phục vụ dự báo live tương lai đến 168 giờ; v3 phục vụ 1/3/6 giờ và kiểm chứng ngắn hạn. Không dùng ưu điểm của guard luồng này để suy ra luồng kia đã được bảo vệ.

Long-range có 67 ô, 45.024 mẫu train, 11.256 validation và 11.256 test; mỗi horizon có 67 mẫu test theo cách sampling hiện tại. Period test 01/01/2025-16/10/2026. Split giữ issue và issue+168h cùng tập, có khoảng cách 168 giờ; đây là điểm cộng kỹ thuật. Chưa tái tạo training trong lượt review.

| Chỉ số test overall | AI | Persistence | Climatology |
|---|---:|---:|---:|
| MAE nhiệt độ, độ C | 0,9418 | 2,9331 | 0,9941 |
| MAE độ ẩm, điểm % | 5,7469 | 14,2408 | 6,0827 |
| RMSE lượng mưa, mm/giờ | 0,9224 | 1,4210 | 0,9304 |
| MAE gió, km/h | 3,2065 | 4,5869 | 3,3081 |
| MAE mây, điểm % | 21,5011 | 27,0518 | 24,8836 |
| Brier sự kiện mưa giờ | 0,129114 | 0,272033 | 0,130392 |

Nguồn: các nhánh test trong `backend/models/long_range/evaluation.json`; split/limitations ở `metadata.json:959`. Chỉ số thấp hơn tốt hơn; không chuyển thành phần trăm chính xác.

- Lợi thế overall so climatology có nhưng nhỏ ở mưa: khoảng 0,87% RMSE và 0,98% Brier. Chưa có khoảng tin cậy cho chênh lệch để khẳng định lợi thế bền vững.
- Ngày 7: MAE gió 3,2723 kém climatology 3,2267; Brier 0,126045 kém 0,124295. Không thể nói AI vượt baseline ở mọi ngày/chỉ số.
- Tại horizon 1h, cả sáu mục tiêu long-range thua persistence theo metric chính trong artifact; cần baseline ngắn hạn phù hợp trước khi chọn cách phục vụ.
- Nhãn là đầu ra mô hình thời tiết lịch sử, không phải quan trắc trạm. Thiếu issue-vintage/availability nên chưa chứng minh skill dự báo vận hành hoặc vượt NWP cùng thời điểm.
- Mưa long-range chưa hiệu chuẩn; chưa có prediction interval. Daily rain probability null là lựa chọn trung thực hơn tạo phần trăm từ max xác suất giờ. UV/AQI/gió giật tương lai chưa được hỗ trợ đầy đủ.
- Baseline cần bổ sung median cho MAE, persistence chu kỳ 24 giờ và NWP cùng vintage. F1 v3 cũng cần so ngưỡng công bằng giữa model và baseline.
- Coverage nominal 90% của interval v3 không phải accuracy 90%. Coverage không đồng đều: diagnostic có tháng 7 tại 6h khoảng 84,05%; thí nghiệm spatial Côn Đảo tại 6h khoảng 59,60%. Giới hạn spatial pipeline ở F9 vẫn áp dụng.

## 4. Đánh giá giao diện và UX

Ảnh mới trong `build/deep-review-ui/` được chụp từ bản web local đã tồn tại trước lượt review. Source hiện tại được analyze/test riêng; không build lại web trong lượt này nên không coi ảnh là chứng minh đồng nhất tuyệt đối với mọi file dirty. Nội dung có dữ liệu dùng replay 18:00 ngày 19/10/2026, không phải thời tiết live ngày review. Browser dùng reduced motion, dark theme.

### Hiện trạng

- Home có phân cấp rõ: địa điểm, nhiệt độ, tình trạng, gợi ý hành động rồi mưa. Điều hướng bốn mục có nhãn và trạng thái chọn; desktop chuyển sang rail. Nguồn và replay có phân biệt.
- Ảnh 320x667: phần đầu chiếm gần hết viewport, chỉ thấy tóm tắt mưa trước thanh điều hướng; dự báo giờ/ngày cần cuộn thêm. Đây là điểm giảm hiệu quả quét thông tin, không phải lỗi overflow đã xác nhận.
- Desktop có khoảng trống lớn bên phải phần nhiệt độ; có thể đưa cảnh báo/độ mới/tóm tắt ngày vào bố cục hai cột thay vì kéo dài vùng đầu.
- Home dùng nền cảnh/kinh nhưng Settings nền đen và nhóm phẳng. Có thể giữ khác biệt theo ngữ cảnh, song nên đồng nhất typography, icon, nhịp khoảng cách và trạng thái nút.
- Cold offline có thông báo lỗi, thử lại và đường đến máy chủ dữ liệu; không phải ngõ cụt. Chưa chứng minh offline đã có cache qua browser trong lượt này.
- Nhãn Thực tế vẫn có thể gây hiểu lầm nếu người dùng không mở chú thích. Đề xuất ưu tiên Dữ liệu mô hình/Phân tích ở nơi còn đủ chỗ, vì không phải số đo trạm.

### Nguyên tắc đề xuất, không phải thiết kế đã triển khai

- Giữ Inter, token nhịp 4/8 và target 48dp đang có. Không cần thay framework hay thiết kế lại toàn bộ.
- Duy trì semantic colors riêng cho cảnh báo, dữ liệu cũ, nguồn và lựa chọn. Dùng nhãn/icon kèm màu, không dùng nền cảnh làm tín hiệu duy nhất.
- Giữ bề mặt ổn định dưới nội dung dày; phân cấp ít lớp, border/elevation nhẹ. Giữ radii hiện có nếu tiếp tục hệ thống glass, tránh trộn thêm kiểu card mới.
- Thang chữ đề xuất: body 15-17, nhãn phụ 12-13, giá trị điều kiện 24-34; nhiệt độ lớn chỉ cho Home. Giảm khoảng trống trước khi giảm khả năng đọc.
- Motion chỉ để phản hồi/chuyển cảnh; tiếp tục tôn trọng system/app reduced motion. Không hứa mượt hay tiết kiệm pin khi chưa đo máy thật.

### Mockup mô tả theo màn

| Màn/khu vực | Đề xuất | Nghiệm thu |
|---|---|---|
| Header Home mobile | Một hàng địa điểm + hành động; nhiệt độ/trạng thái gọn; độ mới và nguồn sát dữ liệu | 320x667 vẫn thấy điểm bắt đầu dự báo giờ trước khi cuộn dài; không cắt chữ lớn |
| Home desktop | Nhiệt độ bên trái; độ mới/cảnh báo/tóm tắt mưa bên phải; dưới là hourly/daily | Giảm vùng trống, cùng thứ tự đọc khi về mobile |
| Card mưa | Giữ timeline; phân biệt max xác suất giờ với xác suất có mưa cả ngày | Nhãn và semantics không gợi ý xác suất ngày nếu model chưa hỗ trợ |
| Điều hướng | Giữ bốn mục, trạng thái chọn và nhãn; menu công cụ phụ có tên truy cập | Mọi đường đi có Back nhất quán; không có tác vụ quan trọng chỉ bằng swipe |
| Settings/form máy chủ | Đưa phần phổ thông trước; URL ở nâng cao; thông báo đổi server cần đăng nhập lại | Bàn phím không che thao tác, lỗi sát trường, F1/F2 được bảo vệ |
| AI/kiểm chứng | Tách forecast đã lưu, mô phỏng hồi cứu và đánh giá tập test | Người dùng phân biệt ba khái niệm, không thấy ±MAE như khoảng dự báo |
| Trip/Alerts | Giữ thông điệp thiếu coverage; không biến thiếu UV/gió giật/AQI thành an toàn | Không đề xuất giờ tốt nhất khi không đủ dữ liệu cho các tiêu chí |

### Accessibility: đã thấy và còn phải kiểm tra

- Đã thấy trong source/test: Semantics, tooltip, hỗ trợ chữ lớn, high contrast/reduced motion, điều hướng có nhãn, test daily semantic action và test bố cục Trip.
- Test Flutter liên quan chữ lớn/layout đạt trong suite hiện tại; không suy rộng thành mọi màn đều hỗ trợ cỡ chữ cực đại.
- Browser mới: Home/Conditions/Settings chạy trên 390x844, 320x667, 844x390, 1440x960; canvas có kích thước; không pageerror được ghi nhận. Đã xem trực tiếp các ảnh đại diện, gồm màn hẹp và offline.
- Chưa kiểm tra TalkBack/VoiceOver, focus order end-to-end, bàn phím và switch control, tương phản trên mọi nền động, safe area máy thật và cỡ chữ tối đa trên từng màn.
- Không tuyên bố đạt WCAG hoặc chứng nhận accessibility từ screenshot/unit test. Không dùng browser giả lập để chứng minh cấu hình native iOS.

## 5. Kiến trúc, hiệu năng và QA

- Provider/service/model tách vai trò khá rõ. WeatherProvider có request id/generation chống response cũ ghi đè, snapshot/prefetch giới hạn và cache-first; replay tách cache live. Đây là những quyết định tốt hơn một giao diện gọi API đơn giản.
- Backend có contract tests, xử lý model không sẵn sàng và các regression mới cho cold-start, revision sau delete và source lockout. Những lỗi cũ trong handoff không được lặp lại như lỗi chưa sửa.
- Phạm vi màn hình lớn: Settings, Map, Home, Trip chứa nhiều layout và logic. Chỉ nên tách theo ranh giới hành vi khi sửa, không refactor hàng loạt vì số dòng.
- Rủi ro cần test riêng: WeatherProvider/Home không có nhánh resume tự fetch thấy được; AppScene có timer đổi cảnh nhưng không tải lại dữ liệu. Nên kiểm tra mở lại app sau nhiều giờ và refresh định kỳ theo freshness, không kết luận lỗi thiết bị đã được tái hiện.
- Background bắt lỗi rồi trả thành công; cần quan sát chính sách retry/telemetry thật khi mạng lỗi kéo dài. Chưa stress test tác vụ nền.
- Benchmark widget background hiện chỉ kiểm tra có paint và in số liệu; không có ngưỡng frame budget production. toImage/raster của test host không phải FPS hay pin điện thoại.
- CI có Flutter analyze/test và build; chưa thấy backend pytest làm gate trong workflow đã đọc. Golden là continue-on-error; Android job tạo debug APK, iOS artifact unsigned. Không coi đây là pipeline phát hành hoàn chỉnh.

## 6. Kiểm chứng mới trong lượt này

| Kiểm tra | Kết quả và phạm vi |
|---|---|
| flutter analyze --no-pub | No issues found; 11,2 giây |
| flutter test --no-pub --exclude-tags golden --reporter expanded | 628 đạt, 4 skip, không fail; khoảng 2 phút 04 giây |
| Backend pytest | 305 đạt, 15 skip, không fail; 66,96 giây; 320 collected |
| Hai probe Flutter | 2 đạt: tái hiện forwarding token khi đổi server và HTTP login, không phải test chứng minh an toàn |
| Browser | 4 viewport + cold offline; không pageerror; Settings vào được khi offline |
| Backend probes | Tái hiện race xóa tài khoản, Infinity sau commit, khóa ghi login, body cap và health stale |
| Artifact ML | Đọc source/metadata/evaluation; không training, không tái tạo metrics từ dữ liệu thô |

Backend dùng Python thật `pythoncore-3.14-64`, INGEST_ENABLED=0, không cacheprovider và DB test tạm. 15 test cần fixture artifact huấn luyện được đánh dấu skip bằng hook trong bộ nhớ để giữ review không training; không sửa test production. **Không ghi là 320/320 đã chạy đạt.** Bốn test Flutter live bị skip; golden không chạy.

Lệnh chính: `D:\flutter\bin\flutter.bat analyze --no-pub`; `D:\flutter\bin\flutter.bat test --no-pub --exclude-tags golden --reporter expanded`; probe riêng `flutter test --no-pub build/deep_review_probe_test.dart --reporter expanded`. Backend gọi pytest.main với `tests -q -ra -p no:cacheprovider --basetemp .../tmp --junitxml .../pytest.xml` và hook skip nói trên.

Bằng chứng:

- `build/deep_review_probe_test.dart`
- `build/deep-review-ui/results.json` và các ảnh cùng thư mục
- `build/review-deep-backend-20261021-174840/pytest.log`, `pytest.xml`
- `build/review-deep-backend-20261021-174840/probe-results.log`
- `build/review-deep-backend-20261021-174840/delete-race-results.log`
- `build/review-deep-backend-20261021-174840/edge-results.log`

## 7. Thứ tự cải thiện

1. Trước phát hành: F1-F4 về phiên, kênh truyền và toàn vẹn/xóa dữ liệu. Thêm regression tái hiện fail trước sửa; giữ đồng bộ tương thích giữa phiên bản.
2. Cùng đợt ổn định backend: rút ngắn login transaction, stream body limit, readiness/freshness và giám sát ingestion. Không bật ingest thật hoặc sửa dữ liệu live chỉ để làm demo xanh.
3. Sửa thông điệp AI sớm: bỏ ±MAE, phân loại verify/replay, không trình bày issue trong train như ngoài mẫu. Các thay đổi này không cần hứa hẹn model chính xác hơn.
4. Công việc dài hơn: final test độc lập, spatial pipeline sạch, forecast archive bất biến, vintage, baseline mạnh và đối chiếu quan trắc độc lập. Phụ thuộc dữ liệu và thiết kế thí nghiệm, không chỉ sửa UI.
5. UX: thu gọn Home ở máy nhỏ, tận dụng desktop, đồng nhất Settings; đo hoàn thành tác vụ trước/sau. Sau đó kiểm tra máy thật, accessibility, hiệu năng và phát hành ký đúng.

Không sửa chức năng production, không train/ingest, không commit/push trong lượt này. Chỉ thêm báo cáo, probe chẩn đoán ở build, kết quả kiểm tra và bàn giao. Chưa xác minh tải thực, pentest, TLS/proxy triển khai, Android/iPhone thật, thông báo nền đúng giờ, FPS/pin, Xcode/signing/App Groups hoặc golden.
