import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/part_number.dart';

class GroupService {
  static String get _exeDir =>
      File(Platform.resolvedExecutable).parent.path;

  static Directory _savedDataDir(String module) =>
      Directory(p.join(_exeDir, 'Modules', module, 'SavedData'));

  static Future<List<String>> listGroups(String module) async {
    final dir = _savedDataDir(module);
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .map((e) {
          final name = p.basename(e.path);
          return name.substring(0, name.length - 5);
        })
        .toList();
    files.sort();
    return files;
  }

  static Future<void> saveGroup(
      String module, String name, List<PartNumber> allPns) async {
    final dir = _savedDataDir(module);
    if (!await dir.exists()) await dir.create(recursive: true);
    final selections = allPns
        .where((pn) => pn.isSelected)
        .map((pn) => '${pn.name}|${pn.flashId}')
        .toList();
    final data = {
      '_format': 'FlashConfigUI_group',
      '_version': 1,
      'selections': selections,
    };
    await File(p.join(dir.path, '$name.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  }

  static Future<List<String>> loadGroupSelections(
      String module, String name) async {
    final file = File(p.join(_savedDataDir(module).path, '$name.json'));
    if (!await file.exists()) return [];
    final content = await file.readAsString(encoding: utf8);
    final data = jsonDecode(content) as Map<String, dynamic>;
    return (data['selections'] as List<dynamic>).cast<String>();
  }

  static Future<void> deleteGroup(String module, String name) async {
    final file = File(p.join(_savedDataDir(module).path, '$name.json'));
    if (await file.exists()) await file.delete();
  }

  /// Parse "pn|flash_id" format and apply selections to the given list.
  static List<PartNumber> applySelections(
      List<PartNumber> allPns, List<String> selections) {
    final selectedKeys = selections.toSet();
    return allPns.map((pn) {
      final key = '${pn.name}|${pn.flashId}';
      return pn.copyWith(isSelected: selectedKeys.contains(key));
    }).toList();
  }
}
