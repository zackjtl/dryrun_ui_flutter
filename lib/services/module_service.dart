import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/part_number.dart';

class ModuleData {
  final List<PartNumber> partNumbers;
  final int? ctype;

  const ModuleData({required this.partNumbers, required this.ctype});
}

class ModuleService {
  static String get _exeDir {
    return File(Platform.resolvedExecutable).parent.path;
  }

  static String get modulesDirPath => p.join(_exeDir, 'Modules');

  static List<String> _splitPartNumbers(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return const [''];
    final parts = value
        .split('_')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? const [''] : parts;
  }

  static Future<List<String>> listModules() async {
    final modulesDir = Directory(modulesDirPath);
    if (!await modulesDir.exists()) {
      return [];
    }

    final dirs = await modulesDir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.uri.pathSegments.reversed.skip(1).first)
        .toList();

    dirs.sort();
    return dirs;
  }

  static Future<bool> isModulesDirMissingOrEmpty() async {
    final modulesDir = Directory(modulesDirPath);
    if (!await modulesDir.exists()) return true;
    final entities = await modulesDir.list().toList();
    return entities.isEmpty;
  }

  static Future<void> copyModulesFrom(String sourceModulesDirPath) async {
    final sourceDir = Directory(sourceModulesDirPath);
    if (!await sourceDir.exists()) {
      throw Exception('Source Modules folder not found: $sourceModulesDirPath');
    }

    final destDir = Directory(modulesDirPath);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    Future<void> copyEntity(FileSystemEntity entity, String destRoot) async {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        final newDestDir = Directory(p.join(destRoot, name));
        if (!await newDestDir.exists()) {
          await newDestDir.create(recursive: true);
        }
        await for (final child in entity.list(followLinks: false)) {
          await copyEntity(child, newDestDir.path);
        }
        return;
      }

      if (entity is File) {
        final name = p.basename(entity.path);
        final destPath = p.join(destRoot, name);
        final destFile = File(destPath);
        if (await destFile.exists()) {
          await destFile.delete();
        }
        await entity.copy(destPath);
        return;
      }

      if (entity is Link) {
        final resolved = await entity.target();
        final targetEntity = FileSystemEntity.typeSync(resolved) ==
                FileSystemEntityType.directory
            ? Directory(resolved)
            : File(resolved);
        await copyEntity(targetEntity, destRoot);
      }
    }

    await for (final entity in sourceDir.list(followLinks: false)) {
      await copyEntity(entity, destDir.path);
    }
  }

  static Future<List<PartNumber>> loadPartNumbers(String module) async {
    final data = await loadModuleData(module);
    return data.partNumbers;
  }

  static Future<ModuleData> loadModuleData(String module) async {
    final indexFile =
        File(p.join(modulesDirPath, module, 'JSON', 'index.json'));
    if (!await indexFile.exists()) {
      return const ModuleData(partNumbers: [], ctype: null);
    }

    final content = await indexFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    final flashIds = data['flash_ids'] as List<dynamic>? ?? [];
    final ctypeRaw = data['ctype'];
    final int? ctype = ctypeRaw is int
        ? ctypeRaw
        : (ctypeRaw is String ? int.tryParse(ctypeRaw) : null);

    final results = <PartNumber>[];

    for (final entry in flashIds) {
      final flashIdRaw = entry['flash_id'] as String? ?? '';
      final vendor = entry['vendor'] as String? ?? '';
      final fileName = '${flashIdRaw.replaceAll(' ', '_')}.json';
      final detailFile = File(p.join(modulesDirPath, module, 'JSON', fileName));

      String partNumber = '';
      String die = '';
      String cellType = '';
      String plane = '';
      String alias = '';

      if (await detailFile.exists()) {
        try {
          final detailContent = await detailFile.readAsString();
          final detail = jsonDecode(detailContent) as Map<String, dynamic>;
          partNumber = detail['Part Number'] as String? ?? '';
          die = (detail['Int Chip Num'] as String?) ?? '';
          cellType = (detail['Cell Type'] as String?) ?? '';
          alias = (detail['Alias'] as String?) ?? '';

          final ppStr = (detail['Prog Planes'] as String?) ?? '0';
          final cbpStr = (detail['Copy Back Planes'] as String?) ?? '0';
          try {
            final pp = int.parse(ppStr);
            final cbp = int.parse(cbpStr);
            if (pp != 0) {
              final result = cbp / pp;
              plane = result == result.toInt()
                  ? result.toInt().toString()
                  : result.toString();
            }
          } catch (_) {
            plane = '';
          }
        } catch (_) {}
      }

      final partNumbers = _splitPartNumbers(partNumber);
      final dirPn = partNumbers.isNotEmpty ? partNumbers.first : '';
      for (final pn in partNumbers) {
        results.add(PartNumber(
          name: pn,
          flashId: flashIdRaw,
          vendor: vendor,
          dirPn: dirPn,
          die: die,
          cellType: cellType,
          plane: plane,
          alias: alias,
        ));
      }
    }

    return ModuleData(partNumbers: results, ctype: ctype);
  }
}
