#include "ProseStyle.h"

#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>

void ProseStyle::apply(QQuickTextDocument *document, const QString &boldFamily) {
  auto *doc = document->textDocument();
  const int size = doc->defaultFont().pixelSize();
  const int bodyLeading = qRound(size * 1.5);
  doc->setIndentWidth(bodyLeading);
  QTextCursor cursor(doc);
  bool changed = false;
  for (auto block = doc->begin(); block.isValid(); block = block.next()) {
    auto format = block.blockFormat();
    const bool heading = format.headingLevel() > 0;
    const int leading = heading ? 120 : bodyLeading;
    const auto heightType = heading ? QTextBlockFormat::ProportionalHeight : QTextBlockFormat::FixedHeight;
    const int top = heading && block.previous().isValid() ? bodyLeading : 0;
    const int bottom = !block.next().isValid() ? 0 : (heading ? qRound(size * 0.5)
      : (block.textList() && block.next().textList() == block.textList() ? qRound(size * 0.25) : bodyLeading));
    if (format.lineHeightType() == heightType
        && format.lineHeight() == leading && format.topMargin() == top
        && format.bottomMargin() == bottom) continue;
    if (!changed) { cursor.beginEditBlock(); changed = true; }
    format.setLineHeight(leading, heightType);
    format.setTopMargin(top);
    format.setBottomMargin(bottom);
    cursor.setPosition(block.position());
    cursor.setBlockFormat(format);
  }
  if (!boldFamily.isEmpty()) {
    QList<QTextCursor> emphasis;
    for (auto block = doc->begin(); block.isValid(); block = block.next()) {
      for (auto it = block.begin(); !it.atEnd(); ++it) {
        const auto fragment = it.fragment();
        const auto format = fragment.charFormat();
        if (format.fontWeight() < QFont::Bold || format.fontFixedPitch()
            || format.property(QTextFormat::FontFamilies).toStringList() == QStringList{boldFamily}) continue;
        QTextCursor range(doc);
        range.setPosition(fragment.position());
        range.setPosition(fragment.position() + fragment.length(), QTextCursor::KeepAnchor);
        emphasis.append(range);
      }
    }
    if (!emphasis.isEmpty()) {
      if (!changed) { cursor.beginEditBlock(); changed = true; }
      QTextCharFormat format;
      format.setFontFamilies({boldFamily});
      for (auto &range : emphasis) range.mergeCharFormat(format);
    }
  }
  if (changed) cursor.endEditBlock();
}
