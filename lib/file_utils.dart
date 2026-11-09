import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

/// 把文件夹打成 zip 放到临时目录，压缩在后台 isolate 跑，不卡 UI。
Future<File> zipDirectory(String directoryPath) async {
  final tmp = await getTemporaryDirectory();
  final trimmed = directoryPath.replaceAll(RegExp(r'[/\\]+$'), '');
  final name = trimmed.split(RegExp(r'[/\\]')).last;
  final outDir = Directory('${tmp.path}/near_zip_${DateTime.now().microsecondsSinceEpoch}');
  await outDir.create(recursive: true);
  final outPath = '${outDir.path}/$name.zip';
  await Isolate.run(() async {
    final encoder = ZipFileEncoder();
    encoder.create(outPath);
    await encoder.addDirectory(Directory(trimmed), includeDirName: true);
    await encoder.close();
  });
  return File(outPath);
}
