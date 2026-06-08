/*
 * This software is in the public domain, furnished "as is", without technical
 * support, and with no warranty, express or implied, as to its usefulness for
 * any purpose.
 *
 * Discovery of a very large flat directory is processed in chunks that yield to
 * the event loop (so the GUI stays responsive), but it remains a single
 * discovery pass. These tests pin that behaviour: small chunk sizes must still
 * produce a complete, correct sync in one pass with no follow-up.
 */
#include <QtTest>
#include "syncenginetestutils.h"
#include "syncengine.h"

using namespace OCC;

namespace {

// Set how many entries discovery processes per event-loop turn before yielding.
void setDiscoveryChunkSize(FakeFolder &fake, int chunkSize)
{
    auto options = fake.syncEngine().syncOptions();
    options._discoveryBatchSize = chunkSize;
    fake.syncEngine().setSyncOptions(options);
}

void fillDir(FileInfo &root, const QString &dir, int count)
{
    root.mkdir(dir);
    for (int i = 0; i < count; ++i) {
        root.insert(QStringLiteral("%1/file%2.bin").arg(dir).arg(i, 6, 10, QLatin1Char('0')), 10);
    }
}
}

class TestBatchedDiscovery : public QObject
{
    Q_OBJECT

private slots:
    // A flat dir much larger than the chunk size must fully sync in ONE pass,
    // with discovery yielding internally but no follow-up requested.
    void syncsLargeFlatDirInOnePass()
    {
        FakeFolder fake{ FileInfo{} };
        fillDir(fake.remoteModifier(), QStringLiteral("big"), 200);
        setDiscoveryChunkSize(fake, 10); // forces ~20 yield chunks

        QVERIFY(fake.syncOnce());

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), NoFollowUpSync);
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // The real-world shape: a large dir nested under another (train2017/train2017).
    void syncsNestedLargeDir()
    {
        FakeFolder fake{ FileInfo{} };
        fake.remoteModifier().mkdir("outer");
        fillDir(fake.remoteModifier(), QStringLiteral("outer/inner"), 200);
        setDiscoveryChunkSize(fake, 10);

        QVERIFY(fake.syncOnce());

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), NoFollowUpSync);
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // Extreme yielding (one entry per turn) must still complete correctly.
    void chunkSizeOneStillCompletes()
    {
        FakeFolder fake{ FileInfo{} };
        fillDir(fake.remoteModifier(), QStringLiteral("big"), 50);
        setDiscoveryChunkSize(fake, 1);

        QVERIFY(fake.syncOnce());

        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // Incremental change after the initial sync still works (no regression).
    void incrementalChangeAfterLargeSync()
    {
        FakeFolder fake{ FileInfo{} };
        fillDir(fake.remoteModifier(), QStringLiteral("big"), 100);
        setDiscoveryChunkSize(fake, 10);
        QVERIFY(fake.syncOnce());

        fake.remoteModifier().insert(QStringLiteral("big/added.bin"), 10);
        QVERIFY(fake.syncOnce());

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), NoFollowUpSync);
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }
};

QTEST_GUILESS_MAIN(TestBatchedDiscovery)
#include "testbatcheddiscovery.moc"
