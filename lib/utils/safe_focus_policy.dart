import 'package:flutter/widgets.dart';

/// Thu tu doc nhu [ReadingOrderTraversalPolicy], nhung khong hoi kich thuoc
/// cua nut focus chua duoc layout. Tren web, cua so co the nhan focus
/// (`didChangeViewFocus` -> `_findInitialFocus`) sau khi cay da build nhung
/// truoc frame layout dau tien; nut "Thoát" cua banner xem lai nam ngoai
/// Navigator nen bi sap xep cung route -> ban goc nem "RenderBox was not laid
/// out: RenderSemanticsAnnotations".
/// Nut chua layout xep cuoi, giu nguyen thu tu; khong bo nut nao.
class SafeReadingOrderTraversalPolicy extends ReadingOrderTraversalPolicy {
  SafeReadingOrderTraversalPolicy({super.requestFocusCallback});

  /// Nut co the tinh vi tri (render object da layout, con gan cay).
  static bool isLaidOut(FocusNode node) {
    final RenderObject? object = node.context?.findRenderObject();
    if (object == null || !object.attached) return false;
    return object is! RenderBox || object.hasSize;
  }

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final ready = <FocusNode>[];
    final pending = <FocusNode>[];
    for (final node in descendants) {
      (isLaidOut(node) ? ready : pending).add(node);
    }
    if (pending.isEmpty) return super.sortDescendants(descendants, currentNode);
    return [...super.sortDescendants(ready, currentNode), ...pending];
  }
}
