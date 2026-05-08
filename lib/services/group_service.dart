import 'dart:convert';
import 'dart:io';
import '../models/part_number.dart';

class GroupService {
  static String get _exeDir {
    return File(Platform.resolvedExecutable).parent.path;
  }

  static Directory get _groupsDir => Directory('$_exeDir/Groups');

  static Future<void> ensureDir() async {
    if (!await _groupsDir.exists()) {
      await _groupsDir.create(recursive: true);
    }
  }

  static Future<List<String>> listGroups() async {
    if (!await _groupsDir.exists()) return [];
    final files = await _groupsDir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .map((e) {
      final name = (e as File).uri.pathSegments.last;
      return name.substring(0, name.length - 5); // strip .json
    }).toList();
    files.sort();
    return files;
  }

  static Future<void> saveGroup(String name, List<PartNumber> selectedPns) async {
    await ensureDir();
    final selections = selectedPns
        .where((p) => p.isSelected)
        .map((p) => '${p.name}|${p.flashId}')
        .toList();
    final data = {
      '_format': 'FlashConfigUI_group',
      '_version': 1,
      'selections': selections,
    };
    final file = File('${_groupsDir.path}/$name.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  }

  static Future<List<String>> loadGroupSelections(String name) async {
    final file = File('${_groupsDir.path}/$name.json');
    if (!await file.exists()) return [];
    final content = await file.readAsString(encoding: utf8);
    final data = jsonDecode(content) as Map<String, dynamic>;
    return (data['selections'] as List<dynamic>).cast<String>();
  }

  static Future<void> deleteGroup(String name) async {
    final file = File('${_groupsDir.path}/$name.json');
    if (await file.exists()) {
      await file.delete();
    }
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
