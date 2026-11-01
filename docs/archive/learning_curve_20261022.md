# Learning curve du lieu cu - 22/10/2026

Da chay hoan tat thi nghiem 1/3/6 nam lich su, 10 o dai dien va ca ba horizon
1h/3h/6h. Tren cung tap test 3h, MAE giam tu 0.61639 xuong 0.58692 degC
(4.78% sai so MAE), F1 tang tu 0.51595 len 0.53218 khi tang 1 len 6 nam.
Loi ich 3 -> 6 nam nho hon 1 -> 3 nam; F1 mua 6h khong tang deu.
Day la ket qua cua thi nghiem mau, khong phai quyet dinh chon/promote model production.

## Pham vi va tai lap

- Script moi: `backend/scripts/learning_curve_v3.py`.
- Tests moi: `backend/tests/test_learning_curve_v3.py`.
- Artifacts: `backend/models/evaluation/data_upgrade_20261022/learning_curve_v3.json`,
  `learning_curve_v3.csv`, `learning_curve_v3_per_cell.csv`.
- Khong sua training helper, history DB, models/v3 hay current candidate;
  khong luu booster, khong sao chep du lieu goc, khong cai package/ket noi mang.
- Dung `train_global_v3` cho dac trung, targets, split, climatology, threshold,
  prediction, scoring va block bootstrap; dung `representative_cells` tu backtest.
- Default script chi chay 3h. Luot thuc te dung `--horizons 3 1 6`; moi cua so
  tao mot binned Dataset roi dung lai cho 6 booster, khong fit lai 3h de them 1h/6h.
- Python 3.14.8, pandas 3.0.6, NumPy 2.5.3, LightGBM 4.7.0. JSON luu version,
  SHA-256 cua 4 source file, hash du lieu tung o va hash hang danh gia.

Chay tu `D:/wether_app/sky_weather_app` (PowerShell):

```powershell
& 'C:/Users/ADMIN/AppData/Local/Python/pythoncore-3.14-64/python.exe' -u backend/scripts/learning_curve_v3.py --horizons 3 1 6 --snapshot-end '2026-10-18 23:00:00'
```

Snapshot duoc doc trong mot SQLite transaction `mode=ro`, `query_only=ON`,
`BEGIN` truoc query dau tien. Chot cutoff 18/10/2026 23:00, nen main co the
append gio moi ma khong thay doi du lieu thi nghiem. Hash se phat hien sua doi
du lieu cu trong lan tai lap; script khong giu mot ban sao DB bat bien.
Tai lap can cung du lieu truoc cutoff, source va versions trong JSON.

## Audit du lieu

Toan snapshot: **5,753,417 hang, 67 o**, timestamps goc tu 01/01/2017 00:00
den 18/10/2026 23:00. Khoang 02/01/2017 duoc mo ta truoc do phu hop voi
viec dac trung can lich su 24h, khong phai timestamp goc dau tien.
Ham chon dai dien nhan n=9 nhung tra ve **10 o** do them TSN/Con Dao va lam
tron theo vung; actual count va danh sach o duoc luu trong JSON.

Trong 10 o: **858,713 hang goc**, 858,410 hang du dac trung, 303 hang bi loai
do warm-up/du lieu thieu. Co **693 gia tri null** trong cac cot dau vao;
khong co timestamp trung, khoang gio thieu ben trong moi chuoi, numeric text
loi hay infinity. TSN bat dau muon hon 7h, nen so hang goc it hon 7.
Null, `#NUM!` va infinity khong duoc thay bang 0; reindex gio truoc tao lag va target.

Khoang gia tri tren cac o duoc chon: temperature 16.1..39.4 degC,
humidity 18..100%, precipitation 0..48.3 mm, cloud cover 0..100%,
pressure_msl 999.3..1019.5, wind_speed 0..84.2, wind_direction 0..360.
Audit JSON luu dtype, min/max/null/error cho ca 12 cot va tung o.
Du lieu la dau ra mo hinh/reanalysis Open-Meteo, khong phai quan trac tram doc lap.

## Thiet ke va ngan leakage

Seed 42, 79 features, learning rate 0.05, 63 leaves, feature/bagging fraction
0.8, bagging freq 5, min_data_in_leaf 100, deterministic + force_col_wise,
2 threads, histogram pool 64 MiB, toi da 300 rounds, early stopping 40.
Temperature objective regression/MAE; rain binary/binary_logloss.
Tat ca hyperparameters giu nguyen giua cac cua so; khong search/tune bang test.

Gio phat hanh duoc lay mau theo `(epoch_day + hour_of_day + 42) % 4 == 0`.
Lich xoay bao phu du 24 gio trong moi 4 ngay, khong chi lay gio 0/4/8/12/16/20.
Cung lich ap dung cho moi o, train va holdouts; cua so 1 nam la tap con cua
3 nam, va 3 nam la tap con cua 6 nam. Tao features/targets tren gio lien tuc
truoc khi lay mau. Features chi dung t va qua khu; toi da 24h context truoc
bat dau cua so duoc phep, khong dung targets tuong lai lam features.

| Train | Cua so issue duoc phep | Hang train lay mau | Hang climatology |
| --- | --- | ---: | ---: |
| 1 nam | 24/09/2022 00:00 -> 23/09/2023 17:00 | 21,880 | 87,540 |
| 3 nam | 24/09/2020 00:00 -> 23/09/2023 17:00 | 65,680 | 262,740 |
| 6 nam | 24/09/2017 00:00 -> 23/09/2023 17:00 | 131,440 | 525,780 |

TRAIN_END la moc **target** 23/09/2023 23:00. Bat buoc t+6h nam trong split,
giu gap 7 ngay cua helper. Sau sampling, train issue cuoi thuc te la
23/09/2023 15:00; issue dau lan luot 24/09/2022 03:00, 24/09/2020 01:00,
24/09/2017 01:00. Khong fit scaler/imputer tren val/test.

| Split | Cua so helper | Issue thuc te sau sampling | Hang |
| --- | --- | --- | ---: |
| val_es | 01/10/2023 00:00 -> 23/09/2024 23:00 | 01/10/2023 03:00 -> 23/09/2024 17:00 | 21,530 |
| val_select | 01/10/2024 00:00 -> 23/09/2025 23:00 | 01/10/2024 01:00 -> 23/09/2025 16:00 | 21,470 |
| test | tu 01/10/2025 00:00, cutoff 18/10/2026 23:00 | 01/10/2025 00:00 -> 18/10/2026 14:00 | 22,960 |

Moi split co cung hang cho tat ca cua so va horizon. Test can du targets 1/3/6h
va t+6 <= cutoff; khong dung partial targets de thay doi mau so.
Lay giao support climatology cua ca ba cua so truoc khi fit; luot nay loai
**0 hang** vi thieu common support. Moi o co 2,296 hang test.
Hash test: `43d84be74c54fb1d2bbdda43fe19744d1fc3903cff8e3fad2b8ef3bd7ecd650b`.

Climatology dung mean temperature va tan suat mua theo o/thang/gio tren
**toan bo gio train du dac trung**, truoc sampling, cua chinh cua so do.
Do do baseline duoc huong nhieu hang hon booster, khong bi lam yeu bang
sampling. Prediction duoc tra theo **thang/gio target t+h**. Mua la >0.1 mm.
Model va climatology deu giu xac suat raw, khong calibration/fallback.
Moi ben tu tune threshold F1 tren **val_es** cung grid 0.05..0.95, buoc 0.01.
val_es cung dung early stopping, nen diem val_es khong phai unseen.
val_select chi de bao cao trong thi nghiem nay; khong chon cua so/model tren do.
Test chi bao cao, khong thay hyperparameters hay nguong sau khi xem diem.

## Ket qua test

Pooled tren **22,960 issue rows / 10 o** cho moi horizon; so su kien mua
lan luot 4,215 (1h), 4,149 (3h), 4,213 (6h). MAE tinh bang degC.
BSS = 1 - Brier_model / Brier_climatology cua **cung cua so train**.

| Horizon | Nam train | MAE model | F1 model | Brier model | BSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3h | 1 | 0.616393 | 0.515951 | 0.117011 | 0.125264 |
| 3h | 3 | 0.596279 | 0.527533 | 0.112775 | 0.145233 |
| 3h | 6 | 0.586915 | 0.532177 | 0.112112 | 0.133569 |
| 1h | 1 | 0.367289 | 0.661782 | 0.087529 | 0.340454 |
| 1h | 3 | 0.350380 | 0.665025 | 0.083835 | 0.360653 |
| 1h | 6 | 0.341735 | 0.669729 | 0.082964 | 0.354987 |
| 6h | 1 | 0.736807 | 0.486733 | 0.124668 | 0.064602 |
| 6h | 3 | 0.716048 | 0.506037 | 0.120871 | 0.082499 |
| 6h | 6 | 0.708112 | 0.502006 | 0.119185 | 0.079769 |

Baseline test 3h tren cung hang:

| Baseline | Nam train | MAE | F1 | Brier | Nguong val_es |
| --- | ---: | ---: | ---: | ---: | ---: |
| Persistence | khong fit | 1.645566 | 0.442708 | 0.201873 | rain tai t >0.1 mm |
| Climatology raw | 1 | 1.066793 | 0.445697 | 0.133767 | 0.28 |
| Climatology raw | 3 | 1.114034 | 0.435909 | 0.131936 | 0.35 |
| Climatology raw | 6 | 1.074085 | 0.442721 | 0.129395 | 0.31 |

Threshold model 3h: 0.29 / 0.34 / 0.31. Moi horizon/cua so trong CSV deu
co MAE/F1/Brier persistence va climatology, sample counts va threshold rieng.

val_select 3h, cung 21,470 hang, khong dung de ra quyet dinh trong luot nay:

| Nam train | MAE model | F1 model | Brier model | BSS |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.574661 | 0.562416 | 0.109786 | 0.144888 |
| 3 | 0.558843 | 0.578740 | 0.107377 | 0.146837 |
| 6 | 0.550388 | 0.580497 | 0.107198 | 0.131094 |

JSON co percentile 95% CI tu **500 block bootstrap, block 7 ngay, seed 42**,
giu cac o cung ngay trong cung block. Test 3h MAE CI cho 1/3/6 nam:
[0.58363, 0.64607] / [0.56292, 0.62726] / [0.55316, 0.61924].
F1 CI: [0.47408, 0.55013] / [0.48075, 0.56390] / [0.48923, 0.56766].
Day la CI tung model, khong phai paired CI cho chenh lech learning curve;
khong dung overlap CI de ket luan y nghia thong ke cua chenh lech.

## Chi phi, dien giai va gioi han

Tong runtime **85.311 giay**, gom load/audit **10.348 giay**; native peak working
set **427.781 MiB**. Gioi han 720 giay / 1,024 MiB, kiem tra trong loading va
moi 10 boosting rounds. Moc runtime khong gom startup/import Python va ghi file
cuoi, nhung luot thuc te van thap hon nhieu so voi ngan sach.

| Nam train | Fit 6 booster (s) | Ca cua so va scoring (s) | Best rounds temp 3h / rain 3h |
| ---: | ---: | ---: | --- |
| 1 | 9.674 | 10.690 | 260 / 96 |
| 3 | 20.997 | 22.549 | 300 / 137 |
| 6 | 40.234 | 41.559 | 300 / 186 |

Ca ba horizon dung chung data loading va binning theo cua so; van can
18 booster rieng (3 cua so x 3 horizon x 2 targets), thay vi 6 neu chi 3h.
Khong co sweep, full-global fit, hay model duoc ghi vao candidate/serving.

Trong mau nay, them nam cu giup MAE va Brier raw cua ca ba horizon. Tai 3h,
1 -> 6 nam: MAE giam **0.029478 degC**, F1 tang **0.016225**, Brier giam
**0.004899**. Cai thien tu 3 -> 6 nam nho hon; F1 6h giam
0.506037 -> 0.502006. BSS 6 nam thap hon 3 nam vi climatology cua 6 nam cung
manh hon, nen khong so BSS giua cac cua so nhu the baseline la co dinh.

Gioi han: 10/67 o, 1/4 issue hours, mot seed va mot split thoi gian, cung
nguon Open-Meteo, chua co temporal/spatial external validation. Them nam cu
cung tang so mau, nen khong tach duoc loi ich sample size voi era diversity.
Temperature 3h va 6h cua cua so 3/6 nam cham tran 300 rounds; chua biet ket
qua khi hoi tu hon. Khong train lai de toi uu dua tren test da xem.

Buoc tiep theo cho team lead: review doc lap script/audit, sau do neu can
lap mot ke hoach validation moi (rolling origins hoac du lieu tram doc lap)
truoc khi quyet dinh train global. Ket qua nay khong tu dong thay the model,
khong la cam ket du bao ngoai doi thuc, va khong suy ra phan tram accuracy.

## Kiem tra da chay

```powershell
# Tu backend/
& 'C:/Users/ADMIN/AppData/Local/Python/pythoncore-3.14-64/python.exe' -m pytest tests/test_learning_curve_v3.py tests/test_train_eval.py -q -p no:cacheprovider --basetemp D:/wether_app/build/pytest-learning-curve-final-20261022
# Tu project root, dung binary da co san, khong cai them
& 'D:/wether_app/sky_weather_app/build/quality-tools/bin/ruff.exe' check --no-cache --config backend/ruff.toml backend/scripts/learning_curve_v3.py backend/tests/test_learning_curve_v3.py
```

**19 passed, 1.87s** (7 tests moi + 12 tests evaluation helper); Ruff all checks
passed. Tests moi kiem tra chronology/purge, sampling long nhau va du 24h,
missing/error khong thanh dry label, common support khi mot cua so thieu,
feature khong doc tuong lai, snapshot transaction khi writer append, metrics.
Assert artifacts: **27 dong aggregate**, **90 dong per-cell**, row hash/mau so
khop giua cua so, BSS dung cong thuc, tong hang per-cell dung, dung ngan sach.
Ca 4 source hashes van khop sau chay. Chua chay full backend suite hay
repeated-seed experiment; chua co review doc lap cho script moi.

Bao cao nay la handoff trong pham vi file duoc giao; khong sua handoff chung
do main so huu nhung thay doi tich hop.
