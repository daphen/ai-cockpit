#pragma once
#include <QQuickPaintedItem>
#include <QFont>
#include <QImage>
#include <QtQmlIntegration>
#include <thread>
#include <mutex>
#include <atomic>
#include <deque>

// libghostty-vt headers use struct fields named `emit`/`signals`/`slots`, which
// collide with Qt's keyword macros. Undef them just around the include.
#pragma push_macro("emit")
#pragma push_macro("signals")
#pragma push_macro("slots")
#undef emit
#undef signals
#undef slots
#include <ghostty/vt.h>
#pragma pop_macro("slots")
#pragma pop_macro("signals")
#pragma pop_macro("emit")

class QSocketNotifier;
class QKeyEvent;
class QMouseEvent;
class QFileSystemWatcher;

// Minimal terminal view: a real shell via forkpty → libghostty-vt → QPainter cells.
// Proves the render path; colors/cursor/resize are deliberately crude for the spike.
class TermView : public QQuickPaintedItem {
  Q_OBJECT
  QML_ELEMENT
public:
  explicit TermView(QQuickItem *parent = nullptr);
  ~TermView() override;
  void paint(QPainter *p) override;

  // The real device pixel ratio, published so QML can snap this item's size to whole
  // device pixels. QML's Screen.devicePixelRatio resolved to 1 here while the window was
  // actually at 1.75, which silently defeated the snapping and left every frame
  // resampling.
  Q_PROPERTY(qreal dpr READ dpr NOTIFY dprChanged)
  // Grid geometry probe (debug/IPC): what the terminal believes about its layout.
  Q_PROPERTY(QString gridInfo READ gridInfo NOTIFY dprChanged)
  // The nvim RPC socket THIS instance's nvim listens on. Per-instance, so the rail
  // never talks to a path a different Cockpit may have unlinked.
  Q_PROPERTY(QString nvimSocket READ nvimSocket CONSTANT)
  qreal dpr() const { return guiDpr_ > 0 ? guiDpr_ : 1.0; }
  QString gridInfo() const {
    return QString("cols=%1 rows=%2 cellW=%3 cellH=%4 padT=%5 padB=%6 itemH=%7 dpr=%8 slack=%9")
      .arg(cols_).arg(rows_).arg(cellW_).arg(cellH_).arg(padT_).arg(padB_)
      .arg(height()).arg(guiDpr_ > 0 ? guiDpr_ : 1.0)
      .arg(height() - rows_ * cellH_ - padT_ - padB_);
  }
  QString nvimSocket() const { return nvimSocket_; }

  // false when focus is in the rail → hide the terminal cursor.
  Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
  bool active() const { return active_.load(); }
  void setActive(bool a);

signals:
  void activeChanged();
  void dprChanged();

protected:
  // The GUI thread learns the ratio here. paint() runs on the RENDER thread, so a
  // dprChanged() emitted from there cannot reliably re-evaluate the QML binding that
  // snaps this item's size — the width silently stayed unsnapped while the height
  // updated.
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void keyPressEvent(QKeyEvent *e) override;
  void mousePressEvent(QMouseEvent *e) override;
  void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

private:
  void spawnPty();
  void hugGridRight(qreal viewW);
  void writePty(const char *data, int len);  // worker-thread only (PTY fd owner)
  void pasteText(const QString &t);
  // The worker thread owns the PTY + ghostty state and does ALL rasterization,
  // publishing finished frames back to the GUI thread; paint() only blits them.
  void workerLoop();          // blocking poll() on the PTY + wake-pipe
  QImage renderFrame();       // worker-thread: rasterize the grid into a DPR image
  void wakeWorker();          // GUI-thread: nudge the worker's poll()
  void enqueuePty(const QByteArray &bytes);  // GUI-thread: queue input for the PTY
  // Load default fg/bg/cursor + palette 0-15 from the theme generator's output
  // (kitty dark-theme.auto.conf), so the terminal matches the rest of the desktop.
  void loadThemeColors();       // read fg/bg/cursor/palette for the CURRENT theme mode
  void applyThemeColors();      // push the loaded colors into the terminal + repaint
  // Box-drawing glyphs must fill the whole cell so lines connect across the
  // 1.25× line height; draw the common ones procedurally. Returns false for
  // codepoints we don't handle (caller falls back to the font glyph).
  bool drawBoxChar(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg);
  // Block elements (U+2580..U+259F: █ ▌ ▎ ▄ shades …) must fill the full cell so
  // vertical bars (markdown quote guides) connect across the 1.25× line height.
  bool drawBlockChar(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg);
  // Powerline separators (U+E0B0..E0B7) drawn as filled vector shapes scaled to
  // the full cell — smooth + seamless, like kitty/ghostty (not the font glyph).
  bool drawPowerline(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg);
  // libghostty-vt invokes this when the terminal must reply to the PTY
  // (DSR, DA, cursor-position reports). Routes back to writePty via userdata.
  static void onWritePty(GhosttyTerminal t, void *userdata,
                         const uint8_t *data, size_t len);

  GhosttyTerminal term_ = nullptr;
  GhosttyRenderState renderState_ = nullptr;  // for the cursor's visual shape (DECSCUSR)
  int cursorShape_ = 1;          // GhosttyRenderStateCursorVisualStyle; 1 = BLOCK
  int master_ = -1;              // PTY master fd (worker-thread owner)
  pid_t child_ = -1;             // forkpty child (session leader) — killed on teardown
  QFileSystemWatcher *themeWatcher_ = nullptr;  // ~/.config/theme_mode → live light/dark flip
  QFont font_;
  QFont iconFont_;   // QsIcons, for the U+E000-U+E4FF icon range

  // Metrics are qreal and SNAPPED to whole device pixels (see applyMetrics): with
  // integer logical metrics, col*cellW*dpr lands on a half pixel at 1.75x, so
  // identical glyphs rasterized at different subpixel offsets — some stems crisp,
  // others smeared. Snapping makes every cell origin a real pixel boundary.
  qreal cellW_ = 9, cellH_ = 18, ascent_ = 14;
  // DEVICE-pixel twins, used exclusively by the worker's painter (which runs at
  // identity transform — Qt disables font hinting under any scale, so painting in
  // logical coords through a DPR transform rendered every glyph unhinted: the
  // permanent softness). Integers by construction; logical mirrors above = D/dpr.
  int cellWD_ = 9, cellHD_ = 18, ascD_ = 14;
  int padTD_ = 18, padRD_ = 16, padBD_ = 0, padLD_ = 10;
  QFont fontD_, iconFontD_;   // device-sized faces the worker rasterizes with
  qreal baseCellW_ = 9, baseCellH_ = 18, baseAscent_ = 14;   // unsnapped, from QFontMetricsF
  void applyMetrics(qreal dpr);   // snap metrics + padding for this ratio
  void centerGrid(qreal viewH, int rows);  // share the row remainder top/bottom
  void relayoutGrid();            // re-derive cols/rows from the current size + metrics
  QString nvimSocket_;
  qreal basePadT_ = 18, basePadB_ = 0;     // design padding, before remainder sharing
  void syncTextureSize(qreal dpr); // pin the backing texture to DEVICE pixels
  int cols_ = 110, rows_ = 30;   // worker-thread only after start; reflows on resize
  // kitty window_padding_width 10 16 10 10 (top right bottom left)
  qreal padT_ = 18, padR_ = 5, padB_ = 0, padL_ = 10;   // top matches the rail's 18px window inset
  qreal basePadL_ = 10, basePadR_ = 5;   // pre-slack values; hugGridRight adds the leftover to the LEFT
  GhosttyColorRgb palette_[256];
  GhosttyColorRgb defFg_{0xdd, 0xdd, 0xdd};
  GhosttyColorRgb defBg_{0x1e, 0x1e, 0x2e};
  GhosttyColorRgb defCursor_{0xdd, 0xdd, 0xdd};
  std::atomic<bool> active_{true};   // rail-focus state; hides the cursor when false

  // --- worker thread + GUI/worker handoff ---
  std::thread worker_;
  std::atomic<bool> quit_{false};
  int wakePipe_[2] = {-1, -1};        // GUI writes a byte to break the worker's poll()
  std::mutex cmdMtx_;                  // guards the command queue below
  std::deque<QByteArray> ptyOut_;     // input bytes bound for the PTY
  bool themeReload_ = false;          // theme_mode changed → reload colours on the worker
  bool repaintReq_ = false;           // active/focus toggled → re-render with no new data
  struct { bool pending = false; int cols, rows, viewW, viewH; qreal dpr; } resize_;
  std::mutex frameMtx_;               // guards frame_ (worker publishes, paint blits)
  QImage frame_;
  // worker-thread-local geometry (seeded in ctor, updated via resize_ commands)
  int wViewW_ = 0, wViewH_ = 0; qreal wDpr_ = 1.0;
  qreal lastDpr_ = 0.0;   // render-thread: last ratio pushed to the worker (drift check)
  qreal guiDpr_ = 0.0;    // GUI-thread copy, published to QML via the dpr property
};
