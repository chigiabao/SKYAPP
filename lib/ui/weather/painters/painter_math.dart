/// Ham toan nho dung chung cho cac painter (khong cap phat bo nho).
library;

import 'dart:math' as math;

/// 2 * pi.
const double kTau = math.pi * 2;

/// Chia lay du luon duong: ket qua trong [0, m).
double wrapDouble(double v, double m) {
  if (m <= 0) return 0;
  final double r = v % m;
  return r < 0 ? r + m : r;
}

/// Gia tri ngau nhien trong [min, max).
double randRange(math.Random r, double min, double max) =>
    min + r.nextDouble() * (max - min);

/// So luong hat sau khi nhan he so chat luong, luon trong [0, max].
int scaledCount(int max, double quality) =>
    (max * quality.clamp(0.0, 1.0)).round().clamp(0, max);
