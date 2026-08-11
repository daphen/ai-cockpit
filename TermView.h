#pragma once
#include <QQuickPaintedItem>
#include <QFont>
#include <QtQmlIntegration>

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

  // false when focus is in the rail → hide the terminal cursor.
  Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
  bool active() const { return active_; }
  void setActive(bool a);

signals:
  void activeChanged();

protected:
  void keyPressEvent(QKeyEvent *e) override;
  void mousePressEvent(QMouseEvent *e) override;
  void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

private slots:
  void onPtyReadable();

private:
  void spawnPty();
  void writePty(const char *data, int len);
  void pasteText(const QString &t);
  // Load default fg/bg/cursor + palette 0-15 from the theme generator's output
  // (kitty dark-theme.auto.conf), so the terminal matches the rest of the desktop.
  void loadThemeColors();       // read fg/bg/cursor/palette for the CURRENT theme mode
  void applyThemeColors();      // push the loaded colors into the terminal + repaint
  // Box-drawing glyphs must fill the whole cell so lines connect across the
  // 1.25× line height; draw the common ones procedurally. Returns false for
  // codepoints we don't handle (caller falls back to the font glyph).
  bool drawBoxChar(QPainter *p, int x, int y, uint32_t cp, const QColor &fg);
  // Block elements (U+2580..U+259F: █ ▌ ▎ ▄ shades …) must fill the full cell so
  // vertical bars (markdown quote guides) connect across the 1.25× line height.
  bool drawBlockChar(QPainter *p, int x, int y, uint32_t cp, const QColor &fg);
  // Powerline separators (U+E0B0..E0B7) drawn as filled vector shapes scaled to
  // the full cell — smooth + seamless, like kitty/ghostty (not the font glyph).
  bool drawPowerline(QPainter *p, int x, int y, uint32_t cp, const QColor &fg);
  // libghostty-vt invokes this when the terminal must reply to the PTY
  // (DSR, DA, cursor-position reports). Routes back to writePty via userdata.
  static void onWritePty(GhosttyTerminal t, void *userdata,
                         const uint8_t *data, size_t len);

  GhosttyTerminal term_ = nullptr;
  GhosttyRenderState renderState_ = nullptr;  // for the cursor's visual shape (DECSCUSR)
  int cursorShape_ = 1;          // GhosttyRenderStateCursorVisualStyle; 1 = BLOCK
  int master_ = -1;              // PTY master fd
  QSocketNotifier *notifier_ = nullptr;
  QFileSystemWatcher *themeWatcher_ = nullptr;  // ~/.config/theme_mode → live light/dark flip
  QFont font_;
  int cellW_ = 9, cellH_ = 18, ascent_ = 14;
  int cols_ = 110, rows_ = 30;   // initial; reflows on window resize
  // kitty window_padding_width 10 16 10 10 (top right bottom left)
  const int padT_ = 10, padR_ = 16, padB_ = 0, padL_ = 10;
  GhosttyColorRgb palette_[256];
  GhosttyColorRgb defFg_{0xdd, 0xdd, 0xdd};
  GhosttyColorRgb defBg_{0x1e, 0x1e, 0x2e};
  GhosttyColorRgb defCursor_{0xdd, 0xdd, 0xdd};
  bool active_ = true;   // rail-focus state; hides the cursor when false
};
