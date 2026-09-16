# Apple Feedback 草稿 — macOS 27: SwiftUI (RenderBox) transient multi-GB glyph-bitmap spikes during drag sessions

> 提交渠道：https://feedbackassistant.apple.com （macOS，类别 Performance / Graphics）
> 附件建议：为提升可信度，提交前可以重新抓一次 malloc_history/vmmap peak 证据（此前的快照在收尾清理中已删除。需要我重建一次证据（MallocStackLogging + 自动抓取器 + 一次拖拽）再附文件；或者先用下面的文字版提交，Apple 若索数据再补）。
> 同类公开案例引用：Ghostty #11827（128GB peak）/ Warp #8205（78GB）/ Apple 社区 News 386GB —— 报告里点名这几条有助于 Apple 归档同类。

---

**Title:** Transient multi-GB physical footprint spikes (CGGlyphBuilderLockBitmaps calloc slabs) in SwiftUI apps when a full-screen-ish SwiftUI panel is rebuilt during an active drag session

**Platform:** macOS 27.0 (26A428) / Xcode 26.x / Apple Silicon (M-series)

**Affected app:** SwiftUI notch app (Atoll, open-source fork of boring.notch), but same disease is observed in many SwiftUI/AppKit apps (see public reports: Ghostty #11827, Warp #8205, News — system apps included).

**Summary (3–5 sentences):**
During an in-progress drop from Finder onto a compact SwiftUI HUD (an auto-opening notch panel), the app's `phys_footprint_peak` jumps to 3.3 GB whileUIKit/normal usage stays ~150 MB. Every live allocation is a CG glyph bitmap slab calloc'd by RenderBox (SwiftUI's private display-list engine) while composing the panel's display list across two CA commits, with zero app-level frames in the stack. The spike fully self-releases in less than a minute — it is not a leak — but it is several GB of transient pressure caused by one UI event, and occurs regardless of the dragged file's content type or whether the expansion is animated. Systemic instruments (malloc_history, vmmap) attribute the memory to `CGGlyphBuilderLockBitmaps` inside `RB::DisplayList` rendering, not to app-owned memory.

**Steps to Reproduce:**
1. Run a SwiftUI app with a compact notch-style overlay window and a `byBounds` shelf panel; the app enables `dynamicShelf`-like behavior: hovering the panel with an active drag auto-opens the (SwiftUI) HUD.
2. From Finder, start dragging a large (>1 GB) `.zip` file.
3. Hover the drag over the notch area — the HUD auto-opens (display content rebuild happens here).
4. Observe the process's "Memory" in Activity Monitor DURING the seconds following the hover/drop: it spikes to ~3.3 GB, then returns to ~150 MB within 1–3 minutes (footprint self-releases after CG caches are purged).
5. Repeat with `.bouncy` animation removed (Transaction(disablesAnimations: true)) — the spike persists, ruling out per-frame animation rebuilds.

**Expected vs Actual:**
- Expected: one display-list commit for a ~640×218 pt panel costs on the order of MBs.
- Actual: `CGGlyphBuilderLockBitmaps` accumulates ~978 × 1.25 MB + ~489 × 173 KB of malloc slabs (≈1.16 GB) live at peak, plus ~0.38 GB CoreUI static theme asset plists and ~0.23 GB SkyLight display-mode dicts; overall `Physical footprint (peak)` ≈ 3.3–3.5 GB. All file-read/binding/QL machinery in the app was removed before isolating this behavior.

**Evidence snapshot (malloc_history -allBySize -fullStacks at peak):**
```
978+489+72 calls for 1,251,840 bytes (live ≈ 1.16 GB):
  calloc → CoreGraphics CGGlyphBuilderLockBitmaps ← RB::Coverage::Glyphs::show
  ← RB::DisplayList::Layer::make_cgimage ← render_contents
  ← [RBInterpolatedDisplayListContents renderInContext:options:]
  ← SwiftUICore PlatformDrawableContent.draw(in:) ← @objc CGDrawingLayer.draw(in:)
  ← CALayer display_if_needed ← CA::Transaction::commit
  ← stepTransactionFlush / stepIdle ← UC::DriverCore::continueProcessing
2 commits per event; both contain the same glyph-slab batches.
```
Also visible on same snapshot: CoreUI `BOMStorageOpenWithSys` mmap 117 MB, SkyLight `SLDisplayCopyAllDisplayModes` dict copies (~792 × 304 KB), CoreNLP/langid model loads, font mmap — all system-side, none app intrusive.

**Notes:**
- The glyph-slab count (~1000/run) scales with panel content, not with the dragged file's byte size (7 MB image drags do not trigger it; 1+ GB zip reliably does).
- Removing the spring animation does not reduce the slab count, so this is not merely an animation-frame artifact; it appears to be the size/pathology of one (or two) commits of the SwiftUI display list containing a very large number of glyph runs, each locking a fresh 1.2 MB CG glyph bitmap slab.
- Public manifestations of the same family (system UI included, all on Tahoe-era builds): Ghostty tab creation spikes to 80–124 GB peak (github.com/ghostty-org/ghostty/discussions/11827), Warp 78 GB (github.com/warpdotdev/warp/issues/8205), News 386 GB / System Settings leaks (Apple community threads).

**Question:** is the glyph-slab allocator inside RenderBox (macOS 27) capped/compactable under memory pressure? Currently one clip of a display list can pin multiple GB of transient CG glyph caches in any SwiftUI app.
