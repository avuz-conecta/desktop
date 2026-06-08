/*
 * This software is in the public domain, furnished "as is", without technical
 * support, and with no warranty, express or implied, as to its usefulness for
 * any purpose.
 */
#include <QtTest>
#include "syncenginetestutils.h"
#include "syncengine.h"

using namespace OCC;

namespace {

void setBatchSize(FakeFolder &fake, int batchSize)
{
    auto options = fake.syncEngine().syncOptions();
    options._discoveryBatchSize = batchSize;
    fake.syncEngine().setSyncOptions(options);
}

void fillBigDir(FileInfo &root, int count)
{
    root.mkdir("big");
    for (int i = 0; i < count; ++i) {
        root.insert(QStringLiteral("big/file%1.bin").arg(i, 6, 10, QLatin1Char('0')), 10);
    }
}

int bigChildCount(FakeFolder &fake)
{
    auto state = fake.currentLocalState();
    auto *big = state.find(QStringLiteral("big"));
    return big ? static_cast<int>(big->children.size()) : 0;
}

// Run syncs until none is requested, capped so a non-converging implementation
// fails loudly instead of hanging the test.
int syncUntilDone(FakeFolder &fake, int maxSyncs = 60)
{
    int runs = 0;
    do {
        ++runs;
        fake.syncOnce();
    } while (fake.syncEngine().isAnotherSyncNeeded() != NoFollowUpSync && runs < maxSyncs);
    return runs;
}
}

class TestBatchedDiscovery : public QObject
{
    Q_OBJECT

private slots:
    // A dir larger than the batch limit must stop one pass early and ask for more.
    void singlePassStopsAtBatchLimit()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        setBatchSize(fake, 10);

        fake.syncOnce();

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), ImmediateFollowUp);
        QVERIFY2(bigChildCount(fake) < 25, "first pass should not have collected the whole dir");
    }

    // Follow-ups must converge and end with the full tree synced, nothing lost.
    void convergesAndSyncsEverything()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        setBatchSize(fake, 10);

        const int runs = syncUntilDone(fake);

        QVERIFY2(runs < 60, "sync did not converge (infinite follow-up loop)");
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // Each batch must make forward progress, else it would loop forever.
    void eachBatchMakesProgress()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        setBatchSize(fake, 10);

        fake.syncOnce();
        const int afterFirst = bigChildCount(fake);
        fake.syncOnce();
        const int afterSecond = bigChildCount(fake);

        QVERIFY2(afterSecond > afterFirst, "follow-up made no progress (would loop forever)");
    }

    // The real-world shape: a large dir nested under another dir
    // (e.g. train2017/train2017/*.jpg). Ancestors must be created too.
    void convergesWithNestedDir()
    {
        FakeFolder fake{ FileInfo{} };
        fake.remoteModifier().mkdir("outer");
        fake.remoteModifier().mkdir("outer/inner");
        for (int i = 0; i < 25; ++i) {
            fake.remoteModifier().insert(
                QStringLiteral("outer/inner/file%1.bin").arg(i, 6, 10, QLatin1Char('0')), 10);
        }
        setBatchSize(fake, 10);

        int runs = 0;
        do {
            ++runs;
            fake.syncOnce();
        } while (fake.syncEngine().isAnotherSyncNeeded() != NoFollowUpSync && runs < 60);

        QVERIFY2(runs < 60, "nested sync did not converge");
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // Disabled (0) behaves like upstream: one pass, no follow-up.
    void disabledByZeroDoesOneShot()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        setBatchSize(fake, 0);

        fake.syncOnce();

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), NoFollowUpSync);
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }
};

QTEST_GUILESS_MAIN(TestBatchedDiscovery)
#include "testbatcheddiscovery.moc"
