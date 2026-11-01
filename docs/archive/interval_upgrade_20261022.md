# Thu nghiem hieu chinh interval ngay 22/10/2026

## Thiet ke khoa truoc khi danh gia

Chi audit va de xuat offset; khong promote, khong retrain booster, khong sua
model dang phuc vu, original candidate, ai_model.py hay cac script train.
Nguon du lieu la dau ra mo hinh/tai phan tich, khong phai quan trac tram.

- Calibration: issue >= 2025-10-01 00:00; issue + 6h <= 2026-03-24 23:00.
- Purge: tron 7 ngay 2026-03-25 den 2026-03-31.
- Evaluation: issue >= 2026-04-01 00:00; tung target <= 2026-10-18 23:00.
- Day la tai su dung hoi cuu ky test da bao cao, khong phai final test moi.
- Mot cau hinh duy nhat: CQR abs theo cell_season, muc 0.90, thu tu thong ke
  ceil((n+1)*0.90), khong noi suy; offset am duoc chan tai 0.
- Can >=720 labels va >=30 ngay target cho moi cell-season-horizon;
  thieu mau thi dung horizon pool, can >=3000 labels va >=60 ngay target.
- Giu nguyen cell roster, feature order, 9 booster nhiet do va serving policy.
  Inclusion cua point forecast sau fallback dung chung code ai_model.
- So sanh baseline offset cu va offset moi tren cung labels; chi so chinh dung
  endpoints lam tron 2 so nhu API. Bao cao rieng parity unrounded toan ky cu.
- Gate: pooled va macro coverage >=90% moi horizon; moi cell >=85%; mean width
  <=115% baseline moi horizon, <=125% moi cell; >=720 labels/cell/horizon.
  Sai parity, thay doi frozen inputs hoac vuot budget thi dung, khong promote.
- Bootstrap ghep cap 1000 lan, seed 42, block issue 7 ngay, giu cac cell cung
  nhau; CI 95% de doi chieu 90%, khong phai bao dam coverage tuong lai.
- Gioi han: 2 LightGBM threads, 1.5 GiB peak process, khoang 900 giay, SQLite
  read-only trong transaction. Chi ghi aggregate, offsets, hashes; khong raw data.

Calibration chu yeu mua kho (12-3), chi co mua mua thang 10-11. Evaluation
chu yeu mua mua (5-10), thang 4 la mua kho; khong du chu ky mua de ket luan
cho ca nam. Spatial holdout khong doc lap. Du lieu gio va cac cell phu thuoc
nhau, nen finite-sample rank khong tao bao dam exchangeability thuc te.

## Tich hop sau QA

Leader quyet dinh promotion. Neu tao snapshot candidate rieng: giu hash booster
va policy, thay interval grouping/scale/offsets va split.cal, cap nhat test
provenance/evaluation theo report moi; khong ghi de original candidate.
verification_cutoff hien lay max ca test_end, nen phai giu it nhat
2026-10-18 23:00 (+07), khong ha xuong calibration cutoff 2026-03-24.
Replay issue tai/truoc cutoff van phai bi chan. trained_through cua long-range
la metadata rieng, khong sua; neu tao contract chung thi phai bao gom label
cutoff calibration va selection. Independent QA can kiem tra lai loader,
fallback, aliases, cutoff va replay truoc moi promotion.

## Ket qua

**Ket luan: reject, khong promote.** Da chay dung mot cau hinh khoa truoc;
khong tim kiem lai offset/level/grouping tren cua so danh gia nay.

Thoi gian 431.826680 giay (7.20 phut), peak process 368.222656 MiB.
9 booster inference, moi predict dung 2 LightGBM threads; khong retrain.
67 cell canonical, 201 cell-horizon; cung hang, cung label cho baseline/moi.
Moi horizon co 280998 label calibration, 175 ngay; moi cell co 4194 labels.
402 nhom cell-season du 1458..2736 labels, 61..114 ngay; 3 horizon pool.
Khong co nhom evaluation phai fallback offset, nhung branch nay da duoc test.

| Horizon | N labels | Coverage cu (%) | Coverage moi (%) | Delta (diem %) | Width cu (C) | Width moi (C) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1h | 323141 | 86.893647 | 87.078087 | +0.184440 | 1.365932 | 1.377660 |
| 3h | 323007 | 85.999065 | 86.366240 | +0.367175 | 2.324572 | 2.350574 |
| 6h | 322806 | 87.268514 | 86.026902 | -1.241613 | 2.854435 | 2.778934 |

Tong 968954 horizon-labels, khong phai 968954 quan trac doc lap.
Pooled va macro coverage bang nhau do moi cell co cung N trong moi horizon.
Hit cu/moi: 280789/281385 (1h), 277783/278969 (3h), 281708/277700 (6h).
Per-cell N lan luot 4823/4821/4818; xem interval_per_cell.csv cho tung cell.
Chi so chinh giu label o do chinh xac DB va lam tron endpoints den 0.01 C
nhu API; audit so lieu cu dung float32 label va endpoints unrounded nhu train.

Bootstrap 1000 lan, 29 block lien tiep 7 ngay, seed 42, percentile CI95:

| Horizon | CI95 coverage moi (%) | CI95 delta coverage (diem %) | CI95 delta width (C) |
| --- | --- | --- | --- |
| 1h | [86.257249, 87.954380] | [-0.008105, +0.347416] | [+0.005674, +0.016841] |
| 3h | [85.078125, 87.677071] | [+0.056628, +0.636223] | [+0.010399, +0.039037] |
| 6h | [84.400273, 87.520876] | [-1.517060, -1.006110] | [-0.089490, -0.063879] |

1h tang nhe, CI delta van chua 0; 3h tang nho voi CI delta duong; 6h hep hon
nhung coverage giam ro. Ca ba upper CI deu duoi 90%; khong du bang chung cho
claim coverage 90%, cang khong phai prediction accuracy 90%.

Gate truot o coverage, khong phai width. Coverage cell thap nhat moi la
83.951897% / 83.509645% / 82.254047%; 2 / 11 / 12 cell duoi 85%.
Moi horizon co 66/67 cell duoi 90%. Ty le width moi/cu trung binh la
1.008586 / 1.011186 / 0.973550; cell lon nhat 1.137304 / 1.177863 / 1.100926,
deu duoi tran 1.15 theo horizon va 1.25 theo cell. So cell coverage tang/giam
la 38/28 (1h, 1 hoa), 34/33 (3h), 24/43 (6h).

## Parity va bao cao cu

804 so sanh old/new voi ham serving thuc _interval_v3, sai so lon nhat 0.0.
49 file hash giu nguyen: 46 file candidate (gom 30 booster) va 3 script lien
quan. Khong sua ai_model.py, train*.py, models/v3 hay models/v3_candidate.
Tong hop per-month va per-cell khop report; 201 cell-horizon khong trung.

Audit unrounded ky cu 2025-10-01..2026-10-18, bao gom fallback hien hanh:

| Horizon | N labels | Coverage serving (%) | Width (C) | Coverage da bao cao (%) |
| --- | ---: | ---: | ---: | ---: |
| 1h | 615797 | 88.468765 | 1.320364 | 88.47 |
| 3h | 615663 | 88.095273 | 2.276932 | 88.09 |
| 6h | 615462 | 89.291134 | 2.816283 | 89.29 |

Sai khac 3h voi so artifact lam tron la +0.005273 diem %. Khong tu nhan
reproduce tung chu so cua report train: artifact chi luu offsets 4 so thap
phan, va audit nay dung offsets thuc serving; chua quy ket nguyen nhan sai
khac rat nho nay. Parity voi ham serving hien tai la chinh xac.

So sanh point raw/served tren toan ky cu chi khac 1 hit o 1h
(delta +0.000162391 diem % tren 615797 labels); 3h/6h khong doi. Do do stale
fallback khong giai thich thieu coverage 1-4 diem %.
Trong evaluation moi, 4823 rows cua Con Dao/1h dung fallback w=0.25.
Coverage o cell nay cu/moi 92.349160% / 90.628240%, width 1.276231 / 1.204093 C.
Khong loai cell fallback khoi phep so sanh.

## Audit va gioi han

SQLite WAL duoc doc trong transaction read-only, snapshot ket thuc
2026-10-18 23:00 bat ke main append cac ngay moi. Doc 619080 rows gom 48h
warmup/cell, 14 cot nguon va 79 features; khong duplicate/gap/null/token loi/
infinity. 1608 feature rows khong hop le chi la 24h warmup dau moi cell,
nam ngoai cua so calibration/test. Nhiet do 15.4..39.4 C, humidity 22..100%,
precipitation 0..25.6; ranges tung bien va cell co trong interval_data_audit.json.
Khong copy raw data vao repo, khong network, khong cai package.

Cua so evaluation la 201 ngay, khong dai dien du ca nam. Thang 4 coverage
moi 1h/3h/6h la 88.686609% / 89.085951% / 90.457377%; thang 8 la
85.215054% / 83.608169% / 81.110576%. CQR theo mua fit tren thang 10-11
khong khac phuc duoc shift sang mua mua 5-9. Chi so theo thang la diagnostic,
khong dung de chon lai model. CI chi la empirical block uncertainty tren
mot vung va mot ky, khong bao gom moi sai so nguon du lieu hay seasonal shift.

## Tai lap va kiem tra

Tu D:/wether_app/sky_weather_app, mac dinh chi in thiet ke, khong doc DB,
khong predict va khong ghi output:

~~~powershell
& 'C:/Users/ADMIN/AppData/Local/Python/pythoncore-3.14-64/python.exe' -B backend/scripts/recalibrate_intervals_v3.py
& 'C:/Users/ADMIN/AppData/Local/Python/pythoncore-3.14-64/python.exe' -B backend/scripts/recalibrate_intervals_v3.py --run
~~~

Python 3.14.8; numpy 2.5.3; pandas 3.0.6; joblib 1.6.0; LightGBM 4.7.0;
psutil 7.2.2; pytest 9.1.1. Khong doi dependencies chung.

16 tests trong test_interval_recalibration.py passed: finite quantile dung
rank, nonfinite/insufficient reject, purge/disjoint targets, cell/horizon
support, target-season keys, fallback alignment, future-feature leakage,
spreadsheet error/null, dry-run, gate va cutoff. 5 tests guard hien huu trong
test_verification_integrity.py passed; junit interval_guard_tests.xml.
Da parse AST hai file moi va kiem tra lai hashes, offsets finite/nonnegative,
counts per-month/per-cell, uniqueness va tong so hit/width so voi report.
Chua co independent QA, chua chay full backend suite, khong tao candidate
snapshot vi gate fail; leader giu quyen quyet dinh tiep theo.

Deliverables: backend/scripts/recalibrate_intervals_v3.py,
backend/tests/test_interval_recalibration.py, report nay va cac interval*
trong backend/models/evaluation/data_upgrade_20261022/. Khong sua shared
agent_handoff.md vi ngoai ownership; report nay la handoff cho leader.

Buoc tiep theo: giu offset hien hanh; independent QA cac outputs truoc khi
thiet ke thu nghiem khac. Muon claim theo mua can calibration dai dien hon
va cua so tuong lai chua tung xem/selection; khong chon lai cau hinh tren
2026-04-01..2026-10-18 sau khi da thay ket qua tren.
