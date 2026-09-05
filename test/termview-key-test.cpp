#include "TermView.h"

#include <QFile>
#include <QKeyEvent>
#include <QTemporaryDir>
#include <QtTest>

class TermViewKeyTest : public QObject {
  Q_OBJECT

private slots:
  void shiftedTextKeepsShiftInKittyReportAll();
};

void TermViewKeyTest::shiftedTextKeepsShiftInKittyReportAll() {
  QTemporaryDir dir;
  QVERIFY(dir.isValid());
  const QString output = dir.filePath("pty-bytes");
  const QByteArray command = "stty raw -echo; printf '\033[>8u'; dd bs=1 count=7 of='"
                           + output.toUtf8() + "' 2>/dev/null; sleep 1";
  qputenv("COCKPIT_COCKPIT_CMD", command);

  TermView view;
  QTest::qWait(200);
  QKeyEvent event(QEvent::KeyPress, Qt::Key_A, Qt::ShiftModifier, QStringLiteral("A"));
  QCoreApplication::sendEvent(&view, &event);

  QTRY_VERIFY_WITH_TIMEOUT(QFile(output).size() >= 7, 2000);
  QFile file(output);
  QVERIFY(file.open(QIODevice::ReadOnly));
  QCOMPARE(file.readAll(), QByteArray("\x1b[97;2u", 7));
}

QTEST_MAIN(TermViewKeyTest)
#include "termview-key-test.moc"
