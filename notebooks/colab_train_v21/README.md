# Huấn luyện long-range v2.1 trên Google Colab

Laptop chỉ làm hai việc nhẹ: **xuất dữ liệu** (chỉ đọc DB) và **kiểm tra artifact** khi tải về.
Phần huấn luyện nặng chạy trên Colab bằng notebook `train_long_range_v21_colab.ipynb`.
Không script nào tự gửi dữ liệu lên mạng. Bạn tự tải thư mục lên Google Drive của mình.

## 0. Chuẩn bị trên laptop (một lần)

Mở terminal tại `D:\wether_app\sky_weather_app\backend` và chạy:

```bat
python scripts\export_colab_data.py --out D:\wether_app\colab_upload
```

- Lệnh này mở `data\history\cells_history.db` ở chế độ **chỉ đọc** (`?mode=ro`, `PRAGMA query_only`)
  và không ghi gì vào DB.
- Kết quả nằm ngoài thư mục dự án, tại `D:\wether_app\colab_upload\`:
  - `data\` gồm `cells.json`, `manifest.json` và 67 tệp `hourly_<ô>.npz` (khoảng 56 MB).
  - `code.zip` và `code.zip.sha256`: code backend cần cho việc train, cùng `models/v3`, `models/long_range`
    và `models/long_range_v2` để so sánh và blend.
  - `train_long_range_v21_colab.ipynb`, `README.md`, `requirements-colab.txt`.
- Nếu `D:\wether_app\colab_upload\data` đã có dữ liệu, script sẽ từ chối ghi đè. Muốn xuất lại thì xoá hoặc
  đổi tên thư mục cũ trước.

## 1. Tải lên Google Drive

1. Mở <https://drive.google.com>, vào **My Drive**.
2. Kéo thả cả thư mục `D:\wether_app\colab_upload` vào My Drive.
3. Đổi tên thư mục vừa tải lên thành **`sky_weather_colab`**. Đường dẫn trên Drive phải là
   `MyDrive/sky_weather_colab/data/manifest.json` và `MyDrive/sky_weather_colab/code.zip`.
4. Chờ Drive tải lên xong (khoảng 110 MB: `data` ≈ 57 MB, `code.zip` ≈ 58 MB) rồi mới chạy notebook.

## 2. Chạy notebook

1. Trên Drive, nhấp đúp `sky_weather_colab/train_long_range_v21_colab.ipynb` và chọn **Open with → Google Colaboratory**.
2. Chọn **Runtime → Change runtime type**. Cần **Python ≥ 3.12** (numpy 2.5.3 và scipy 1.18.1 đã ghim yêu cầu
   3.12; ô 1 sẽ dừng nếu runtime cũ hơn, khi đó chọn phiên bản runtime mới nhất). CPU là đủ vì LightGBM không cần GPU. Nếu có tuỳ chọn **High-RAM**
   thì nên bật, vì cần khoảng 12 GB RAM.
3. Chọn **Runtime → Run all**. Colab sẽ hỏi quyền truy cập Drive, bạn đồng ý.
4. Ô 3 cài đúng phiên bản thư viện rồi **tự khởi động lại runtime**. Khi đó, bấm vào ô 4 rồi chọn
   **Runtime → Run after**.
   - Nếu `pip` báo không có phiên bản phù hợp với Python của Colab, notebook sẽ dừng. Đừng tự đổi phiên bản
     cho qua. Hãy sửa `requirements-colab.txt` có chủ đích; phiên bản mới sẽ được ghi vào `metadata.json`,
     và bước kiểm tra trên laptop sẽ cảnh báo, hoặc báo lỗi nếu LightGBM lệch major.minor.
5. Các bước còn lại chạy theo thứ tự:

| Ô | Bước | Thời gian ước tính (2 vCPU) |
|---|---|---|
| 6 | Smoke test toàn chuỗi (dev → final → spatial → test → nén) trên 3 ô lưới, ledger riêng | 5–10 phút |
| 7 | `dev`: chọn mode và năm bắt đầu train trên VAL_FIT | 2–3 giờ |
| 8 | `final`: train boosters, sau đó dùng VAL_CAL để fit taper, blend V3, hiệu chỉnh mưa và khoảng p10/p90 | khoảng 1,5 giờ (nếu chọn 2017: 2,5–3 giờ) |
| 9 | `spatial`: 6 fold bỏ khối ô | khoảng 1 giờ |
| 10 | `test`: chấm TEST **đúng một lần** | 15–30 phút |
| 12 | Nén artifact và tải về | 1 phút |

**Nếu Colab bị ngắt kết nối:** mở lại notebook và chạy lại từ ô 1. Bước nào đã có kết quả trên Drive
(`runs/dev/dev_selection.json`, `runs/long_range_v21/MANIFEST.sha256`, các fold trong `runs/spatial/`) sẽ được bỏ qua.
Ô 8 chép artifact vào `runs/long_range_v21.partial` rồi mới đổi tên, và khi resume thì kiểm tra lại sha256 theo
`MANIFEST.sha256`. Nếu ô 8 báo thư mục `runs/long_range_v21` dở dang hoặc không khớp MANIFEST, hãy đổi tên thư mục đó
(và xoá `runs/long_range_v21.partial` nếu có) rồi chạy lại ô 8. Việc này chỉ được làm **trước** khi chấm test.

### Sự cố khi chấm test

Ngay khi bắt đầu chấm, trainer ghi mục `started` vào ledger `MyDrive/sky_weather_colab/ledger/test_ledger.jsonl`
(trước khi đọc bất kỳ nhãn test nào), và ghi mục `completed` khi xong. Từ lúc có `started`, cửa sổ test coi như
**đã dùng**: chạy lại `test`, chạy lại `final` (kể cả với thư mục `--out` khác) đều bị từ chối. Nếu phiên bị ngắt
giữa lúc chấm (ô 10 báo "đã BẮT ĐẦU nhưng chưa xong"), **không** tìm cách chấm lại. Hãy báo cho team leader;
kết quả được ghi nhận là "chấm test bị gián đoạn", và verify trên laptop sẽ báo đúng lỗi đó.

## 3. Tải artifact về và đặt vào backend

Ô 12 tải về `long_range_v21_<phiên bản>.zip` và `long_range_v21_<phiên bản>.zip.sha256`. Hai tệp này cũng được lưu ở thư mục gốc
`sky_weather_colab` trên Drive.

Trên laptop, mở PowerShell tại thư mục chứa tệp zip:

```powershell
Get-FileHash .\long_range_v21_<phiên bản>.zip -Algorithm SHA256   # so với nội dung tệp .sha256
```

Giải nén vào **`D:\wether_app\sky_weather_app\backend\models\long_range_v21\`**. Thư mục này phải chưa tồn tại;
không ghi đè `models\long_range_v2`:

```powershell
Expand-Archive .\long_range_v21_<phiên bản>.zip -DestinationPath D:\wether_app\sky_weather_app\backend\models\long_range_v21
```

## 4. Kiểm tra trên laptop

Tại `D:\wether_app\sky_weather_app\backend`:

```bat
python scripts\train_long_range_v21.py --verify-artifacts models\long_range_v21
python -m pytest tests -q
python -m ruff check --config ruff.toml .
```

Lệnh verify kiểm tra những điểm sau:
- sha256 của mọi tệp khớp `MANIFEST.sha256`; `model_version` giống nhau ở mọi tệp JSON;
- ledger có chuỗi hash hợp lệ và đúng một cặp `started` + `completed` cho v21 (một lần chấm test); hash của `test_spec.json` khớp `metadata.json`;
- phiên bản thư viện: lệch thì cảnh báo, lệch LightGBM major.minor thì báo lỗi;
- 24 trường hợp parity: dự báo được tính lại từ DB cục bộ (chỉ đọc), sai lệch tối đa phải ≤ 1e-4 cho mọi khoá,
  kể cả p10/p90 và xác suất mưa đã hiệu chỉnh;
- mỗi ô lưới chạy được một lần `predict` đầy đủ.

Kết quả in ra dạng JSON. `"passed": true` nghĩa là đạt. Chỉ khi verify đạt, team leader mới quyết định đổi
import trong router sang `import long_range_model_v21 as long_range_model`.

## Lưu ý trung thực

- Nhãn là dữ liệu mô hình Open-Meteo, không phải quan trắc trạm, nên kết quả chỉ là skill mô phỏng.
- Cửa sổ TEST 2025-01..2026-10 đã được v1, v2 và V3 dùng trước đây. Ledger ghi rõ việc tái sử dụng này.
- Khoảng p10–p90 nhắm tới độ phủ 80 %. Độ phủ 80 % **không** có nghĩa là độ chính xác 80 %.

## Chạy trên máy của bạn (không dùng Colab)

Từ thư mục `sky_weather_app`, nhấp đúp `Train-v21-Local.cmd`, hoặc chạy:

```
python backend/scripts/run_v21_local.py --smoke-only   # kiểm tra nhanh 3 ô lưới, khoảng 2–3 phút
python backend/scripts/run_v21_local.py                # huấn luyện đầy đủ: smoke → dev → final → spatial → test → verify
```

- Dữ liệu đọc trực tiếp từ `backend/data/history/cells_history.db` (chỉ đọc), không cần thư mục `colab_upload`.
- Kết quả từng bước nằm trong `D:\wether_app\v21_runs\`, log ở `v21_runs\train.log`. Bị tắt giữa chừng thì chạy lại lệnh, các bước đã xong sẽ được bỏ qua.
- Mặc định dùng 4 luồng và chạy ở mức ưu tiên thấp để máy vẫn dùng được. Muốn nhanh hơn: `--threads 6` hoặc `--threads 8`.
- Cần khoảng 6–10 GB RAM trống (trainer tự dừng nếu vượt 10 GiB). Nên đóng bớt Chrome và không chạy Flutter build cùng lúc.
- Chạy xong và `verify` đạt, artifact được chép vào `backend/models/long_range_v21/`. App vẫn dùng v2 cho tới khi đổi import.
- Test chỉ được chấm một lần: nếu đã chấm test trên Colab thì không chạy bước test trên máy nữa.
