/*
 * SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "bulkpropagatordownloadjob.h"

#include "syncfileitem.h"
#include "syncengine.h"
#include "common/syncjournaldb.h"
#include "common/syncjournalfilerecord.h"
#include "propagatorjobs.h"
#include "filesystem.h"
#include "account.h"
#include "propagatedownloadencrypted.h"

#include <QDir>
#include <QTimer>

namespace OCC {

Q_LOGGING_CATEGORY(lcBulkPropagatorDownloadJob, "nextcloud.sync.propagator.bulkdownload", QtInfoMsg)

BulkPropagatorDownloadJob::BulkPropagatorDownloadJob(OwncloudPropagator *propagator,
                                                     PropagateDirectory *parentDirJob)
    : PropagatorJob{propagator}
    , _filesToDownload{}
    , _parentDirJob{parentDirJob}
{
}

namespace
{
static QString makeBulkDownloadRecallFileName(const QString &fn)
{
    auto recallFileName(fn);
    // Add _recall-XXXX  before the extension.
    auto dotLocation = recallFileName.lastIndexOf('.');
    // If no extension, add it at the end  (take care of cases like foo/.hidden or foo.bar/file)
    if (dotLocation <= recallFileName.lastIndexOf('/') + 1) {
        dotLocation = recallFileName.size();
    }

    const auto &timeString = QDateTime::currentDateTimeUtc().toString("yyyyMMdd-hhmmss");
    recallFileName.insert(dotLocation, "_.sys.admin#recall#-" + timeString);

    return recallFileName;
}

void handleBulkDownloadRecallFile(const QString &filePath, const QString &folderPath, SyncJournalDb &journal)
{
    qCDebug(lcBulkPropagatorDownloadJob) << "handleBulkDownloadRecallFile: " << filePath;

    FileSystem::setFileHidden(filePath, true);

    auto file = QFile{filePath};
    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(lcBulkPropagatorDownloadJob) << "Could not open recall file" << file.errorString();
        return;
    }
    const auto existingFile = QFileInfo{filePath};
    const auto &baseDir = existingFile.dir();

    while (!file.atEnd()) {
        auto line = file.readLine();
        line.chop(1); // remove trailing \n

        const auto &recalledFile = QDir::cleanPath(baseDir.filePath(line));
        if (!recalledFile.startsWith(folderPath) || !recalledFile.startsWith(baseDir.path())) {
            qCWarning(lcBulkPropagatorDownloadJob) << "Ignoring recall of " << recalledFile;
            continue;
        }

        // Path of the recalled file in the local folder
        const auto &localRecalledFile = recalledFile.mid(folderPath.size());

        auto record = SyncJournalFileRecord{};
        if (!journal.getFileRecord(localRecalledFile, &record) || !record.isValid()) {
            qCWarning(lcBulkPropagatorDownloadJob) << "No db entry for recall of" << localRecalledFile;
            continue;
        }

        qCInfo(lcBulkPropagatorDownloadJob) << "Recalling" << localRecalledFile << "Checksum:" << record._checksumHeader;

        const auto &targetPath = makeBulkDownloadRecallFileName(recalledFile);

        qCDebug(lcBulkPropagatorDownloadJob) << "Copy recall file: " << recalledFile << " -> " << targetPath;
        // Remove the target first, QFile::copy will not overwrite it.
        FileSystem::remove(targetPath);
        QFile::copy(recalledFile, targetPath);
    }
}
}

void BulkPropagatorDownloadJob::addDownloadItem(const SyncFileItemPtr &item)
{
    Q_ASSERT(item->isDirectory() || item->_type == ItemTypeVirtualFileDehydration || item->_type == ItemTypeVirtualFile);
    if (item->isDirectory() || (item->_type != ItemTypeVirtualFileDehydration && item->_type != ItemTypeVirtualFile)) {
        qCWarning(lcBulkPropagatorDownloadJob) << "Failed to process bulk download for a non-virtual file" << item->_originalFile;
        return;
    }
    _filesToDownload.push_back(item);
}

bool BulkPropagatorDownloadJob::scheduleSelfOrChild()
{
    if (_state == Running || _state == Finished) {
        return false; // already processing; chunks run asynchronously
    }
    if (_filesToDownload.empty()) {
        return false;
    }

    _state = Running;
    start();
    return false;
}

PropagatorJob::JobParallelism BulkPropagatorDownloadJob::parallelism() const
{
    return PropagatorJob::JobParallelism::FullParallelism;
}

void BulkPropagatorDownloadJob::finalizeOneFile(const SyncFileItemPtr &file)
{
    emit propagator()->itemCompleted(file, ErrorCategory::GenericError);
}

void BulkPropagatorDownloadJob::start()
{
    if (propagator()->_abortRequested) {
        abortWithError({}, SyncFileItem::NormalError, {});
        return;
    }

    const auto &vfs = propagator()->syncOptions()._vfs;
    Q_ASSERT(vfs && vfs->mode() == Vfs::WindowsCfApi);

    _nextFileToProcess = 0;
    processChunk();
}

void BulkPropagatorDownloadJob::processChunk()
{
    if (propagator()->_abortRequested) {
        abortWithError({}, SyncFileItem::NormalError, {});
        return;
    }

    const auto &vfs = propagator()->syncOptions()._vfs;
    Q_ASSERT(vfs && vfs->mode() == Vfs::WindowsCfApi);

    // Process a bounded chunk and yield to the event loop between chunks. Creating
    // every placeholder + metadata for 100k+ files in one synchronous pass froze
    // the GUI thread; chunking lets the UI repaint while the bulk job runs. Kept
    // small so each synchronous burst stays short (smoother GUI).
    constexpr auto chunkSize = 250;
    const auto total = _filesToDownload.size();
    const auto end = qMin(_nextFileToProcess + chunkSize, total);

    QList<SyncFileItemPtr> chunk;
    chunk.reserve(end - _nextFileToProcess);
    for (auto i = _nextFileToProcess; i < end; ++i) {
        const auto &fileToDownload = _filesToDownload.at(i);
        Q_ASSERT(fileToDownload->_type == ItemTypeVirtualFile);

        if (propagator()->localFileNameClash(fileToDownload->_file)) {
            fileToDownload->_status = SyncFileItem::FileNameClash;
            finalizeOneFile(fileToDownload);
            qCWarning(lcBulkPropagatorDownloadJob) << "File" << QDir::toNativeSeparators(fileToDownload->_file) << "can not be downloaded because of a local file name clash!";
            abortWithError(fileToDownload, SyncFileItem::FileNameClash, tr("File %1 can not be downloaded because of a local file name clash!").arg(QDir::toNativeSeparators(fileToDownload->_file)));
            return;
        }
        chunk.push_back(fileToDownload);
    }

    const auto r = vfs->createPlaceholders(chunk);
    if (!r) {
        qCCritical(lcBulkPropagatorDownloadJob) << "Could not create placholders:" << r.error();
        for (const auto &fileToDownload : std::as_const(chunk)) {
            fileToDownload->_status = SyncFileItem::NormalError;
            finalizeOneFile(fileToDownload);
        }
        abortWithError({}, SyncFileItem::NormalError, r.error());
        return;
    }

    for (const auto &fileToDownload : std::as_const(chunk)) {
        if (!updateMetadata(fileToDownload)) {
            // updateMetadata() already calls abortWithError() on failure.
            return;
        }

        if (!fileToDownload->_remotePerm.isNull() && !fileToDownload->_remotePerm.hasPermission(RemotePermissions::CanWrite)) {
            // make sure ReadOnly flag is preserved for placeholder, similarly to regular files
            FileSystem::setFileReadOnly(propagator()->fullLocalPath(fileToDownload->_file), true);
        }
        fileToDownload->_status = SyncFileItem::Success;
        finalizeOneFile(fileToDownload);
    }

    _nextFileToProcess = end;
    if (_nextFileToProcess < total) {
        QTimer::singleShot(0, this, &BulkPropagatorDownloadJob::processChunk);
    } else {
        _filesToDownload.clear();
        done(SyncFileItem::Success);
    }
}

bool BulkPropagatorDownloadJob::updateMetadata(const SyncFileItemPtr &item)
{
    const auto fullFileName = propagator()->fullLocalPath(item->_file);
    const auto updateMetadataFlags = Vfs::UpdateMetadataTypes{Vfs::UpdateMetadataType::AllMetadata};
    const auto result = propagator()->updateMetadata(*item, updateMetadataFlags);
    if (!result) {
        abortWithError(item, SyncFileItem::FatalError, tr("Error updating metadata: %1").arg(result.error()));
        return false;
    } else if (*result == Vfs::ConvertToPlaceholderResult::Locked) {
        abortWithError(item, SyncFileItem::SoftError, tr("The file %1 is currently in use").arg(item->_file));
        return false;
    }

    // Throttle: an fsync commit per file freezes the UI on 100k+ file syncs.
    propagator()->_journal->commitIfTimeoutReached("download file start2");

    // handle the special recall file
    if (!item->_remotePerm.hasPermission(RemotePermissions::IsShared)
        && (item->_file == QLatin1String(".sys.admin#recall#") || item->_file.endsWith(QLatin1String("/.sys.admin#recall#")))) {
        handleBulkDownloadRecallFile(fullFileName, propagator()->localPath(), *propagator()->_journal);
    }

    const auto isLockOwnedByCurrentUser = item->_lockOwnerId == propagator()->account()->davUser();

    const auto isUserLockOwnedByCurrentUser = (item->_lockOwnerType == SyncFileItem::LockOwnerType::UserLock && isLockOwnedByCurrentUser);
    const auto isTokenLockOwnedByCurrentUser = (item->_lockOwnerType == SyncFileItem::LockOwnerType::TokenLock && isLockOwnedByCurrentUser);

    if (item->_locked == SyncFileItem::LockStatus::LockedItem && !isUserLockOwnedByCurrentUser && !isTokenLockOwnedByCurrentUser) {
        qCDebug(lcBulkPropagatorDownloadJob()) << fullFileName << "file is locked: making it read only";
        FileSystem::setFileReadOnly(fullFileName, true);
    } else {
        qCDebug(lcBulkPropagatorDownloadJob()) << fullFileName << "file is not locked: making it" << ((!item->_remotePerm.isNull() && !item->_remotePerm.hasPermission(RemotePermissions::CanWrite))
            ? "read only"
            : "read write");
        FileSystem::setFileReadOnlyWeak(fullFileName, (!item->_remotePerm.isNull() && !item->_remotePerm.hasPermission(RemotePermissions::CanWrite)));
    }
    return true;
}

void BulkPropagatorDownloadJob::done(const SyncFileItem::Status status)
{
    _state = Finished;
    emit finished(status);
}

void BulkPropagatorDownloadJob::abortWithError(SyncFileItemPtr item, SyncFileItem::Status status, const QString &error)
{
    qCInfo(lcBulkPropagatorDownloadJob) << "finished with status" << status << error;
    abort(AbortType::Synchronous);
    if (item) {
        item->_errorString = error;
        item->_status = status;
        emit propagator()->itemCompleted(item, ErrorCategory::GenericError);
    }
    done(status);
}

}
