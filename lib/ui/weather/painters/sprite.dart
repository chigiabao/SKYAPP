/// Anh dem (sprite) cho hinh blur tinh: ve MOT lan vao ui.Image o do phan
/// giai thap, moi khung chi drawImageRect + dich chuyen (re hon nhieu so voi
/// MaskFilter.blur moi khung).
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// So pixel anh tren 1 px logic. Hinh da blur manh nen 0.5 khong thay khac,
/// ma tiet kiem bo nho (~4-36 lan so voi do phan giai vat ly).
const double kSpriteScale = 0.5;

class Sprite {
  Sprite._(this.image, this.bounds);

  /// Ghi [draw] (toa do local, nam trong [bounds]) vao anh.
  factory Sprite.record(
    Rect bounds,
    void Function(Canvas canvas) draw, {
    double scale = kSpriteScale,
  }) {
    final int w = (bounds.width * scale).ceil().clamp(1, 4096);
    final int h = (bounds.height * scale).ceil().clamp(1, 4096);
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec)
      ..scale(scale)
      ..translate(-bounds.left, -bounds.top);
    draw(c);
    final ui.Picture pic = rec.endRecording();
    final ui.Image img = pic.toImageSync(w, h);
    pic.dispose();
    return Sprite._(
      img,
      Rect.fromLTWH(bounds.left, bounds.top, w / scale, h / scale),
    );
  }

  final ui.Image image;

  /// Vung (toa do local) ma anh phu.
  final Rect bounds;

  static final Paint _default = Paint()..filterQuality = FilterQuality.low;

  /// Ve sprite voi goc local tai [origin]; alpha cua [paint] nhan vao anh.
  void paint(Canvas canvas, Offset origin, [Paint? paint]) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      bounds.shift(origin),
      paint ?? _default,
    );
  }

  void dispose() => image.dispose();
}
