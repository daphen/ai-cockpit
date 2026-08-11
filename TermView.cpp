#include "TermView.h"

#include <QPainter>
#include <QPainterPath>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QSocketNotifier>
#include <QFontMetrics>
#include <QGuiApplication>
#include <QClipboard>
#include <QFileSystemWatcher>
#include <QQuickWindow>
#include <QString>
#include <cmath>

#include <pty.h>       // forkpty
#include <sys/ioctl.h> // TIOCSWINSZ
#include <unistd.h>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <string>
#include <cstdlib>
#include <cstring>
#include <cstdio>

TermView::TermView(QQuickItem *parent) : QQuickPaintedItem(parent) {
  setFlag(ItemHasContents, true);
  setAcceptedMouseButtons(Qt::AllButtons);
  setFocus(true);

  font_ = QFont("GeistMono Nerd Font");
  font_.setStyleHint(QFont::Monospace);
  font_.setHintingPreference(QFont::PreferNoHinting);  // don't stem-darken; lighter, closer to kitty
  font_.setPointSizeF(13.0);                 // kitty font_size 13
  QFontMetricsF fm(font_);
  const double natural = fm.height();
  cellW_ = qRound(fm.horizontalAdvance(QChar('M')));
  cellH_ = qRound(natural * 1.25);           // kitty modify_font cell_height 125%
  ascent_ = qRound(fm.ascent() + (cellH_ - natural) / 2.0);  // center glyph in cell
  setImplicitSize(cols_ * cellW_ + padL_ + padR_,
                  rows_ * cellH_ + padT_ + padB_);

  // libghostty-vt terminal at the fixed spike size.
  GhosttyResult r = ghostty_terminal_new(nullptr, &term_, cols_, rows_);
  if (r != GHOSTTY_SUCCESS) qFatal("ghostty_terminal_new failed: %d", r);

  ghostty_render_state_new(nullptr, &renderState_);  // cursor shape (DECSCUSR) lives here
  loadThemeColors();  // fg/bg/cursor + palette 0-15 for the current theme mode
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_USERDATA, this);
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       reinterpret_cast<const void *>(&TermView::onWritePty));
  applyThemeColors();

  // Live light/dark flip: reload colors when ~/.config/theme_mode changes.
  themeWatcher_ = new QFileSystemWatcher(this);
  {
    const char *home = getenv("HOME");
    QString tm = QString::fromStdString(std::string(home ? home : "") + "/.config/theme_mode");
    themeWatcher_->addPath(tm);
    connect(themeWatcher_, &QFileSystemWatcher::fileChanged, this, [this, tm](const QString &) {
      loadThemeColors();
      applyThemeColors();
      if (!themeWatcher_->files().contains(tm)) themeWatcher_->addPath(tm);  // re-arm after rewrite
    });
  }

  spawnPty();
}

TermView::~TermView() {
  if (notifier_) notifier_->setEnabled(false);
  if (master_ >= 0) ::close(master_);
  if (renderState_) ghostty_render_state_free(renderState_);
  if (term_) ghostty_terminal_free(term_);
}

void TermView::setActive(bool a) {
  if (a == active_) return;
  active_ = a;
  emit activeChanged();
  update();   // repaint so the cursor shows/hides immediately
}

static bool parseHex(const std::string &s, GhosttyColorRgb &out) {
  unsigned r, g, b;
  if (s.size() < 7 || s[0] != '#') return false;
  if (sscanf(s.c_str(), "#%2x%2x%2x", &r, &g, &b) != 3) return false;
  out.r = (uint8_t)r; out.g = (uint8_t)g; out.b = (uint8_t)b;
  return true;
}

void TermView::loadThemeColors() {
  const char *home = getenv("HOME");
  if (!home) return;
  // Current theme mode (light/dark) → the matching generated kitty palette.
  std::string mode = "dark";
  {
    std::ifstream mf(std::string(home) + "/.config/theme_mode");
    std::string m;
    if (mf && std::getline(mf, m)) {
      m.erase(0, m.find_first_not_of(" \t\r\n"));
      auto e = m.find_last_not_of(" \t\r\n");
      if (e != std::string::npos) m.erase(e + 1);
      if (m == "light" || m == "dark") mode = m;
    }
  }
  ghostty_color_palette_default(palette_);  // reset before overriding 0-15
  std::ifstream f(std::string(home) + "/.config/kitty/" + mode + "-theme.auto.conf");
  if (!f) return;
  std::string line;
  while (std::getline(f, line)) {
    std::istringstream is(line);
    std::string key, val;
    if (!(is >> key >> val)) continue;
    GhosttyColorRgb c;
    if (!parseHex(val, c)) continue;
    if (key == "background") defBg_ = c;
    else if (key == "foreground") defFg_ = c;
    else if (key == "cursor") defCursor_ = c;
    else if (key.rfind("color", 0) == 0) {
      int idx = atoi(key.c_str() + 5);
      if (idx >= 0 && idx < 256) palette_[idx] = c;
    }
  }
}

void TermView::applyThemeColors() {
  if (!term_) return;
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &defFg_);
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &defBg_);
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &defCursor_);
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette_);
  update();
}

void TermView::spawnPty() {
  struct winsize ws = {};
  ws.ws_col = cols_;
  ws.ws_row = rows_;
  pid_t pid = forkpty(&master_, nullptr, nullptr, &ws);
  if (pid < 0) { qFatal("forkpty failed"); }
  if (pid == 0) {
    // child: exec the login shell
    const char *sh = getenv("SHELL");
    if (!sh || !*sh) sh = "/bin/bash";
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);  // let nvim enable termguicolors → full theme
    setenv("HEIDR_COCKPIT", "1", 1);  // nvim uses this to enable rail-crossing keymaps
    // Fixed nvim RPC socket so the rail can open files in the running nvim
    // (nvim-follow). nvim reads NVIM_LISTEN_ADDRESS on startup to set --listen.
    {
      const char *rt = getenv("XDG_RUNTIME_DIR");
      static char nvsock[512];
      snprintf(nvsock, sizeof(nvsock), "%s/heidr-nvim.sock", rt && *rt ? rt : "/tmp");
      setenv("NVIM_LISTEN_ADDRESS", nvsock, 1);
    }
    // Auto-launch nvim in the pane; drop to a login shell when it exits.
    // Override the command with HEIDR_COCKPIT_CMD.
    // Launch nvim with an explicit --listen (NVIM_LISTEN_ADDRESS is deprecated in
    // 0.12 and doesn't reliably bind), so the rail can open files via --remote.
    const char *cmd = getenv("HEIDR_COCKPIT_CMD");
    if (!cmd || !*cmd) cmd = "rm -f \"$NVIM_LISTEN_ADDRESS\" 2>/dev/null; nvim --listen \"$NVIM_LISTEN_ADDRESS\" -c 'set shortmess+=I'; exec \"$SHELL\" -l";
    execl(sh, sh, "-l", "-c", cmd, (char *)nullptr);
    _exit(127);
  }
  // parent: watch the master fd for output
  notifier_ = new QSocketNotifier(master_, QSocketNotifier::Read, this);
  connect(notifier_, &QSocketNotifier::activated, this, &TermView::onPtyReadable);
}

void TermView::geometryChange(const QRectF &n, const QRectF &o) {
  QQuickPaintedItem::geometryChange(n, o);
  if (n.size() == o.size() || cellW_ <= 0 || cellH_ <= 0) return;
  const int c = std::max(1, (int(n.width()) - padL_ - padR_) / cellW_);
  const int r = std::max(1, (int(n.height()) - padT_ - padB_) / cellH_);
  if (c == cols_ && r == rows_) return;
  cols_ = c;
  rows_ = r;
  ghostty_terminal_resize(term_, (uint16_t)cols_, (uint16_t)rows_,
                          (uint32_t)cellW_, (uint32_t)cellH_);
  if (master_ >= 0) {
    struct winsize ws = {};
    ws.ws_col = (unsigned short)cols_;
    ws.ws_row = (unsigned short)rows_;
    ws.ws_xpixel = (unsigned short)(cols_ * cellW_);
    ws.ws_ypixel = (unsigned short)(rows_ * cellH_);
    ioctl(master_, TIOCSWINSZ, &ws);  // delivers SIGWINCH → shell/nvim reflow
  }
  update();
}

void TermView::onPtyReadable() {
  uint8_t buf[8192];
  ssize_t n = ::read(master_, buf, sizeof(buf));
  if (n <= 0) { notifier_->setEnabled(false); return; }
  ghostty_terminal_vt_write(term_, buf, (size_t)n);
  // Refresh the cursor's visual shape (block/bar/underline) from the render
  // state — DECSCUSR (nvim's mode-based cursor) updates it here.
  if (renderState_ && ghostty_render_state_update(renderState_, term_) == GHOSTTY_SUCCESS) {
    GhosttyRenderStateCursorVisualStyle sh = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    if (ghostty_render_state_get(renderState_, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &sh) == GHOSTTY_SUCCESS)
      cursorShape_ = (int)sh;
  }
  // Honor synchronized output (mode 2026): while nvim is mid-frame, don't
  // present partial state — that's what made the cursor flicker across panels.
  GhosttyTerminalModeConfig mc;
  mc.mode = GHOSTTY_MODE_SYNC_OUTPUT;
  mc.value = false;
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_MODE, &mc);
  if (!mc.value) update();
}

void TermView::writePty(const char *data, int len) {
  if (master_ >= 0 && len > 0) { ssize_t w = ::write(master_, data, len); (void)w; }
}

void TermView::onWritePty(GhosttyTerminal, void *userdata,
                          const uint8_t *data, size_t len) {
  auto *self = static_cast<TermView *>(userdata);
  if (self) self->writePty(reinterpret_cast<const char *>(data), (int)len);
}

void TermView::pasteText(const QString &t) {
  if (t.isEmpty()) return;
  QByteArray b = t.toUtf8();
  writePty(b.constData(), b.size());
}

static inline QColor toQ(const GhosttyColorRgb &c) { return QColor(c.r, c.g, c.b); }

static QColor resolveStyleColor(const GhosttyStyleColor &sc,
                                const GhosttyColorRgb *palette,
                                const QColor &fallback) {
  switch (sc.tag) {
    case GHOSTTY_STYLE_COLOR_RGB:
      return QColor(sc.value.rgb.r, sc.value.rgb.g, sc.value.rgb.b);
    case GHOSTTY_STYLE_COLOR_PALETTE:
      return toQ(palette[sc.value.palette]);
    default:
      return fallback;
  }
}

bool TermView::drawBoxChar(QPainter *p, int x, int y, uint32_t cp, const QColor &fg) {
  // One antialiased pen for EVERY segment (straight, tee, corner) so lines and
  // corners have identical weight — kitty-style uniform box-drawing. Pixel-snap
  // the center lines (+0.5) so 1px strokes stay crisp.
  const qreal t = std::max(1, cellW_ / 8);
  const qreal mx = std::floor(x + cellW_ / 2.0) + 0.5;
  const qreal my = std::floor(y + cellH_ / 2.0) + 0.5;
  const qreal x0 = x, x2 = x + cellW_, y0 = y, y2 = y + cellH_;
  p->save();
  p->setRenderHint(QPainter::Antialiasing, true);
  QPen pen(fg); pen.setWidthF(t); pen.setCapStyle(Qt::FlatCap); pen.setJoinStyle(Qt::MiterJoin);
  p->setPen(pen); p->setBrush(Qt::NoBrush);
  auto H = [&](qreal a, qreal b) { p->drawLine(QPointF(a, my), QPointF(b, my)); };
  auto V = [&](qreal a, qreal b) { p->drawLine(QPointF(mx, a), QPointF(mx, b)); };
  bool ok = true;
  switch (cp) {
    case 0x2500: H(x0, x2); break;                       // ─
    case 0x2502: V(y0, y2); break;                       // │
    case 0x250C: H(mx, x2); V(my, y2); break;            // ┌
    case 0x2510: H(x0, mx); V(my, y2); break;            // ┐
    case 0x2514: H(mx, x2); V(y0, my); break;            // └
    case 0x2518: H(x0, mx); V(y0, my); break;            // ┘
    case 0x251C: V(y0, y2); H(mx, x2); break;            // ├
    case 0x2524: V(y0, y2); H(x0, mx); break;            // ┤
    case 0x252C: H(x0, x2); V(my, y2); break;            // ┬
    case 0x2534: H(x0, x2); V(y0, my); break;            // ┴
    case 0x253C: H(x0, x2); V(y0, y2); break;            // ┼
    case 0x256D: case 0x256E: case 0x256F: case 0x2570: {   // ╭ ╮ ╯ ╰ rounded
      pen.setJoinStyle(Qt::RoundJoin); p->setPen(pen);
      const qreal r = std::min(cellW_, cellH_) * 0.4;
      QPainterPath pp;
      if (cp == 0x256D)      { pp.moveTo(x2, my); pp.lineTo(mx + r, my); pp.arcTo(QRectF(mx, my, 2 * r, 2 * r), 90, 90);          pp.lineTo(mx, y2); }
      else if (cp == 0x256E) { pp.moveTo(x0, my); pp.lineTo(mx - r, my); pp.arcTo(QRectF(mx - 2 * r, my, 2 * r, 2 * r), 90, -90);  pp.lineTo(mx, y2); }
      else if (cp == 0x2570) { pp.moveTo(x2, my); pp.lineTo(mx + r, my); pp.arcTo(QRectF(mx, my - 2 * r, 2 * r, 2 * r), 270, -90); pp.lineTo(mx, y0); }
      else                   { pp.moveTo(x0, my); pp.lineTo(mx - r, my); pp.arcTo(QRectF(mx - 2 * r, my - 2 * r, 2 * r, 2 * r), 270, 90); pp.lineTo(mx, y0); }
      p->drawPath(pp);
      break;
    }
    default: ok = false;
  }
  p->restore();
  return ok;
}

bool TermView::drawBlockChar(QPainter *p, int x, int y, uint32_t cp, const QColor &fg) {
  const int x2 = x + cellW_, y2 = y + cellH_;
  const int midx = x + cellW_ / 2, midy = y + cellH_ / 2;
  switch (cp) {
    case 0x2588: p->fillRect(x, y, cellW_, cellH_, fg); return true;         // █ full
    case 0x2580: p->fillRect(x, y, cellW_, cellH_ / 2, fg); return true;     // ▀ upper half
    case 0x2584: p->fillRect(x, midy, cellW_, y2 - midy, fg); return true;   // ▄ lower half
    case 0x2590: p->fillRect(midx, y, x2 - midx, cellH_, fg); return true;   // ▐ right half
    case 0x2591: case 0x2592: case 0x2593: {                                 // ░ ▒ ▓ shades
      QColor c = fg; c.setAlphaF(cp == 0x2591 ? 0.25 : cp == 0x2592 ? 0.5 : 0.75);
      p->fillRect(x, y, cellW_, cellH_, c); return true;
    }
    case 0x2589: case 0x258A: case 0x258B: case 0x258C:                      // ▉▊▋▌▍▎▏ left
    case 0x258D: case 0x258E: case 0x258F: {
      int w = std::max(1, (int)qRound(cellW_ * ((0x2590 - cp) / 8.0)));
      p->fillRect(x, y, w, cellH_, fg); return true;
    }
    case 0x2581: case 0x2582: case 0x2583: case 0x2585:                      // ▁▂▃▄▅▆▇ lower
    case 0x2586: case 0x2587: {
      int h = std::max(1, (int)qRound(cellH_ * ((cp - 0x2580) / 8.0)));
      p->fillRect(x, y2 - h, cellW_, h, fg); return true;
    }
    default: return false;   // quadrants/eighths (2594-259F) are rare → font glyph
  }
}

bool TermView::drawPowerline(QPainter *p, int x, int y, uint32_t cp, const QColor &fg) {
  const qreal w = cellW_, h = cellH_;
  const qreal x0 = x, x1 = x + w, y0 = y, y1 = y + h, ym = y + h / 2.0;
  p->save();
  p->setRenderHint(QPainter::Antialiasing, true);
  p->setPen(Qt::NoPen);
  p->setBrush(fg);
  bool handled = true;
  switch (cp) {
    case 0xE0B0: { QPointF pts[3] = {{x0, y0}, {x1, ym}, {x0, y1}}; p->drawConvexPolygon(pts, 3); break; }  //
    case 0xE0B2: { QPointF pts[3] = {{x1, y0}, {x0, ym}, {x1, y1}}; p->drawConvexPolygon(pts, 3); break; }  //
    case 0xE0B4: { QPainterPath pp; pp.moveTo(x0, y0); pp.arcTo(QRectF(x0 - w, y0, 2 * w, h), 90, -180); pp.closeSubpath(); p->drawPath(pp); break; }  //
    case 0xE0B6: { QPainterPath pp; pp.moveTo(x1, y0); pp.arcTo(QRectF(x1 - w, y0, 2 * w, h), 90, 180); pp.closeSubpath(); p->drawPath(pp); break; }  //
    case 0xE0B1: case 0xE0B3: {  // thin chevron outlines
      QPen pen(fg); pen.setWidthF(1.5); p->setPen(pen); p->setBrush(Qt::NoBrush);
      if (cp == 0xE0B1) { p->drawLine(QPointF(x0, y0), QPointF(x1, ym)); p->drawLine(QPointF(x1, ym), QPointF(x0, y1)); }
      else              { p->drawLine(QPointF(x1, y0), QPointF(x0, ym)); p->drawLine(QPointF(x0, ym), QPointF(x1, y1)); }
      break;
    }
    case 0xE0B5: case 0xE0B7: {  // thin half-circle outlines
      QPen pen(fg); pen.setWidthF(1.5); p->setPen(pen); p->setBrush(Qt::NoBrush);
      if (cp == 0xE0B5) p->drawArc(QRectF(x0 - w, y0, 2 * w, h), 90 * 16, -180 * 16);
      else              p->drawArc(QRectF(x1 - w, y0, 2 * w, h), 90 * 16, 180 * 16);
      break;
    }
    default: handled = false;
  }
  p->restore();
  return handled;
}

void TermView::paint(QPainter *outP) {
  // QQuickPaintedItem scales the painter by a transform (device-pixel-ratio is
  // left at 1), so drawText rasterizes glyphs at base size then stretches the
  // bitmap → fuzzy/thick. Render into our own DPR-aware image (glyphs rasterize
  // at the real density with an identity transform), then blit it 1:1.
  const qreal ratio = window() ? window()->effectiveDevicePixelRatio() : 1.0;
  QImage img(QSize(std::max(1, (int)std::ceil(width() * ratio)),
                   std::max(1, (int)std::ceil(height() * ratio))),
             QImage::Format_ARGB32_Premultiplied);
  img.setDevicePixelRatio(ratio);
  img.fill(Qt::transparent);
  QPainter localPainter(&img);
  QPainter *p = &localPainter;

  // Effective defaults (an app may have OSC-overridden fg/bg/cursor).
  GhosttyColorRgb fgD = defFg_, bgD = defBg_, curD = defCursor_;
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fgD);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bgD);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, &curD);
  const QColor defFg = toQ(fgD), defBg = toQ(bgD), curColor = toQ(curD);

  p->fillRect(boundingRect(), defBg);

  uint16_t cx = 0, cy = 0;
  bool cvis = true;
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &cvis);

  // Two passes: fill EVERY background first, then draw glyphs on top. A glyph
  // can overhang its cell (wide Nerd icons horizontally, descenders vertically);
  // if a neighbor's background were filled after the glyph, it would clip that
  // overhang. Separating the passes lets overhangs survive.
  struct Glyph { int x, y; uint32_t cp; QColor fg; bool bold; };
  std::vector<Glyph> glyphs;
  glyphs.reserve((size_t)rows_ * cols_);

  for (uint16_t row = 0; row < rows_; ++row) {
    for (uint16_t col = 0; col < cols_; ++col) {
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      GhosttyPoint pt;
      pt.tag = GHOSTTY_POINT_TAG_ACTIVE;
      pt.value.coordinate.x = col;
      pt.value.coordinate.y = row;
      if (ghostty_terminal_grid_ref(term_, pt, &ref) != GHOSTTY_SUCCESS) continue;

      GhosttyCell cell;
      if (ghostty_grid_ref_cell(&ref, &cell) != GHOSTTY_SUCCESS) continue;

      GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
      ghostty_grid_ref_style(&ref, &style);

      bool has = false;
      ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has);

      QColor fg = resolveStyleColor(style.fg_color, palette_, defFg);
      QColor bg = resolveStyleColor(style.bg_color, palette_, QColor());
      if (!bg.isValid()) {  // text-less cells carry their bg on the cell itself
        GhosttyCellContentTag ct;
        if (ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &ct) == GHOSTTY_SUCCESS) {
          if (ct == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
            GhosttyColorRgb c;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_RGB, &c);
            bg = toQ(c);
          } else if (ct == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
            GhosttyColorPaletteIndex idx;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_PALETTE, &idx);
            bg = toQ(palette_[idx]);
          }
        }
      }

      QColor effBg = bg.isValid() ? bg : defBg;
      if (style.inverse) std::swap(fg, effBg);
      if (style.faint) fg = QColor((fg.red() + effBg.red()) / 2,
                                   (fg.green() + effBg.green()) / 2,
                                   (fg.blue() + effBg.blue()) / 2);

      const int x = padL_ + col * cellW_, y = padT_ + row * cellH_;
      if (effBg != defBg) p->fillRect(x, y, cellW_, cellH_, effBg);

      if (has) {
        uint32_t cp = 0;
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
        glyphs.push_back({x, y, cp, fg, (bool)style.bold});
      }
    }
  }

  for (const Glyph &g : glyphs) {
    if (g.cp >= 0x2500 && g.cp <= 0x257F && drawBoxChar(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural box-drawing fills the cell; skip the glyph
    if (g.cp >= 0x2580 && g.cp <= 0x259F && drawBlockChar(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural block elements fill the cell; skip the glyph
    if (g.cp >= 0xE0B0 && g.cp <= 0xE0B7 && drawPowerline(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural powerline separators (smooth, seamless)
    QFont f = font_;
    f.setBold(g.bold);
    // Italics off entirely: the GeistMono italic face slants past the cell's
    // right edge and gets clipped, so render italic-attributed cells upright.
    p->setFont(f);
    p->setPen(g.fg);
    p->drawText(g.x, g.y + ascent_,
                QString::fromUcs4(reinterpret_cast<const char32_t *>(&g.cp), 1));
  }

  // Cursor: honor the app's requested shape (nvim swaps block/beam by mode).
  if (cvis && active_ && cx < cols_ && cy < rows_) {   // hidden when the rail has focus
    const int x = padL_ + cx * cellW_, y = padT_ + cy * cellH_;
    switch (cursorShape_) {
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
        p->fillRect(x, y, 2, cellH_, curColor);  // beam (insert mode)
        break;
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
        p->fillRect(x, y + cellH_ - 2, cellW_, 2, curColor);
        break;
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        p->setPen(curColor);
        p->drawRect(x, y, cellW_ - 1, cellH_ - 1);
        break;
      default: {  // BLOCK: fill, redraw the glyph under it in the bg color
        p->fillRect(x, y, cellW_, cellH_, curColor);
        GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
        GhosttyPoint pt;
        pt.tag = GHOSTTY_POINT_TAG_ACTIVE;
        pt.value.coordinate.x = cx;
        pt.value.coordinate.y = cy;
        if (ghostty_terminal_grid_ref(term_, pt, &ref) == GHOSTTY_SUCCESS) {
          GhosttyCell cell;
          bool has = false;
          if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) {
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has);
            if (has) {
              uint32_t cp = 0;
              ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
              p->setFont(font_);
              p->setPen(defBg);
              p->drawText(x, y + ascent_,
                          QString::fromUcs4(reinterpret_cast<const char32_t *>(&cp), 1));
            }
          }
        }
        break;
      }
    }
  }

  localPainter.end();
  // Point-form blit of the DPR-tagged image → drawn 1:1 at its logical size with
  // NO resampling. The rect form rescales+smooths even at 1:1, which softened it.
  outP->setRenderHint(QPainter::SmoothPixmapTransform, false);
  outP->drawImage(QPointF(0, 0), img);
}

void TermView::keyPressEvent(QKeyEvent *e) {
  const bool ctrl = e->modifiers() & Qt::ControlModifier;
  const bool shift = e->modifiers() & Qt::ShiftModifier;
  // Ctrl+Shift+V / Shift+Insert → paste clipboard (before ctrl-char encoding).
  if ((ctrl && shift && e->key() == Qt::Key_V) ||
      (shift && e->key() == Qt::Key_Insert)) {
    pasteText(QGuiApplication::clipboard()->text(QClipboard::Clipboard));
    return;
  }

  QByteArray out;
  switch (e->key()) {
    case Qt::Key_Return:
    case Qt::Key_Enter:     out = "\r"; break;
    case Qt::Key_Backspace: out = "\x7f"; break;
    case Qt::Key_Tab:       out = "\t"; break;
    case Qt::Key_Escape:    out = "\x1b"; break;
    case Qt::Key_Up:        out = "\x1b[A"; break;
    case Qt::Key_Down:      out = "\x1b[B"; break;
    case Qt::Key_Right:     out = "\x1b[C"; break;
    case Qt::Key_Left:      out = "\x1b[D"; break;
    default:
      if (e->modifiers() & Qt::ControlModifier) {
        QString t = e->text();
        if (!t.isEmpty()) { char c = t.at(0).toLatin1(); out.append(char(c & 0x1f)); }
      } else {
        out = e->text().toUtf8();
      }
  }
  if (!out.isEmpty()) writePty(out.constData(), out.size());
  else QQuickPaintedItem::keyPressEvent(e);
}

void TermView::mousePressEvent(QMouseEvent *e) {
  forceActiveFocus();
  if (e->button() == Qt::MiddleButton) {
    auto *cb = QGuiApplication::clipboard();
    QString t = cb->supportsSelection() ? cb->text(QClipboard::Selection)
                                        : cb->text(QClipboard::Clipboard);
    pasteText(t);
    return;
  }
  QQuickPaintedItem::mousePressEvent(e);
}
