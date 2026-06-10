/*
 * This software is in the public domain, furnished "as is", without technical
 * support, and with no warranty, express or implied, as to its usefulness for
 * any purpose.
 */
#include <QtTest>
#include "gui/tray/syncstatussummary.h"

using namespace OCC;

class TestSyncStatusSummary : public QObject
{
    Q_OBJECT

private slots:
    void notLargeWhenBelowThreshold()
    {
        SyncStatusSummary summary;
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(10);
        QVERIFY(!summary.largeSyncInProgress());
    }

    void largeWhenSyncingAndAboveThreshold()
    {
        SyncStatusSummary summary;
        QSignalSpy spy(&summary, &SyncStatusSummary::largeSyncInProgressChanged);
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(20001);
        QVERIFY(summary.largeSyncInProgress());
        QCOMPARE(spy.count(), 1); // emitted exactly once on the transition
    }

    void notLargeWhenNotSyncingEvenIfManyFiles()
    {
        SyncStatusSummary summary;
        summary.setTotalFilesForTesting(50000);
        summary.setSyncingForTesting(false);
        QVERIFY(!summary.largeSyncInProgress());
    }

    void clearsWhenSyncStops()
    {
        SyncStatusSummary summary;
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(30000);
        QVERIFY(summary.largeSyncInProgress());
        summary.setSyncingForTesting(false);
        QVERIFY(!summary.largeSyncInProgress());
    }
};

QTEST_GUILESS_MAIN(TestSyncStatusSummary)
#include "testsyncstatussummary.moc"
