/*
 * SPDX-FileCopyrightText: 2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:dart_git/blob_ctime_builder.dart';
import 'package:dart_git/dart_git.dart';
import 'package:dart_git/file_mtime_builder.dart';
import 'package:dart_git/utils/date_time.dart';
import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart' as io;

import 'package:gitjournal/core/file/file.dart';
import 'package:gitjournal/core/file/file_storage.dart';
import 'package:gitjournal/generated/builders.pb.dart' as pb;
import 'package:gitjournal/logger/logger.dart';

class FileStorageCache {
  final String cacheFolderPath;
  var lastProcessedHead = GitHash.zero();

  FileStorageCache(this.cacheFolderPath) {
    assert(cacheFolderPath.startsWith(p.separator));
  }

  Future<void> clear() async {
    try {
      dynamic _;
      _ = await io.File(_cTimeFilePath).delete(recursive: true);
      _ = await io.File(_mTimeFilePath).delete(recursive: true);
    } on io.FileSystemException catch (err, st) {
      if (err.osError?.errorCode == 2 /* File Not Found */) {
        return;
      }
      Log.e("Failed to clear FileStorageCache osError",
          ex: err, stacktrace: st);
    } catch (err, st) {
      Log.e("Failed to clear FileStorageCache", ex: err, stacktrace: st);
    }
  }

  Future<FileStorage> load(GitRepository gitRepo) async {
    var blobVisitorTuple = await _buildCTimeBuilder();
    var mTimeBuilderTuple = await _buildMTimeBuilder();

    lastProcessedHead = blobVisitorTuple.item2;
    if (mTimeBuilderTuple.item2 != lastProcessedHead) {
      lastProcessedHead = GitHash.zero();
    }

    return FileStorage(
      gitRepo: gitRepo,
      blobCTimeBuilder: blobVisitorTuple.item1,
      fileMTimeBuilder: mTimeBuilderTuple.item1,
    );
  }

  Future<Result<void>> save(FileStorage fileStorage) async {
    return catchAll(() async {
      var headR = await fileStorage.gitRepo.headHash();
      lastProcessedHead = headR.isFailure ? GitHash.zero() : headR.getOrThrow();

      await _saveCTime(fileStorage.blobCTimeBuilder);
      await _saveMTime(fileStorage.fileMTimeBuilder);
      return Result(null);
    });
  }

  String get _cTimeFilePath => p.join(cacheFolderPath, 'blob_ctime_v1');
  String get _mTimeFilePath => p.join(cacheFolderPath, 'file_mtime_v1');

  Future<Tuple2<BlobCTimeBuilder, GitHash>> _buildCTimeBuilder() async {
    var file = io.File(_cTimeFilePath);

    var stat = file.statSync();
    if (stat.type == io.FileSystemEntityType.notFound) {
      return Tuple2(BlobCTimeBuilder(), GitHash.zero());
    }

    var size = (stat.size / 1024).toStringAsFixed(2);
    Log.d("BlobCTimeBuilder Cache Size: $size Kb");

    var buffer = await file.readAsBytes();
    var data = pb.BlobCTimeBuilderData.fromBuffer(buffer);

    var commitHashes =
        data.commitHashes.map((bytes) => GitHash.fromBytes(bytes)).toSet();

    var treeHashes =
        data.treeHashes.map((bytes) => GitHash.fromBytes(bytes)).toSet();

    var map = data.map
        .map((hashStr, pbDt) => MapEntry(GitHash(hashStr), _fromProto(pbDt)));

    var builder = BlobCTimeBuilder(
      processedCommits: commitHashes,
      processedTrees: treeHashes,
      map: map,
    );
    return Tuple2(builder, GitHash.fromBytes(data.headHash));
  }

  Future<Tuple2<FileMTimeBuilder, GitHash>> _buildMTimeBuilder() async {
    var file = io.File(_mTimeFilePath);

    var stat = file.statSync();
    if (stat.type == io.FileSystemEntityType.notFound) {
      return Tuple2(FileMTimeBuilder(), GitHash.zero());
    }

    var size = (stat.size / 1024).toStringAsFixed(2);
    Log.d("FileMTimeBuilder Cache Size: $size Kb");

    var buffer = await file.readAsBytes();
    var data = pb.FileMTimeBuilderData.fromBuffer(buffer);

    var commitHashes =
        data.commitHashes.map((bytes) => GitHash.fromBytes(bytes)).toSet();

    var map = data.map.map((filePath, pbInfo) {
      var hash = GitHash.fromBytes(pbInfo.hash);
      var dt = _fromProto(pbInfo.dt);
      var info = FileMTimeInfo(pbInfo.filePath, hash, dt);

      return MapEntry(filePath, info);
    });

    var builder = FileMTimeBuilder(processedCommits: commitHashes, map: map);
    return Tuple2(builder, GitHash.fromBytes(data.headHash));
  }

  Future<void> _saveCTime(BlobCTimeBuilder builder) async {
    var commitHashes = builder.processedCommits.map((bytes) => bytes.bytes);
    var treeHashes = builder.processedTrees.map((bytes) => bytes.bytes);
    var map = builder.map.map((hash, dt) {
      var pbDt = pb.TzDateTime(
        offset: dt.offset.inSeconds,
        timestamp: Int64(dt.secondsSinceEpoch),
      );
      return MapEntry(hash.toString(), pbDt);
    });

    var data = pb.BlobCTimeBuilderData(
      headHash: lastProcessedHead.bytes,
      commitHashes: commitHashes,
      treeHashes: treeHashes,
      map: map,
    );

    var file = io.File(_cTimeFilePath);
    var _ = await file.writeAsBytes(data.writeToBuffer());
  }

  Future<void> _saveMTime(FileMTimeBuilder builder) async {
    var commitHashes = builder.processedCommits.map((bytes) => bytes.bytes);
    var map = builder.map.map((filePath, data) {
      var pbDt = pb.TzDateTime(
        offset: data.dt.offset.inSeconds,
        timestamp: Int64(data.dt.secondsSinceEpoch),
      );

      var info = pb.FileMTimeInfo(
        dt: pbDt,
        hash: data.hash.bytes,
        filePath: filePath,
      );

      return MapEntry(filePath, info);
    });

    var data = pb.FileMTimeBuilderData(
      headHash: lastProcessedHead.bytes,
      commitHashes: commitHashes,
      map: map,
    );

    var file = io.File(_mTimeFilePath);
    var _ = await file.writeAsBytes(data.writeToBuffer());
  }
}

GDateTime _fromProto(pb.TzDateTime dt) {
  var offset = Duration(seconds: dt.offset);
  return GDateTime.fromTimeStamp(offset, dt.timestamp.toInt());
}
