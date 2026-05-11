import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/part_number.dart';
import '../services/module_service.dart';
import '../services/group_service.dart';
import 'report_shell.dart';

// ─── Palette ─────────────────────────────────────────────────────────────────
const _kSidebarBg = Color(0xFF0F172A);
const _kHeaderBg  = Color(0xFF1E293B);
const _kBlue      = Color(0xFF3B82F6);
const _kMainBg    = Color(0xFFF1F5F9);
const _kSurface   = Color(0xFFFFFFFF);
const _kRowOdd    = Color(0xFFF8FAFC);
const _kRowSel    = Color(0xFFEFF6FF);
const _kRowHover  = Color(0xFFE0F2FE);
const _kBorder    = Color(0xFFE2E8F0);
const _kTextPri   = Color(0xFF0F172A);
const _kTextSec   = Color(0xFF64748B);
const _kTermBg    = Color(0xFF0D1117);
const _kTermHdr   = Color(0xFF161B22);
// ─────────────────────────────────────────────────────────────────────────────

const _vendorOrder = [
  'Samsung', 'Kioxia', 'Micron', 'Hynix', 'Intel', 'SanDisk',
];

const _defaultModulesSourcePath =
    r'O:\PRD-(產品研發處)-MPTool\Utility\MPDryRunModules\Modules.7z';

Color _logColor(String line) {
  if (line.startsWith('====='))        return const Color(0xFF60A5FA);
  if (line.startsWith('[Error]'))      return const Color(0xFFF87171);
  if (line.startsWith('[Exit] 0'))     return const Color(0xFF4ADE80);
  if (line.startsWith('[Exit]'))       return const Color(0xFFFB923C);
  if (line.startsWith('[Info]'))       return const Color(0xFF94A3B8);
  if (line.startsWith('@@DRYRUN_RUN')) return const Color(0xFFA78BFA);
  return const Color(0xFFCBD5E1);
}

({Color bg, Color fg}) _cellColors(String ct) {
  return switch (ct.toUpperCase()) {
    'TLC' => (bg: const Color(0xFFDCFCE7), fg: const Color(0xFF166534)),
    'QLC' => (bg: const Color(0xFFDBEAFE), fg: const Color(0xFF1D4ED8)),
    'SLC' => (bg: const Color(0xFFFEF3C7), fg: const Color(0xFF92400E)),
    'MLC' => (bg: const Color(0xFFF3E8FF), fg: const Color(0xFF6B21A8)),
    _     => (bg: const Color(0xFFF1F5F9), fg: const Color(0xFF475569)),
  };
}

// ─── HomeScreen ──────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _prefsArchivePath     = 'dryrun_ui.archive_path';
  static const _prefsSelectedModule  = 'dryrun_ui.selected_module';
  static const _prefsSelectedGroup   = 'dryrun_ui.selected_group';
  static const _prefsOpenHtmlReport  = 'dryrun_ui.open_html_report';
  static const _prefsSharedReportDir = 'dryrun_ui.shared_report_dir';
  static String _prefsVendor(String module) => 'dryrun_ui.vendor.$module';

  List<String>    _modules        = [];
  String?         _selectedModule;
  int?            _moduleCtype;
  List<PartNumber> _allPartNumbers = [];
  bool            _isLoading      = false;
  bool            _selectAll      = false;

  String  _selectedVendor = 'All';

  List<String> _groups        = [];
  String?      _selectedGroup;

  String? _archivePath;
  String? _sharedReportDir;
  bool    _isRunning      = false;
  bool    _showOutput     = true;
  bool    _openHtmlReport = false;
  double  _outputHeight   = 230;
  String? _hoveredRowKey;

  final List<String>     _runLog           = [];
  final ScrollController _logScrollController = ScrollController();
  Process? _activeProcess;
  bool     _stopRequested = false;

  List<PartNumber> get _filteredPartNumbers {
    if (_selectedVendor == 'All') return _allPartNumbers;
    return _allPartNumbers.where((p) => p.vendor == _selectedVendor).toList();
  }

  List<String> get _vendors {
    final set = _allPartNumbers
        .map((p) => p.vendor)
        .where((v) => v.isNotEmpty)
        .toSet();
    final ordered = _vendorOrder.where((v) => set.contains(v)).toList();
    final others  = set.where((v) => !_vendorOrder.contains(v)).toList()..sort();
    return ['All', ...ordered, ...others];
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _activeProcess?.kill(ProcessSignal.sigkill);
    _logScrollController.dispose();
    super.dispose();
  }

  // ─── Init ─────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final prefs          = await SharedPreferences.getInstance();
    final archivePath    = prefs.getString(_prefsArchivePath);
    final openHtmlReport = prefs.getBool(_prefsOpenHtmlReport) ?? false;
    final sharedReportDir = prefs.getString(_prefsSharedReportDir);
    final savedModule    = prefs.getString(_prefsSelectedModule);
    final archiveOk = archivePath != null &&
        archivePath.trim().isNotEmpty &&
        File(archivePath).existsSync();
    if (!archiveOk && archivePath != null) {
      await prefs.remove(_prefsArchivePath);
    }
    setState(() {
      _archivePath      = archiveOk ? archivePath : null;
      _openHtmlReport   = openHtmlReport;
      _sharedReportDir  = sharedReportDir;
      _selectedModule   = savedModule;
    });
    await _ensureModulesAvailableOnStartup();
    await _loadModules();
  }

  Future<void> _ensureModulesAvailableOnStartup() async {
    final needLoad = await ModuleService.isModulesDirMissingOrEmpty();
    if (!needLoad) return;

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _AppDialog(
        title: '找不到 Modules',
        content: '本機 Modules 資料夾不存在或為空。\n\n'
            '將從以下路徑解壓縮：\n$_defaultModulesSourcePath\n\n'
            '目標資料夾：\n${ModuleService.modulesDirPath}',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('安裝'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await ModuleService.extractModulesFrom7z(_defaultModulesSourcePath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Modules 安裝完成')),
      );
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => _AppDialog(
          title: '安裝失敗',
          content: e.toString(),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('確定'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadModules() async {
    final modules = await ModuleService.listModules();
    if (!mounted) return;
    setState(() {
      _modules = modules;
      if (_selectedModule != null && !modules.contains(_selectedModule)) {
        _selectedModule = null;
      }
      if (_selectedModule == null && modules.isNotEmpty) {
        _selectedModule = modules.first;
      }
    });
    if (_selectedModule != null) await _loadPartNumbers();
  }

  Future<void> _loadPartNumbers() async {
    if (_selectedModule == null) return;
    setState(() => _isLoading = true);
    final moduleData   = await ModuleService.loadModuleData(_selectedModule!);
    final prefs        = await SharedPreferences.getInstance();
    final savedVendor  = prefs.getString(_prefsVendor(_selectedModule!));
    final vendorsSet   = moduleData.partNumbers
        .map((p) => p.vendor)
        .where((v) => v.isNotEmpty)
        .toSet();
    final ordered      = _vendorOrder.where((v) => vendorsSet.contains(v)).toList();
    final others       = vendorsSet.where((v) => !_vendorOrder.contains(v)).toList()
      ..sort();
    final validVendors = {'All', ...ordered, ...others};
    final restoredVendor = (savedVendor != null && validVendors.contains(savedVendor))
        ? savedVendor
        : 'All';
    setState(() {
      _allPartNumbers = moduleData.partNumbers;
      _moduleCtype    = moduleData.ctype;
      _isLoading      = false;
      _selectAll      = false;
      _selectedVendor = restoredVendor;
    });
    _loadGroups();
  }

  // ─── Group methods ────────────────────────────────────────────────────────

  Future<void> _loadGroups() async {
    if (_selectedModule == null) {
      setState(() { _groups = []; _selectedGroup = null; });
      return;
    }
    final groups     = await GroupService.listGroups(_selectedModule!);
    final prefs      = await SharedPreferences.getInstance();
    final savedGroup = prefs.getString(_prefsSelectedGroup);
    setState(() {
      _groups        = groups;
      _selectedGroup = (savedGroup != null && groups.contains(savedGroup))
          ? savedGroup
          : null;
    });
    if (_selectedGroup != null) await _loadGroup(_selectedGroup);
  }

  Future<void> _saveGroup() async {
    final selected = _allPartNumbers.where((p) => p.isSelected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No part numbers selected')),
      );
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return _AppDialog(
          title: 'Save Group',
          content: null,
          customContent: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. Samsung TLC',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: _kMainBg,
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty) return;
    if (_selectedModule == null) return;
    await GroupService.saveGroup(_selectedModule!, name.trim(), _allPartNumbers);
    _loadGroups();
  }

  Future<void> _loadGroup(String? name) async {
    if (name == null || name.isEmpty || _selectedModule == null) return;
    final selections = await GroupService.loadGroupSelections(_selectedModule!, name);
    if (selections.isEmpty) return;
    setState(() {
      _allPartNumbers = GroupService.applySelections(_allPartNumbers, selections);
      _selectedGroup  = name;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSelectedGroup, name);
    _refreshSelectionLog();
  }

  Future<void> _deleteGroup() async {
    if (_selectedGroup == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _AppDialog(
        title: 'Delete Group',
        content: 'Delete "$_selectedGroup"? This cannot be undone.',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await GroupService.deleteGroup(_selectedModule!, _selectedGroup!);
    final prefs     = await SharedPreferences.getInstance();
    final savedGroup = prefs.getString(_prefsSelectedGroup);
    if (savedGroup == _selectedGroup) await prefs.remove(_prefsSelectedGroup);
    _loadGroups();
  }

  Future<void> _pickArchive() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '7z', extensions: ['7z']),
      ],
    );
    if (file == null) return;
    setState(() => _archivePath = file.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsArchivePath, file.path);
  }

  // ─── Path helpers ─────────────────────────────────────────────────────────

  String get _exeDirPath => File(Platform.resolvedExecutable).parent.path;

  Iterable<String> _searchBases() sync* {
    Directory dir = Directory(_exeDirPath);
    for (int i = 0; i < 10; i++) {
      yield dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }

  String _joinBaseRel(String base, String rel) =>
      p.joinAll([base, ...p.split(rel)]);

  String? _findExistingFileRelPath(List<String> relCandidates) {
    for (final base in _searchBases()) {
      for (final rel in relCandidates) {
        final abs = File(_joinBaseRel(base, rel));
        if (abs.existsSync()) return p.relative(abs.path, from: _exeDirPath);
      }
    }
    return null;
  }

  String? _findExistingDirRelPath(List<String> relCandidates) {
    for (final base in _searchBases()) {
      for (final rel in relCandidates) {
        final abs = Directory(_joinBaseRel(base, rel));
        if (abs.existsSync()) return p.relative(abs.path, from: _exeDirPath);
      }
    }
    return null;
  }

  Future<List<String>?> _resolvePythonCommand() async {
    final candidates = <List<String>>[
      ['py', '-3.14'],
      ['py', '-3'],
      ['python'],
      ['python3'],
    ];
    for (final cand in candidates) {
      try {
        final result = await Process.run(
          cand.first,
          [...cand.skip(1), '-V'],
          runInShell: true,
        );
        if (result.exitCode == 0) return cand;
      } catch (_) {}
    }
    return null;
  }

  // ─── Run logic ────────────────────────────────────────────────────────────

  void _appendLog(String line) {
    setState(() => _runLog.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) return;
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _stopRun() {
    _stopRequested = true;
    _activeProcess?.kill(ProcessSignal.sigkill);
  }

  // ─── CardRegisters → structured JSON ─────────────────────────────────────

  static List<Map<String, dynamic>> _parseCardRegistersToJson(String raw) {
    final lines    = raw.split(RegExp(r'\r?\n'));
    final sections = <Map<String, dynamic>>[];
    String title   = '';
    final hexBuf   = <String>[];
    final fields   = <Map<String, dynamic>>[];
    bool pastDash  = false;
    bool inHex     = false;

    void flush() {
      if (title.isNotEmpty || hexBuf.isNotEmpty || fields.isNotEmpty) {
        sections.add({'title': title, 'hex': List<String>.from(hexBuf), 'fields': List<Map<String, dynamic>>.from(fields)});
      }
      title = ''; hexBuf.clear(); fields.clear(); pastDash = false; inHex = false;
    }

    final hexRe = RegExp(r'^[0-9a-fA-F]{2}( [0-9a-fA-F]{2})*\s*$');
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty)             { flush(); continue; }
      if (t.startsWith('---'))   { pastDash = true; inHex = true; continue; }
      if (!pastDash)             { title = t; continue; }
      if (inHex && hexRe.hasMatch(t)) { hexBuf.add(t); continue; }
      inHex = false;
      final eq = t.indexOf('=');
      if (eq > 0) {
        fields.add({'type': 'kv', 'key': t.substring(0, eq).trim(), 'value': t.substring(eq + 1).trim()});
      } else if (t.endsWith(':')) {
        fields.add({'type': 'subheader', 'key': t});
      } else {
        fields.add({'type': 'list', 'value': t});
      }
    }
    flush();
    return sections;
  }

  // ─── Report generator (JSON/JS data + HTML shell) ─────────────────────────

  Future<void> _generateReport(
    String archivePath,
    List<String> targets,
    Map<String, int> exitCodes,
    Map<String, Map<String, int>> deviceExitCodesByTarget,
    Map<String, Map<String, List<String>>> outputByTargetByRun,
    Map<String, Map<String, String>> dumpDirByTargetByRun,
    Map<String, PartNumber> targetMeta,
  ) async {
    final now         = DateTime.now();
    final archiveName = p.basename(archivePath);
    final archiveStem = p.basenameWithoutExtension(archiveName);
    final safeName    = archiveStem
        .replaceAll(RegExp(r'[^\w.]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');

    final reportsDir = Directory(
      _sharedReportDir ?? p.join(p.dirname(archivePath), 'DryRun Report'),
    );
    if (!reportsDir.existsSync()) reportsDir.createSync(recursive: true);

    // Build target data list
    final targetList = <Map<String, dynamic>>[];
    for (final t in targets) {
      final devMap  = deviceExitCodesByTarget[t] ?? {};
      final outMap  = outputByTargetByRun[t] ?? {};
      final dumpMap = dumpDirByTargetByRun[t] ?? {};
      final runKeys = devMap.keys.toList()..sort();
      final runs    = <Map<String, dynamic>>[];
      for (final rk in runKeys) {
        final rCode  = devMap[rk] ?? -9999;
        final output = (outMap[rk] ?? []).where((l) => l.trim().isNotEmpty).toList();
        var crSections = <Map<String, dynamic>>[];
        final dumpDir = dumpMap[rk] ?? '';
        if (dumpDir.isNotEmpty) {
          final crFile = File(p.join(dumpDir, 'CardRegisters.txt'));
          if (crFile.existsSync()) {
            try { crSections = _parseCardRegistersToJson(crFile.readAsStringSync(encoding: utf8)); }
            catch (_) {}
          }
        }
        runs.add({'key': rk, 'exitCode': rCode, 'output': output, 'cardRegisters': crSections});
      }
      final meta = targetMeta[t];
      targetList.add({
        'name':     t,
        'exitCode': exitCodes[t] ?? -9999,
        'flashId':  meta?.flashId  ?? '',
        'die':      meta?.die      ?? '',
        'cellType': meta?.cellType ?? '',
        'plane':    meta?.plane    ?? '',
        'alias':    meta?.alias    ?? '',
        'runs':     runs,
      });
    }

    final reportData = <String, dynamic>{
      'key':      archiveStem,
      'time':     now.toIso8601String(),
      'module':   _selectedModule ?? '',
      'ctype':    _moduleCtype?.toString() ?? '-',
      'archive':  archiveName,
      'dumpBase': p.join(_exeDirPath, 'Dump'),
      'targets':  targetList,
    };

    // Write JSONP data file: <safeName>.js
    final jsFile = File(p.join(reportsDir.path, '$safeName.js'));
    await jsFile.writeAsString(
      'window.DRYRUN_REPORTS=window.DRYRUN_REPORTS||{};\n'
      'window.DRYRUN_REPORTS[${jsonEncode(archiveStem)}]=${jsonEncode(reportData)};\n',
      encoding: utf8,
    );
    _appendLog('[Info] Report data: ${jsFile.path}');

    // Scan Reports/ for all report .js files (exclude manifest.js), newest first
    final jsFiles = reportsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.js') && p.basename(f.path) != 'manifest.js')
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    // Write manifest.js
    final manifestFile = File(p.join(reportsDir.path, 'manifest.js'));
    final manifestList = jsFiles.map((f) => p.basename(f.path)).toList();
    await manifestFile.writeAsString(
      'window.DRYRUN_MANIFEST=${jsonEncode(manifestList)};\n',
      encoding: utf8,
    );
    _appendLog('[Info] Manifest: ${manifestFile.path}');

    // Always overwrite index.html so template changes take effect
    final indexFile = File(p.join(reportsDir.path, 'index.html'));
    await indexFile.writeAsString(kReportShellHtml, encoding: utf8);
    _appendLog('[Info] Report index: ${indexFile.path}');
    final pyFile = File(p.join(reportsDir.path, 'update_manifest.py'));
    if (!pyFile.existsSync()) {
      await pyFile.writeAsString(kUpdateManifestPy, encoding: utf8);
    }
    final batFile = File(p.join(reportsDir.path, 'update_manifest.bat'));
    if (!batFile.existsSync()) {
      await batFile.writeAsString(kUpdateManifestBat, encoding: utf8);
    }

    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', indexFile.path],
            runInShell: true, workingDirectory: _exeDirPath);
      } else if (Platform.isMacOS) {
        await Process.start('open', [indexFile.path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [indexFile.path]);
      }
    } catch (e) {
      _appendLog('[Error] Open report failed: $e');
    }
  }

  Future<void> _openReportDir() async {
    final dir = _sharedReportDir ??
        (_archivePath != null
            ? p.join(p.dirname(_archivePath!), 'DryRun Report')
            : null);
    if (dir == null) return;
    await Process.start('explorer.exe', [dir], runInShell: false);
  }

  Future<void> _pickSharedReportDir() async {
    final dir = await getDirectoryPath(initialDirectory: _sharedReportDir);
    if (dir == null) return;
    setState(() => _sharedReportDir = dir);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSharedReportDir, dir);
  }

  Future<void> _clearSharedReportDir() async {
    setState(() => _sharedReportDir = null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsSharedReportDir);
  }

  Future<void> _runDryRun() async {
    if (_isRunning) return;

    final archivePath = _archivePath;
    if (archivePath == null || archivePath.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an MPTool .7z archive first')),
      );
      return;
    }

    final selected = _allPartNumbers.where((p) => p.isSelected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one part number')),
      );
      return;
    }

    final targetSet  = <String>{};
    final targetMeta = <String, PartNumber>{};
    for (final pn in selected) {
      final vendor = pn.vendor.trim();
      final dirPn  = pn.dirPn.trim().isNotEmpty ? pn.dirPn.trim() : pn.name.trim();
      if (vendor.isEmpty || dirPn.isEmpty) continue;
      final key = '$vendor/$dirPn';
      targetSet.add(key);
      targetMeta.putIfAbsent(key, () => pn);
    }

    if (targetSet.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected items are missing Vendor/PartNumber directory info')),
      );
      return;
    }
    final targets = targetSet.toList()..sort();

    final scriptRel = _findExistingFileRelPath(
        const ['scripts/run_dryrun.py', 'run_dryrun.py']);
    if (scriptRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('run_dryrun.py not found — ensure scripts/ folder is next to the exe')),
      );
      return;
    }

    final readFeatureRel = _findExistingFileRelPath(
        const ['scripts/read_feature.py', 'read_feature.py']);
    if (readFeatureRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('read_feature.py not found — cannot check MPTool CLI support')),
      );
      return;
    }

    final module = _selectedModule;
    if (module == null) return;
    final devicesDirRel = _findExistingDirRelPath(
        ['Modules/$module/Recipes']);
    if (devicesDirRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Modules/$module/Recipes not found — cannot run dry run')),
      );
      return;
    }

    final pyCmd = await _resolvePythonCommand();
    if (pyCmd == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Python not found (py / python) — cannot run dry run')),
      );
      return;
    }

    setState(() {
      _isRunning      = true;
      _stopRequested  = false;
      _showOutput     = true;
      _runLog.clear();
    });

    _appendLog('[Info] Archive: $archivePath');
    _appendLog('[Info] BaseDir: $_exeDirPath');
    _appendLog('[Info] Script: $scriptRel');
    _appendLog('[Info] read_feature.py: $readFeatureRel');
    _appendLog('[Info] devices-dir: $devicesDirRel');
    _appendLog('[Info] output-base: .');
    _appendLog('[Info] ctype: ${_moduleCtype?.toString() ?? '-'}');
    _appendLog('[Info] Targets: ${targets.length}');

    final exe          = pyCmd.first;
    final prefixArgs   = pyCmd.skip(1).toList();
    final workingDir   = _exeDirPath;
    const workRootRel  = '_dryrun_work';
    String? workName;
    try {
      final archiveFile = File(archivePath);
      final stat        = archiveFile.statSync();
      final stem        = p.basenameWithoutExtension(archivePath);
      final safeStem    = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
      workName = 'mptool_${safeStem}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {}

    _appendLog('[Info] work-root: $workRootRel');
    if (workName != null) _appendLog('[Info] work-name: $workName');

    final exitCodes               = <String, int>{};
    final deviceExitCodesByTarget = <String, Map<String, int>>{};
    final outputByTargetByRun     = <String, Map<String, List<String>>>{};
    final dumpDirByTargetByRun    = <String, Map<String, String>>{};

    try {
      int idx = 0;
      for (final target in targets) {
        if (_stopRequested) break;
        idx++;
        _appendLog('');
        _appendLog('===== ($idx/${targets.length}) $target =====');

        final args = <String>[
          ...prefixArgs,
          scriptRel,
          archivePath,
          target,
          '--devices-dir', devicesDirRel,
          '--output-base', '.',
          '--work-root',   workRootRel,
          '--keep-temp',
        ];
        if (_moduleCtype != null) args.addAll(['--ctype', _moduleCtype.toString()]);
        if (workName != null)      args.addAll(['--work-name', workName]);

        final process = await Process.start(
          exe, args,
          runInShell: true,
          workingDirectory: workingDir,
        );
        _activeProcess = process;

        final stdoutDone = Completer<void>();
        final stderrDone = Completer<void>();
        deviceExitCodesByTarget[target] = {};
        outputByTargetByRun[target]     = {};
        dumpDirByTargetByRun[target]    = {};
        String? currentRunKey;

        void handleLine(String line) {
          if (line.startsWith('@@DRYRUN_RUN ')) {
            try {
              final obj = jsonDecode(line.substring('@@DRYRUN_RUN '.length))
                  as Map<String, dynamic>;
              final dev     = (obj['device']   ?? '').toString();
              final config  = (obj['config']   ?? '').toString();
              final exit    = int.tryParse((obj['exit_code'] ?? '').toString()) ?? -9999;
              final dumpDir = (obj['dump_dir'] ?? '').toString();
              if (dev.isNotEmpty) {
                final runKey = config.isNotEmpty ? '$dev + $config' : dev;
                final cur = deviceExitCodesByTarget[target]![runKey];
                if (cur == null) {
                  deviceExitCodesByTarget[target]![runKey] = exit;
                } else if (cur == 0 && exit != 0) {
                  deviceExitCodesByTarget[target]![runKey] = exit;
                }
                currentRunKey = runKey;
                outputByTargetByRun[target]![runKey] = [];
                if (dumpDir.isNotEmpty) {
                  dumpDirByTargetByRun[target]![runKey] = dumpDir;
                }
              }
            } catch (_) {}
          } else {
            if (currentRunKey != null) {
              outputByTargetByRun[target]![currentRunKey!] ??= [];
              outputByTargetByRun[target]![currentRunKey!]!.add(line);
            }
          }
          _appendLog(line);
        }

        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(handleLine,
                onDone: () => stdoutDone.complete(),
                onError: (_) => stdoutDone.complete());

        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(handleLine,
                onDone: () => stderrDone.complete(),
                onError: (_) => stderrDone.complete());

        final exitCode = await process.exitCode;
        await Future.wait([stdoutDone.future, stderrDone.future]);
        exitCodes[target] = exitCode;
        _appendLog('[Exit] $exitCode');
      }

      if (_openHtmlReport && !_stopRequested && exitCodes.isNotEmpty) {
        await _generateReport(
            archivePath, targets, exitCodes, deviceExitCodesByTarget,
            outputByTargetByRun, dumpDirByTargetByRun, targetMeta);
      }
    } catch (e) {
      _appendLog('[Error] $e');
    } finally {
      _activeProcess = null;
      setState(() => _isRunning = false);
    }
  }

  void _toggleSelection(int index) {
    final list   = _filteredPartNumbers;
    final target = list[index];
    setState(() {
      _allPartNumbers = _allPartNumbers.map((pn) {
        if (pn.flashId == target.flashId && pn.name == target.name) {
          return pn.copyWith(isSelected: !target.isSelected);
        }
        return pn;
      }).toList();
    });
    _refreshSelectionLog();
  }

  void _toggleSelectAll() {
    final filtered = _filteredPartNumbers;
    setState(() {
      _selectAll = !_selectAll;
      _allPartNumbers = _allPartNumbers.map((pn) {
        if (filtered.any((f) => f.flashId == pn.flashId && f.name == pn.name)) {
          return pn.copyWith(isSelected: _selectAll);
        }
        return pn;
      }).toList();
    });
    _refreshSelectionLog();
  }

  void _refreshSelectionLog() {
    if (_isRunning) return;
    final selected = _allPartNumbers.where((p) => p.isSelected).toList();
    final lines = <String>[
      '===== Selected Part Numbers (${selected.length}) =====',
    ];
    for (final pn in selected) {
      final extra = [
        if (pn.flashId.isNotEmpty) pn.flashId,
        if (pn.die.isNotEmpty) '${pn.die} Die',
        if (pn.cellType.isNotEmpty) pn.cellType,
      ].join('  ');
      lines.add('  ${pn.vendor.isNotEmpty ? "${pn.vendor}/" : ""}${pn.name}'
          '${extra.isNotEmpty ? "  —  $extra" : ""}');
    }
    setState(() {
      _runLog
        ..clear()
        ..addAll(lines);
    });
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredPartNumbers;
    return Scaffold(
      backgroundColor: _kMainBg,
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Column(
              children: [
                _buildHeader(),
                if (_isRunning)
                  const LinearProgressIndicator(
                    backgroundColor: _kBorder,
                    color: _kBlue,
                    minHeight: 2,
                  ),
                _buildControlsBar(),
                _buildTableHeader(),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: _buildTable(filtered)),
                      if (_showOutput) _buildOutputPanel(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Sidebar ──────────────────────────────────────────────────────────────

  Widget _buildSidebar() {
    return Container(
      width: 200,
      color: _kSidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
            child: Row(
              children: [
                GestureDetector(
                  onDoubleTap: () => Process.start('explorer.exe', [_exeDirPath], runInShell: false),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _kBlue,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.memory_rounded, color: Colors.white, size: 19),
                  ),
                ),
                const SizedBox(width: 11),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SD MPTool',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700)),
                    Text('Dry Run Launcher',
                        style: TextStyle(color: Color(0xFF475569), fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text(
              'VENDOR',
              style: TextStyle(
                  color: Color(0xFF475569),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              itemCount: _vendors.length,
              itemBuilder: (context, i) {
                final vendor = _vendors[i];
                final count  = vendor == 'All'
                    ? _allPartNumbers.length
                    : _allPartNumbers.where((p) => p.vendor == vendor).length;
                final active = _selectedVendor == vendor;
                return _VendorItem(
                  vendor: vendor,
                  count: count,
                  active: active,
                  onTap: () {
                    setState(() => _selectedVendor = vendor);
                    final mod = _selectedModule;
                    if (mod != null) {
                      SharedPreferences.getInstance().then(
                        (prefs) => prefs.setString(_prefsVendor(mod), vendor),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final archiveText = _archivePath?.trim() ?? '';
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: _kHeaderBg,
      child: Row(
        children: [
          _HeaderButton(
            onPressed: _isRunning ? null : _pickArchive,
            icon: Icons.folder_open_rounded,
            label: 'MPTool Archive',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Tooltip(
              message: archiveText.isEmpty ? '' : archiveText,
              preferBelow: true,
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withOpacity(0.92),
                borderRadius: BorderRadius.circular(6),
              ),
              textStyle: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 12,
                fontFamily: 'Courier New',
              ),
              child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.07),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  Icon(
                    archiveText.isEmpty
                        ? Icons.inbox_outlined
                        : Icons.archive_outlined,
                    size: 14,
                    color: archiveText.isEmpty
                        ? Colors.white.withOpacity(0.25)
                        : const Color(0xFF60A5FA),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      archiveText.isEmpty
                          ? 'No archive selected — click MPTool Archive to browse'
                          : archiveText,
                      style: TextStyle(
                        color: archiveText.isEmpty
                            ? Colors.white.withOpacity(0.3)
                            : Colors.white.withOpacity(0.85),
                        fontSize: 12,
                        fontFamily: archiveText.isEmpty ? null : 'Courier New',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
          const SizedBox(width: 16),
          _CompactDropdown<String>(
            value: _selectedModule,
            hintText: 'Select Module',
            items: _modules
                .map((m) => _CompactDropdownItem(value: m, label: m))
                .toList(),
            onChanged: (val) async {
              setState(() => _selectedModule = val);
              final prefs = await SharedPreferences.getInstance();
              if (val != null) {
                await prefs.setString(_prefsSelectedModule, val);
              } else {
                await prefs.remove(_prefsSelectedModule);
              }
              _loadPartNumbers();
            },
            height: 36,
            itemHeight: 36,
            minWidth: 180,
            backgroundColor: Colors.white.withOpacity(0.1),
            borderColor: Colors.white.withOpacity(0.2),
            textColor: Colors.white,
            hintColor: Colors.white54,
            iconColor: Colors.white54,
            menuColor: const Color(0xFF1E293B),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
        ],
      ),
    );
  }

  // ─── Controls bar ─────────────────────────────────────────────────────────

  Widget _buildControlsBar() {
    final selectedCount = _allPartNumbers.where((p) => p.isSelected).length;
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          _StatChip(label: 'Total', value: '${_allPartNumbers.length}'),
          const _VertDivider(),
          _StatChip(
            label: 'Selected',
            value: '$selectedCount',
            highlight: selectedCount > 0,
          ),
          const _VertDivider(),
          _StatChip(
            label: 'CType',
            value: _moduleCtype?.toString() ?? '—',
          ),
          const SizedBox(width: 18),
          // Group controls
          _SmallButton(
            onPressed: _saveGroup,
            icon: Icons.bookmark_add_outlined,
            label: 'Save',
          ),
          const SizedBox(width: 8),
          _CompactDropdown<String>(
            value: _selectedGroup,
            hintText: 'Load Group',
            items: _groups
                .map((g) => _CompactDropdownItem(value: g, label: g))
                .toList(),
            onChanged: _loadGroup,
            height: 30,
            itemHeight: 32,
            minWidth: 140,
            backgroundColor: _kSurface,
            borderColor: _kBorder,
            textColor: _kTextPri,
            hintColor: _kTextSec,
            iconColor: _kTextSec,
            menuColor: _kSurface,
          ),
          if (_selectedGroup != null) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: 'Delete group',
              child: InkWell(
                onTap: _deleteGroup,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline,
                      size: 16, color: Colors.red.shade400),
                ),
              ),
            ),
          ],
          const Spacer(),
          // Report checkbox
          Row(
            children: [
              Transform.scale(
                scale: 0.82,
                child: Checkbox(
                  value: _openHtmlReport,
                  onChanged: _isRunning
                      ? null
                      : (v) {
                          final next = v ?? false;
                          setState(() => _openHtmlReport = next);
                          SharedPreferences.getInstance().then(
                              (p) => p.setBool(_prefsOpenHtmlReport, next));
                        },
                  activeColor: _kBlue,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Text('HTML Report',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: _kTextSec,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(width: 6),
          // Shared report folder button
          Tooltip(
            message: _sharedReportDir != null
                ? 'Shared report folder:\n$_sharedReportDir'
                : 'Shared report folder: <archive dir>/DryRun Report (default)\nClick to set custom folder',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: _pickSharedReportDir,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      Icons.folder_shared_outlined,
                      size: 18,
                      color: _sharedReportDir != null ? _kBlue : _kTextSec,
                    ),
                  ),
                ),
                if (_sharedReportDir != null)
                  InkWell(
                    onTap: _clearSharedReportDir,
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 12, color: _kTextSec),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Output toggle
          Tooltip(
            message: _showOutput ? 'Hide output' : 'Show output',
            child: InkWell(
              onTap: () => setState(() => _showOutput = !_showOutput),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  Icons.terminal_rounded,
                  size: 18,
                  color: _showOutput ? _kBlue : _kTextSec,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Open report directory',
            child: InkWell(
              onTap: (_sharedReportDir != null || _archivePath != null)
                  ? _openReportDir
                  : null,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(Icons.folder_open_rounded, size: 18,
                    color: (_sharedReportDir != null || _archivePath != null)
                        ? _kTextSec
                        : _kTextSec.withOpacity(0.3)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (_isRunning) ...[
            OutlinedButton.icon(
              onPressed: _stopRun,
              icon: const Icon(Icons.stop_rounded, size: 15),
              label: const Text('Stop'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade600,
                side: BorderSide(color: Colors.red.shade300),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            onPressed: _isRunning ? null : _runDryRun,
            icon: Icon(
              _isRunning ? Icons.hourglass_top_rounded : Icons.play_arrow_rounded,
              size: 17,
            ),
            label: Text(_isRunning ? 'Running…' : 'Run Dry Run'),
            style: FilledButton.styleFrom(
              backgroundColor: _kBlue,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Table header ─────────────────────────────────────────────────────────

  Widget _buildTableHeader() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: _kMainBg,
        border: Border(
          top: BorderSide(color: _kBorder),
          bottom: BorderSide(color: _kBorder),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Checkbox(
              value: _selectAll,
              onChanged: (_) => _toggleSelectAll(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: _kBlue,
            ),
          ),
          const SizedBox(width: 8),
          const _TH('#', 36),
          const _TH('PART NUMBER', 280),
          const _TH('FLASH ID', 190),
          const _TH('DIE', 50, center: true),
          const _TH('CELL TYPE', 80, center: true),
          const _TH('PLANE', 60, center: true),
          const Expanded(child: _TH('ALIAS', 0)),
        ],
      ),
    );
  }

  // ─── Table body ───────────────────────────────────────────────────────────

  Widget _buildTable(List<PartNumber> filtered) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _kBlue, strokeWidth: 2.5),
            SizedBox(height: 12),
            Text('Loading part numbers…',
                style: TextStyle(color: _kTextSec, fontSize: 13)),
          ],
        ),
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory_outlined,
                size: 44, color: _kTextSec.withOpacity(0.35)),
            const SizedBox(height: 12),
            const Text('No part numbers',
                style: TextStyle(
                    color: _kTextSec,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
            if (_selectedVendor != 'All') ...[
              const SizedBox(height: 4),
              Text('Try selecting "All" vendor',
                  style: TextStyle(
                      color: _kTextSec.withOpacity(0.6), fontSize: 12)),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final pn     = filtered[index];
        final rowKey = '${pn.flashId}|${pn.name}';
        final isHov  = _hoveredRowKey == rowKey;

        Color rowBg;
        if (pn.isSelected) {
          rowBg = isHov ? _kRowHover : _kRowSel;
        } else {
          rowBg = isHov ? _kRowHover : (index.isEven ? _kSurface : _kRowOdd);
        }

        return MouseRegion(
          onEnter: (_) => setState(() => _hoveredRowKey = rowKey),
          onExit: (_) => setState(() {
            if (_hoveredRowKey == rowKey) _hoveredRowKey = null;
          }),
          child: Container(
              decoration: BoxDecoration(
                color: rowBg,
                border: Border(
                  left: BorderSide(
                    color: pn.isSelected ? _kBlue : Colors.transparent,
                    width: 3,
                  ),
                  bottom: const BorderSide(color: _kBorder, width: 0.5),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Checkbox(
                      value: pn.isSelected,
                      onChanged: (_) => _toggleSelection(index),
                      activeColor: _kBlue,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TD('${index + 1}', 36, color: _kTextSec, size: 12),
                  _TD(pn.name, 280, weight: FontWeight.w600),
                  _TD(pn.flashId, 190, mono: true, color: _kTextSec, size: 12),
                  SizedBox(
                    width: 50,
                    child: Center(
                      child: Text(pn.die,
                          style: const TextStyle(
                              fontSize: 13, color: _kTextPri)),
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: Center(
                      child: pn.cellType.isEmpty
                          ? const SizedBox.shrink()
                          : _CellBadge(pn.cellType),
                    ),
                  ),
                  _TD(pn.plane, 60, center: true),
                  Expanded(
                    child: Text(
                      pn.alias,
                      style: const TextStyle(
                          color: _kTextSec, fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        );
      },
    );
  }

  // ─── Output panel ─────────────────────────────────────────────────────────

  Widget _buildOutputPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── resize handle ──────────────────────────────────────────────
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            onVerticalDragUpdate: (d) => setState(() {
              _outputHeight = (_outputHeight - d.delta.dy).clamp(80.0, 700.0);
            }),
            child: Container(
              height: 6,
              color: const Color(0xFF0F172A),
              alignment: Alignment.center,
              child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        // ── panel body ─────────────────────────────────────────────────
        Container(
      height: _outputHeight,
      decoration: const BoxDecoration(
        color: _kTermBg,
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: _kTermHdr,
              border: Border(bottom: BorderSide(color: Color(0xFF0D1117))),
            ),
            child: Row(
              children: [
                Row(
                  children: [
                    _TermDot(color: Colors.red.shade400),
                    const SizedBox(width: 5),
                    _TermDot(color: Colors.orange.shade400),
                    const SizedBox(width: 5),
                    _TermDot(color: Colors.green.shade500),
                  ],
                ),
                const SizedBox(width: 12),
                Text(
                  _isRunning ? 'OUTPUT — Running' : 'OUTPUT',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                if (_isRunning) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Color(0xFF60A5FA),
                    ),
                  ),
                ],
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _runLog.clear()),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear',
                      style: TextStyle(
                          color: Color(0xFF475569), fontSize: 11.5)),
                ),
              ],
            ),
          ),
          Expanded(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
              child: _runLog.isEmpty
                  ? const Center(
                      child: Text('No output yet',
                          style: TextStyle(
                              color: Color(0xFF334155), fontSize: 12)),
                    )
                  : ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      itemCount: _runLog.length,
                      itemBuilder: (context, i) {
                        final line = _runLog[i];
                        return SelectableText(
                          line,
                          style: TextStyle(
                            color: _logColor(line),
                            fontSize: 12,
                            fontFamily: 'Courier New',
                            height: 1.55,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
        ),
      ],
    );
  }
}

// ─── Reusable widgets ─────────────────────────────────────────────────────────

class _VendorItem extends StatelessWidget {
  final String vendor;
  final int    count;
  final bool   active;
  final VoidCallback onTap;

  const _VendorItem({
    required this.vendor,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: active ? _kBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    vendor,
                    style: TextStyle(
                      color: active ? Colors.white : const Color(0xFFCBD5E1),
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white.withOpacity(0.2)
                        : const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: active ? Colors.white : const Color(0xFF64748B),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  const _HeaderButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withOpacity(0.3)),
        backgroundColor: Colors.white.withOpacity(0.08),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final bool   highlight;

  const _StatChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: const TextStyle(
                fontSize: 12, color: _kTextSec, fontWeight: FontWeight.w500)),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                color: highlight ? _kBlue : _kTextPri,
                fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _VertDivider extends StatelessWidget {
  const _VertDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: _kBorder,
    );
  }
}

class _SmallButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  const _SmallButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _kTextPri,
        side: const BorderSide(color: _kBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _CellBadge extends StatelessWidget {
  final String cellType;
  const _CellBadge(this.cellType);

  @override
  Widget build(BuildContext context) {
    final c = _cellColors(cellType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        cellType,
        style: TextStyle(
          color: c.fg,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TermDot extends StatelessWidget {
  final Color color;
  const _TermDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color.withOpacity(0.7),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _TH extends StatelessWidget {
  final String text;
  final double width;
  final bool   center;

  const _TH(this.text, this.width, {this.center = false});

  @override
  Widget build(BuildContext context) {
    final widget = Text(
      text,
      textAlign: center ? TextAlign.center : TextAlign.left,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: _kTextSec,
        letterSpacing: 0.6,
      ),
    );
    if (width == 0) return widget;
    return SizedBox(width: width, child: widget);
  }
}

class _TD extends StatelessWidget {
  final String     text;
  final double     width;
  final bool       center;
  final FontWeight weight;
  final bool       mono;
  final Color?     color;
  final double     size;

  const _TD(
    this.text,
    this.width, {
    this.center = false,
    this.weight = FontWeight.normal,
    this.mono   = false,
    this.color,
    this.size   = 13,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          fontFamily: mono ? 'Courier New' : null,
          color: color ?? _kTextPri,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _AppDialog extends StatelessWidget {
  final String         title;
  final String?        content;
  final Widget?        customContent;
  final List<Widget>   actions;

  const _AppDialog({
    required this.title,
    required this.content,
    this.customContent,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _kTextPri)),
              const SizedBox(height: 14),
              if (content != null)
                Text(content!,
                    style: const TextStyle(
                        fontSize: 13.5, color: _kTextSec, height: 1.5)),
              if (customContent != null) customContent!,
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions
                    .expand((w) => [w, const SizedBox(width: 8)])
                    .take(actions.length * 2 - 1)
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Compact Dropdown ─────────────────────────────────────────────────────────

class _CompactDropdownItem<T> {
  final T      value;
  final String label;
  const _CompactDropdownItem({required this.value, required this.label});
}

class _CompactDropdown<T> extends StatelessWidget {
  final T?                           value;
  final String                       hintText;
  final List<_CompactDropdownItem<T>> items;
  final ValueChanged<T>              onChanged;
  final double                       height;
  final double                       itemHeight;
  final double                       minWidth;
  final Color                        backgroundColor;
  final Color                        borderColor;
  final Color                        textColor;
  final Color                        hintColor;
  final Color                        iconColor;
  final Color                        menuColor;
  final double                       fontSize;
  final BorderRadius                 borderRadius;

  const _CompactDropdown({
    required this.value,
    required this.hintText,
    required this.items,
    required this.onChanged,
    required this.height,
    required this.itemHeight,
    required this.backgroundColor,
    required this.borderColor,
    required this.textColor,
    required this.hintColor,
    required this.iconColor,
    required this.menuColor,
    this.minWidth    = 0,
    this.fontSize    = 13,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  @override
  Widget build(BuildContext context) {
    String? selected;
    for (final it in items) {
      if (it.value == value) {
        selected = it.label;
        break;
      }
    }

    return SizedBox(
      height: height,
      child: PopupMenuButton<T>(
        padding:   EdgeInsets.zero,
        tooltip:   '',
        offset:    Offset(0, height),
        color:     menuColor,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(color: borderColor),
        ),
        onSelected: onChanged,
        itemBuilder: (context) => items
            .map((it) => PopupMenuItem<T>(
                  value:   it.value,
                  height:  itemHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    it.label,
                    style: TextStyle(
                        fontSize: fontSize,
                        color: textColor,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        child: Container(
          height: height,
          constraints: minWidth > 0 ? BoxConstraints(minWidth: minWidth) : null,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color:        backgroundColor,
            borderRadius: borderRadius,
            border:       Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                selected ?? hintText,
                style: TextStyle(
                  fontSize:   fontSize,
                  color:      selected == null ? hintColor : textColor,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: 6),
              Icon(Icons.expand_more_rounded, size: 17, color: iconColor),
            ],
          ),
        ),
      ),
    );
  }
}
