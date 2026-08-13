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
#include <signal.h>    // killpg on teardown
#include <sys/wait.h>
#include <sys/ioctl.h> // TIOCSWINSZ
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cerrno>

// Kitty graphics needs a PNG decoder installed process-wide. Decode via QImage
// into tight RGBA, allocated through the library's allocator (it takes ownership
// and frees with the same allocator).
static bool heidrDecodePng(void *, const GhosttyAllocator *alloc,
                           const uint8_t *data, size_t len, GhosttySysImage *out) {
  QImage img;
  if (!img.loadFromData(data, (int)len, "PNG")) return false;
  img = img.convertToFormat(QImage::Format_RGBA8888);
  const size_t w = (size_t)img.width(), h = (size_t)img.height();
  const size_t n = w * h * 4;
  uint8_t *buf = ghostty_alloc(alloc, n);
  if (!buf) return false;
  for (size_t y = 0; y < h; y++)
    memcpy(buf + y * w * 4, img.constScanLine((int)y), w * 4);
  out->width = (uint32_t)w; out->height = (uint32_t)h;
  out->data = buf; out->data_len = n;
  return true;
}

// Kitty unicode-placeholder row/column diacritics (kitty's canonical 297-entry
// table). The Nth combining mark on a U+10EEEE placeholder cell encodes the
// number N — 1st = image row, 2nd = image column, 3rd = high byte of image id.
static const uint32_t kKittyDiacritics[] = {
#include "kitty_diacritics.inc"
};
static int kittyDiacriticIndex(uint32_t cp) {
  for (size_t i = 0; i < sizeof(kKittyDiacritics) / sizeof(uint32_t); ++i)
    if (kKittyDiacritics[i] == cp) return (int)i;
  return -1;
}

// Borrowed kitty image pixels (RGBA/RGB, uncompressed) → a QImage view. Returns
// a null image for anything we can't map. No copy: valid only within paint().
static QImage kittyImageView(GhosttyKittyGraphicsImage im) {
  uint32_t iw = 0, ih = 0;
  GhosttyKittyImageFormat fmt = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
  GhosttyKittyImageCompression comp = GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE;
  const uint8_t *pix = nullptr; size_t plen = 0;
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &iw);
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &ih);
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &fmt);
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION, &comp);
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pix);
  ghostty_kitty_graphics_image_get(im, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &plen);
  if (!pix || !iw || !ih || comp != GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE) return QImage();
  QImage::Format qfmt;
  if (fmt == GHOSTTY_KITTY_IMAGE_FORMAT_RGBA) qfmt = QImage::Format_RGBA8888;
  else if (fmt == GHOSTTY_KITTY_IMAGE_FORMAT_RGB) qfmt = QImage::Format_RGB888;
  else return QImage();
  return QImage(pix, (int)iw, (int)ih, qfmt);
}

TermView::TermView(QQuickItem *parent) : QQuickPaintedItem(parent) {
  setFlag(ItemHasContents, true);
  setAcceptedMouseButtons(Qt::AllButtons);
  setFocus(true);

  // Match the RAIL's text rendering so the two panes look like one app: same family,
  // sized in PIXELS like QsLib does (Theme.fontSize + n), and the DEFAULT hinting
  // preference. PreferNoHinting was chosen to imitate kitty, but the rail's QML Text
  // uses Quickshell's forced NativeRendering with default hinting, so the terminal
  // read visibly lighter/softer than the panel beside it.
  font_ = QFont("GeistMono Nerd Font");
  font_.setStyleHint(QFont::Monospace);
  // Tunable at runtime so rendering can be judged side by side without a rebuild:
  //   HEIDR_HINTING = none | slight | full | default   (default: default = rail-like)
  //   HEIDR_FONT_PX = <pixels>                          (default: 17 ≈ 13pt at 96dpi)
  {
    const QByteArray h = qgetenv("HEIDR_HINTING");
    QFont::HintingPreference hp = QFont::PreferDefaultHinting;
    if (h == "none")   hp = QFont::PreferNoHinting;
    if (h == "slight") hp = QFont::PreferVerticalHinting;   // vertical stems only
    if (h == "full")   hp = QFont::PreferFullHinting;
    font_.setHintingPreference(hp);
    bool ok = false;
    const int px = qgetenv("HEIDR_FONT_PX").toInt(&ok);
    font_.setPixelSize(ok && px >= 8 && px <= 48 ? px : 17);
  }
  // kitty's `symbol_map U+E000-U+E4FF QsIcons` has no Qt equivalent, and the range
  // collides with the Nerd Font's Seti block — so without an explicit per-codepoint
  // font the rail's Nucleo icons silently render as the WRONG glyph.
  iconFont_ = QFont("QsIcons");
  iconFont_.setHintingPreference(font_.hintingPreference());
  iconFont_.setPixelSize(font_.pixelSize());

  QFontMetricsF fm(font_);
  const double natural = fm.height();
  baseCellW_ = fm.horizontalAdvance(QChar('M'));
  baseCellH_ = natural * 1.25;                // kitty modify_font cell_height 125%
  baseAscent_ = fm.ascent() + (baseCellH_ - natural) / 2.0;   // center glyph in cell
  applyMetrics(1.0);
  setImplicitSize(cols_ * cellW_ + padL_ + padR_,
                  rows_ * cellH_ + padT_ + padB_);

  // libghostty-vt terminal at the fixed spike size.
  GhosttyResult r = ghostty_terminal_new(nullptr, &term_, cols_, rows_);
  if (r != GHOSTTY_SUCCESS) qFatal("ghostty_terminal_new failed: %d", r);

  ghostty_render_state_new(nullptr, &renderState_);  // cursor shape (DECSCUSR) lives here
  // Kitty graphics: install the PNG decoder once (process-wide) and give this
  // terminal a storage budget so it accepts + stores images (dashboard banner, etc.).
  static bool s_pngInstalled = false;
  if (!s_pngInstalled) {
    // Callback options take the function pointer BY VALUE (ghostty_sys_set casts the
    // void* straight to the fn type), unlike the scalar terminal options, which take a
    // pointer TO the value. Passing &localVariable stored the address of a stack slot
    // and libghostty later jumped into stack garbage — a segfault on the first PNG.
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<void *>(&heidrDecodePng));
    s_pngInstalled = true;
  }
  size_t kittyLimit = (size_t)320 * 1024 * 1024;
  ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyLimit);
  // Kitty's FILE and SHARED-MEMORY transmission mediums are opt-in — a terminal reading
  // paths an application names is a real capability, so libghostty makes you ask. Without
  // this, only inline base64 works, and snacks.image (the nvim dashboard masthead, and
  // image.nvim generally) writes a PNG to a temp path and sends the PATH — so its images
  // never landed and the placeholder cells rendered as coloured blocks instead, coloured
  // by the image id encoded in their foreground.
  {
    bool on = true;
    ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &on);
    ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &on);
    // Temp-file transmission is restricted to a directory, which is the point: the
    // terminal will only read images out of the system temp dir.
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
    GhosttyString tdir{};
    tdir.ptr = reinterpret_cast<const uint8_t *>(tmpdir);
    tdir.len = strlen(tmpdir);
    ghostty_terminal_set(term_, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &tdir);
  }
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
      { std::lock_guard<std::mutex> lk(cmdMtx_); themeReload_ = true; }
      wakeWorker();   // colours (palette_/term_) are worker-owned → reload there
      if (!themeWatcher_->files().contains(tm)) themeWatcher_->addPath(tm);  // re-arm after rewrite
    });
  }

  spawnPty();

  // Worker thread owns the PTY read loop + ghostty + rasterization. A self-pipe
  // lets the GUI thread break the worker's blocking poll() to deliver commands.
  if (pipe(wakePipe_) != 0) qFatal("wake pipe failed");
  for (int i = 0; i < 2; ++i) {
    fcntl(wakePipe_[i], F_SETFL, fcntl(wakePipe_[i], F_GETFL) | O_NONBLOCK);
    fcntl(wakePipe_[i], F_SETFD, fcntl(wakePipe_[i], F_GETFD) | FD_CLOEXEC);
  }
  wViewW_ = (int)(cols_ * cellW_ + padL_ + padR_);
  wViewH_ = (int)(rows_ * cellH_ + padT_ + padB_);
  worker_ = std::thread(&TermView::workerLoop, this);
}

TermView::~TermView() {
  quit_.store(true);
  wakeWorker();
  if (worker_.joinable()) worker_.join();
  // Take the shell tree with us. forkpty's child is a SESSION LEADER, so its pgid is
  // its pid and one killpg reaches fish and everything it started. Closing the master
  // alone was not enough — nvim survived it, so every relaunch of the cockpit orphaned
  // another editor (30 of them after an afternoon of restarts), and those orphans still
  // hold the nvim server socket, which is what made live-follow land in the wrong place.
  if (child_ > 0) {
    ::killpg(child_, SIGHUP);
    for (int i = 0; i < 20; ++i) {                 // ~200ms for a clean exit
      if (::waitpid(child_, nullptr, WNOHANG) == child_) { child_ = -1; break; }
      struct timespec ts { 0, 10 * 1000 * 1000 };
      ::nanosleep(&ts, nullptr);
    }
    if (child_ > 0) { ::killpg(child_, SIGKILL); ::waitpid(child_, nullptr, 0); }
  }
  if (wakePipe_[0] >= 0) ::close(wakePipe_[0]);
  if (wakePipe_[1] >= 0) ::close(wakePipe_[1]);
  if (master_ >= 0) ::close(master_);
  if (renderState_) ghostty_render_state_free(renderState_);
  if (term_) ghostty_terminal_free(term_);
}

void TermView::setActive(bool a) {
  if (a == active_.load()) return;
  active_.store(a);
  emit activeChanged();
  { std::lock_guard<std::mutex> lk(cmdMtx_); repaintReq_ = true; }
  wakeWorker();   // worker re-renders so the cursor shows/hides immediately
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
}

// Snap the cell box + padding to whole DEVICE pixels for this ratio. Everything the
// renderer positions is a multiple of cellW/cellH offset by the pads, so if those are
// exact device-pixel multiples then every glyph origin is too — which is what keeps
// stem weights identical across columns instead of alternating crisp/smeared.
// QQuickPaintedItem's backing texture defaults to the item size in LOGICAL pixels,
// so on a 1.5x/1.75x display everything we paint is rasterized into a texture smaller
// than the physical pixels and then scaled UP by the compositor — a permanent softness
// that no font/metric tuning can recover. Pin the texture to device pixels instead.
void TermView::syncTextureSize(qreal dpr) {
  if (dpr <= 0) dpr = 1.0;
  // qRound, not ceil: with a device-pixel-snapped item these are exact, and rounding
  // keeps the painter's scale equal to dpr instead of a hair above it. A warning fires
  // if the item is ever unsnapped again, because the symptom (slightly soft, unevenly
  // weighted glyphs) is easy to misread as a font problem.
  const qreal wantW = width() * dpr, wantH = height() * dpr;
  const bool exact = std::abs(wantW - std::round(wantW)) <= 0.01 &&
                     std::abs(wantH - std::round(wantH)) <= 0.01;
  // Only report a mismatch that SURVIVES: Qt hands out dpr 1, then 2, then the real
  // ratio during startup, and the item re-snaps at each step. Warning on the way through
  // told me the mapping was broken when the settled state was already exact.
  if (!exact) {
    QMetaObject::invokeMethod(this, [this] {
      const qreal r = guiDpr_ > 0 ? guiDpr_ : 1.0;
      const qreal w = width() * r, h = height() * r;
      if (std::abs(w - std::round(w)) > 0.01 || std::abs(h - std::round(h)) > 0.01)
        qWarning("TermView: settled size %gx%g at dpr %g is not device-pixel exact — "
                 "frames resample, glyph stems will look uneven", width(), height(), r);
    }, Qt::QueuedConnection);
  }
  const int tw = std::max(1, (int)std::round(wantW));
  const int th = std::max(1, (int)std::round(wantH));
  if (textureSize() != QSize(tw, th)) setTextureSize(QSize(tw, th));
}

void TermView::applyMetrics(qreal dpr) {
  if (dpr <= 0) dpr = 1.0;
  auto snap = [dpr](qreal v) { return std::max(1.0, std::round(v * dpr)) / dpr; };
  cellW_  = snap(baseCellW_);
  cellH_  = snap(baseCellH_);
  ascent_ = std::round(baseAscent_ * dpr) / dpr;
  padT_ = snap(18); padR_ = snap(16); padB_ = 0; padL_ = snap(10);
  basePadT_ = padT_; basePadB_ = padB_;
}

void TermView::spawnPty() {
  struct winsize ws = {};
  ws.ws_col = cols_;
  ws.ws_row = rows_;
  pid_t pid = forkpty(&master_, nullptr, nullptr, &ws);
  if (pid < 0) { qFatal("forkpty failed"); }
  if (pid > 0) child_ = pid;   // remember it so teardown can take the shell tree with us
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
  // parent: the worker thread's poll() loop reads master_ (see workerLoop).
}

void TermView::geometryChange(const QRectF &n, const QRectF &o) {
  QQuickPaintedItem::geometryChange(n, o);
  if (n.size() == o.size() || cellW_ <= 0 || cellH_ <= 0) return;
  const int c = std::max(1, (int)((n.width()  - padL_ - padR_) / cellW_));
  // Rows never divide the height exactly, and the remainder used to pile up at the
  // bottom as a dead band below the statusline — with the cursor occasionally drawn
  // into it, which is what the stray dash past the lualine was. Split the remainder
  // top/bottom so it reads as symmetric padding instead of a gap.
  const int r = std::max(1, (int)((n.height() - basePadT_ - basePadB_) / cellH_));
  centerGrid(n.height(), r);
  const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
  syncTextureSize(dpr);
  {
    std::lock_guard<std::mutex> lk(cmdMtx_);
    resize_ = { true, c, r, (int)n.width(), (int)n.height(), dpr };
  }
  wakeWorker();   // worker applies ghostty_terminal_resize + TIOCSWINSZ + re-renders
}

// Distribute the vertical remainder around the grid. basePad* is the design padding
// (kitty's window_padding_width); anything left over after whole rows is shared between
// top and bottom so no unexplained strip survives at one edge.
void TermView::centerGrid(qreal viewH, int rows) {
  const qreal used = rows * cellH_;
  qreal slack = viewH - used - basePadT_ - basePadB_;
  if (slack < 0) slack = 0;
  const qreal half = std::floor(slack / 2.0);
  padT_ = basePadT_ + half;
  padB_ = basePadB_ + (slack - half);
}

void TermView::wakeWorker() {
  if (wakePipe_[1] >= 0) { char b = 1; ssize_t w = ::write(wakePipe_[1], &b, 1); (void)w; }
}

void TermView::enqueuePty(const QByteArray &bytes) {
  if (bytes.isEmpty()) return;
  { std::lock_guard<std::mutex> lk(cmdMtx_); ptyOut_.push_back(bytes); }
  wakeWorker();
}

void TermView::workerLoop() {
  int lastCols = cols_, lastRows = rows_;
  bool dirty = false;

  while (!quit_.load()) {
    struct pollfd fds[2];
    fds[0].fd = master_;      fds[0].events = POLLIN; fds[0].revents = 0;
    fds[1].fd = wakePipe_[0]; fds[1].events = POLLIN; fds[1].revents = 0;
    int pr = ::poll(fds, 2, -1);
    if (pr < 0) { if (errno == EINTR) continue; break; }
    if (quit_.load()) break;

    if (fds[1].revents & POLLIN) {
      char drain[256]; while (::read(wakePipe_[0], drain, sizeof(drain)) > 0) {}
    }

    std::deque<QByteArray> outs;
    bool doResize = false, doTheme = false, doRepaint = false;
    decltype(resize_) rz{};
    {
      std::lock_guard<std::mutex> lk(cmdMtx_);
      outs.swap(ptyOut_);
      if (resize_.pending) { rz = resize_; resize_.pending = false; doResize = true; }
      doTheme = themeReload_;   themeReload_ = false;
      doRepaint = repaintReq_;  repaintReq_ = false;
    }
    for (auto &b : outs) writePty(b.constData(), b.size());
    if (doTheme)   { loadThemeColors(); applyThemeColors(); dirty = true; }
    if (doResize) {
      if (rz.cols != lastCols || rz.rows != lastRows) {
        cols_ = rz.cols; rows_ = rz.rows;
        ghostty_terminal_resize(term_, (uint16_t)cols_, (uint16_t)rows_,
                                (uint32_t)cellW_, (uint32_t)cellH_);
        if (master_ >= 0) {
          struct winsize ws = {};
          ws.ws_col = (unsigned short)cols_;   ws.ws_row = (unsigned short)rows_;
          ws.ws_xpixel = (unsigned short)(cols_ * cellW_);
          ws.ws_ypixel = (unsigned short)(rows_ * cellH_);
          ioctl(master_, TIOCSWINSZ, &ws);  // SIGWINCH → shell/nvim reflow
        }
        lastCols = cols_; lastRows = rows_;
      }
      wViewW_ = rz.viewW; wViewH_ = rz.viewH;
      if (std::abs(rz.dpr - wDpr_) > 0.001) { wDpr_ = rz.dpr; applyMetrics(wDpr_); }
      dirty = true;
    }
    if (doRepaint) dirty = true;

    bool ptyClosed = false;
    if (fds[0].revents & POLLIN) {
      // Drain the whole burst before rendering — one nvim redraw can span many
      // reads; rendering per-chunk would emit redundant mid-burst frames (the
      // big-file-open stutter). Inner poll(0) gates extra reads on a blocking fd.
      uint8_t buf[65536];
      for (;;) {
        ssize_t n = ::read(master_, buf, sizeof(buf));
        if (n > 0) {
          ghostty_terminal_vt_write(term_, buf, (size_t)n);
          dirty = true;
          struct pollfd more; more.fd = master_; more.events = POLLIN; more.revents = 0;
          if (::poll(&more, 1, 0) > 0 && (more.revents & POLLIN)) continue;
          break;
        }
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) ptyClosed = true;
        break;
      }
      // Cursor visual shape (block/bar/underline) — nvim swaps it by mode.
      if (dirty && renderState_ && ghostty_render_state_update(renderState_, term_) == GHOSTTY_SUCCESS) {
        GhosttyRenderStateCursorVisualStyle sh = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        if (ghostty_render_state_get(renderState_, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &sh) == GHOSTTY_SUCCESS)
          cursorShape_ = (int)sh;
      }
    }
    if (ptyClosed || (fds[0].revents & (POLLHUP | POLLERR))) {
      if (dirty) {  // present nvim's final frame before we tear down
        QImage f = renderFrame();
        { std::lock_guard<std::mutex> lk(frameMtx_); frame_ = f; }
        QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
      }
      break;  // PTY closed (shell/nvim exited)
    }

    if (!dirty) continue;

    // Synchronized output (mode 2026): don't present a half-drawn frame. Stay
    // dirty and render once nvim ends the sync (next data burst wakes us).
    GhosttyTerminalModeConfig mc;
    mc.mode = GHOSTTY_MODE_SYNC_OUTPUT; mc.value = false;
    ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_MODE, &mc);
    if (mc.value) continue;

    QImage f = renderFrame();
    { std::lock_guard<std::mutex> lk(frameMtx_); frame_ = f; }
    dirty = false;
    QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
  }
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
  enqueuePty(t.toUtf8());   // GUI thread → worker owns the PTY fd
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

bool TermView::drawBoxChar(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg) {
  // One antialiased pen for EVERY segment (straight, tee, corner) so lines and
  // corners have identical weight — kitty-style uniform box-drawing. Pixel-snap
  // the center lines (+0.5) so 1px strokes stay crisp.
  const qreal t = std::max(1.0, cellW_ / 8);
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

bool TermView::drawBlockChar(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg) {
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

bool TermView::drawPowerline(QPainter *p, qreal x, qreal y, uint32_t cp, const QColor &fg) {
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
  // GUI/scene-graph thread: only blit the frame the worker rasterized. All the
  // heavy work (VT parse + glyph raster) happens off this thread in workerLoop.
  //
  // The worker caches the device-pixel-ratio and previously only refreshed it on a
  // RESIZE, so plugging into a differently-scaled display (or any scale change with
  // no geometry change) left it rasterizing at the old ratio — the frame then got
  // stretched into the item and the text looked blotchy/pixelated rather than merely
  // soft. Re-check the live ratio here and hand the worker a fresh one when it drifts.
  const qreal liveDpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
  // Publish the ratio to the GUI thread. itemChange() fires before the window is mapped,
  // where effectiveDevicePixelRatio() still reads 1, and screenChanged never fires when
  // the window opens on its final screen — so paint() is the only place that reliably
  // knows. Queued, because this runs on the render thread.
  if (liveDpr > 0 && std::abs(liveDpr - guiDpr_) > 0.001) {
    QMetaObject::invokeMethod(this, [this, liveDpr] {
      if (std::abs(liveDpr - guiDpr_) > 0.001) { guiDpr_ = liveDpr; emit dprChanged(); }
    }, Qt::QueuedConnection);
  }
  if (liveDpr > 0 && std::abs(liveDpr - lastDpr_) > 0.01) {
    lastDpr_ = liveDpr;
    syncTextureSize(liveDpr);
    {
      std::lock_guard<std::mutex> lk(cmdMtx_);
      resize_ = { true, cols_, rows_, (int)width(), (int)height(), liveDpr };
    }
    wakeWorker();
  }
  QImage f;
  { std::lock_guard<std::mutex> lk(frameMtx_); f = frame_; }
  if (f.isNull()) { outP->fillRect(boundingRect(), toQ(defBg_)); return; }
  outP->setRenderHint(QPainter::SmoothPixmapTransform, false);
  outP->drawImage(QPointF(0, 0), f);
}

QImage TermView::renderFrame() {
  // Worker thread. Render into a DPR-aware image (glyphs rasterize at the real
  // density with an identity transform), which paint() then blits 1:1.
  const qreal ratio = wDpr_ > 0 ? wDpr_ : 1.0;
  const int vw = std::max(1, wViewW_), vh = std::max(1, wViewH_);
  QImage img(QSize(std::max(1, (int)std::round(vw * ratio)),
                   std::max(1, (int)std::round(vh * ratio))),
             QImage::Format_RGB32);   // OPAQUE: alpha blending softens glyph edges
  img.setDevicePixelRatio(ratio);
  img.fill(toQ(defBg_));   // the bg is repainted below; this seeds an opaque surface
  QPainter localPainter(&img);
  QPainter *p = &localPainter;

  // Effective defaults (an app may have OSC-overridden fg/bg/cursor).
  GhosttyColorRgb fgD = defFg_, bgD = defBg_, curD = defCursor_;
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fgD);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bgD);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, &curD);
  const QColor defFg = toQ(fgD), defBg = toQ(bgD), curColor = toQ(curD);

  p->fillRect(QRectF(0, 0, vw, vh), defBg);

  uint16_t cx = 0, cy = 0;
  bool cvis = true;
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
  ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &cvis);

  // Two passes: fill EVERY background first, then draw glyphs on top. A glyph
  // can overhang its cell (wide Nerd icons horizontally, descenders vertically);
  // if a neighbor's background were filled after the glyph, it would clip that
  // overhang. Separating the passes lets overhangs survive.
  struct Glyph { qreal x, y; uint32_t cp; QColor fg; bool bold; };
  std::vector<Glyph> glyphs;
  // Run state for merged background fills (see the fill below).
  bool runActive = false; QColor runColor; int runRow = -1, runStartCol = 0, runEndCol = -1;
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

      const qreal x = padL_ + col * cellW_, y = padT_ + row * cellH_;
      // Backgrounds accumulate into RUNS instead of one rect per cell. Per-cell fills
      // leave a hairline seam wherever a cell edge lands off the device-pixel grid, which
      // is what striped the markdown heading blocks with vertical gaps. One rect per run
      // of identical colour has no interior edges to seam, and draws far less.
      if (effBg != defBg) {
        if (runActive && effBg == runColor && runRow == row && col == runEndCol + 1) {
          runEndCol = col;                       // extend
        } else {
          if (runActive)
            p->fillRect(padL_ + runStartCol * cellW_, padT_ + runRow * cellH_,
                        (runEndCol - runStartCol + 1) * cellW_, cellH_, runColor);
          runActive = true; runColor = effBg; runRow = row;
          runStartCol = col; runEndCol = col;
        }
      } else if (runActive) {
        p->fillRect(padL_ + runStartCol * cellW_, padT_ + runRow * cellH_,
                    (runEndCol - runStartCol + 1) * cellW_, cellH_, runColor);
        runActive = false;
      }

      if (has) {
        uint32_t cp = 0;
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
        glyphs.push_back({x, y, cp, fg, (bool)style.bold});
      }
    }
  }

  if (runActive)                                  // flush a run that ended at the last cell
    p->fillRect(padL_ + runStartCol * cellW_, padT_ + runRow * cellH_,
                (runEndCol - runStartCol + 1) * cellW_, cellH_, runColor);

  for (const Glyph &g : glyphs) {
    if (g.cp >= 0x2500 && g.cp <= 0x257F && drawBoxChar(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural box-drawing fills the cell; skip the glyph
    if (g.cp >= 0x2580 && g.cp <= 0x259F && drawBlockChar(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural block elements fill the cell; skip the glyph
    if (g.cp >= 0xE0B0 && g.cp <= 0xE0B7 && drawPowerline(p, g.x, g.y, g.cp, g.fg))
      continue;  // procedural powerline separators (smooth, seamless)
    // U+E000-U+E4FF = the QsIcons range (see the ctor); everything else uses the
    // text face. Mirrors kitty's symbol_map so the rail's icons match the editor's.
    const bool isIcon = g.cp >= 0xE000 && g.cp <= 0xE4FF;
    QFont f = isIcon ? iconFont_ : font_;
    if (!isIcon) f.setBold(g.bold);
    // Italics off entirely: the GeistMono italic face slants past the cell's
    // right edge and gets clipped, so render italic-attributed cells upright.
    p->setFont(f);
    p->setPen(g.fg);
    p->drawText(QPointF(g.x, g.y + ascent_),
                QString::fromUcs4(reinterpret_cast<const char32_t *>(&g.cp), 1));
  }

  // Cursor: honor the app's requested shape (nvim swaps block/beam by mode).
  if (cvis && active_.load() && cx < cols_ && cy < rows_) {   // hidden when the rail has focus
    const qreal x = padL_ + cx * cellW_, y = padT_ + cy * cellH_;
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
              p->drawText(QPointF(x, y + ascent_),
                          QString::fromUcs4(reinterpret_cast<const char32_t *>(&cp), 1));
            }
          }
        }
        break;
      }
    }
  }

  // Kitty graphics: blit stored image placements over the cells (dashboard
  // banner, image.nvim, etc.). Pixel data is borrowed from the terminal and
  // valid until the next mutating call — safe to read here inside paint().
  {
    GhosttyKittyGraphics kg = nullptr;
    if (ghostty_terminal_get(term_, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &kg) == GHOSTTY_SUCCESS && kg) {
      // Virtual (unicode-placeholder) placements carry no viewport geometry —
      // their cells live in the grid. Record imageId -> intended cell grid so
      // the placeholder scan below can slice the image into per-cell tiles.
      struct VGrid { uint32_t cols, rows; };
      std::unordered_map<uint32_t, VGrid> virtualPl;

      GhosttyKittyGraphicsPlacementIterator it = nullptr;
      if (ghostty_kitty_graphics_placement_iterator_new(nullptr, &it) == GHOSTTY_SUCCESS && it) {
        ghostty_kitty_graphics_get(kg, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &it);
        while (ghostty_kitty_graphics_placement_next(it)) {
          uint32_t imgId = 0;
          ghostty_kitty_graphics_placement_get(it, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imgId);
          GhosttyKittyGraphicsImage im = ghostty_kitty_graphics_image(kg, imgId);
          if (!im) continue;

          bool virt = false;
          ghostty_kitty_graphics_placement_get(it, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &virt);
          if (virt) {
            uint32_t vc = 0, vr = 0;
            ghostty_kitty_graphics_placement_get(it, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, &vc);
            ghostty_kitty_graphics_placement_get(it, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &vr);
            if (!vc || !vr)
              ghostty_kitty_graphics_placement_grid_size(it, im, term_, &vc, &vr);
            if (vc && vr) virtualPl[imgId] = {vc, vr};
            continue;
          }

          GhosttyKittyGraphicsPlacementRenderInfo ri = GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo);
          if (ghostty_kitty_graphics_placement_render_info(it, im, term_, &ri) != GHOSTTY_SUCCESS) continue;
          if (!ri.viewport_visible) continue;
          QImage srcImg = kittyImageView(im);
          if (srcImg.isNull()) continue;
          QRectF srcR(ri.source_x, ri.source_y, ri.source_width, ri.source_height);
          QRectF dstR(padL_ + (qreal)ri.viewport_col * cellW_,
                      padT_ + (qreal)ri.viewport_row * cellH_,
                      ri.pixel_width, ri.pixel_height);
          p->setRenderHint(QPainter::SmoothPixmapTransform, true);
          p->drawImage(dstR, srcImg, srcR);
        }
        ghostty_kitty_graphics_placement_iterator_free(it);
      }

      static const bool kittyDbg = qEnvironmentVariableIsSet("HEIDR_KITTY_DEBUG");
      if (kittyDbg) {
        fprintf(stderr, "[kitty] virtualPl=%zu", virtualPl.size());
        for (auto &kv : virtualPl) fprintf(stderr, " id=%u(%ux%u)", kv.first, kv.second.cols, kv.second.rows);
        fprintf(stderr, "\n");
      }
      int dbgPh = 0, dbgBlit = 0;

      // Unicode placeholders (snacks banner, image.nvim): scan the visible grid
      // for U+10EEEE cells, decode the image cell (row,col) from the combining
      // diacritics and the image id from the fg colour, blit the matching tile.
      if (!virtualPl.empty()) {
        p->setRenderHint(QPainter::SmoothPixmapTransform, true);
        for (uint16_t row = 0; row < rows_; ++row) {
          int prevRow = 0, prevCol = -1;   // kitty auto-increment, reset per grid row
          for (uint16_t col = 0; col < cols_; ++col) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt; pt.tag = GHOSTTY_POINT_TAG_ACTIVE;
            pt.value.coordinate.x = col; pt.value.coordinate.y = row;
            if (ghostty_terminal_grid_ref(term_, pt, &ref) != GHOSTTY_SUCCESS) { prevCol = -1; continue; }

            uint32_t g[16]; size_t gn = 0;
            if (ghostty_grid_ref_graphemes(&ref, g, 16, &gn) != GHOSTTY_SUCCESS || gn == 0 ||
                g[0] != 0x10EEEEu) { prevCol = -1; continue; }
            dbgPh++;

            int imgRow = -1, imgCol = -1, idHigh = -1, di = 0;
            for (size_t k = 1; k < gn; ++k) {
              int v = kittyDiacriticIndex(g[k]);
              if (v < 0) continue;
              if (di == 0) imgRow = v; else if (di == 1) imgCol = v; else if (di == 2) idHigh = v;
              di++;
            }
            if (imgRow < 0) imgRow = prevRow;
            if (imgCol < 0) imgCol = prevCol + 1;
            prevRow = imgRow; prevCol = imgCol;

            GhosttyStyle st = GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_grid_ref_style(&ref, &st);
            uint32_t id = 0;
            if (st.fg_color.tag == GHOSTTY_STYLE_COLOR_RGB)
              id = ((uint32_t)st.fg_color.value.rgb.r << 16) |
                   ((uint32_t)st.fg_color.value.rgb.g << 8) |
                    (uint32_t)st.fg_color.value.rgb.b;
            else if (st.fg_color.tag == GHOSTTY_STYLE_COLOR_PALETTE)
              id = st.fg_color.value.palette;
            if (idHigh > 0) id |= ((uint32_t)idHigh << 24);

            auto vit = virtualPl.find(id);
            if (vit == virtualPl.end()) continue;
            GhosttyKittyGraphicsImage im = ghostty_kitty_graphics_image(kg, id);
            if (!im) continue;
            QImage srcImg = kittyImageView(im);
            if (srcImg.isNull()) continue;
            const uint32_t nc = vit->second.cols, nr = vit->second.rows;
            if (!nc || !nr || (uint32_t)imgCol >= nc || (uint32_t)imgRow >= nr) continue;
            const qreal sw = (qreal)srcImg.width() / nc, sh = (qreal)srcImg.height() / nr;
            QRectF srcR(imgCol * sw, imgRow * sh, sw, sh);
            QRectF dstR(padL_ + (qreal)col * cellW_, padT_ + (qreal)row * cellH_, cellW_, cellH_);
            p->drawImage(dstR, srcImg, srcR);
            dbgBlit++;
          }
        }
      }
      if (kittyDbg && (dbgPh || !virtualPl.empty()))
        fprintf(stderr, "[kitty] placeholders=%d blitted=%d\n", dbgPh, dbgBlit);
    }
  }

  localPainter.end();
  return img;
}

void TermView::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickPaintedItem::itemChange(change, data);
  if (change != ItemSceneChange || !data.window) return;
  auto publish = [this] {
    if (!window()) return;
    const qreal r = window()->effectiveDevicePixelRatio();
    if (r > 0 && std::abs(r - guiDpr_) > 0.001) { guiDpr_ = r; emit dprChanged(); }
  };
  publish();
  // Follow the window across monitors: a different screen means a different ratio, and
  // the size has to re-snap for the mapping to stay 1:1.
  connect(data.window, &QQuickWindow::screenChanged, this, publish);
  connect(data.window, &QWindow::screenChanged, this, publish);
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
  if (!out.isEmpty()) enqueuePty(out);
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
