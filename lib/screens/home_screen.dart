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

const _vendorOrder = [
  'Samsung',
  'Kioxia',
  'Micron',
  'Hynix',
  'Intel',
  'SanDisk'
];

const _defaultModulesSourcePath =
    r'O:\PRD-(產品研發處)-MPTool\Utility\MPDryRunModules\Modules';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _prefsArchivePath = 'dryrun_ui.archive_path';
  static const _prefsSelectedGroup = 'dryrun_ui.selected_group';
  static const _prefsOpenHtmlReport = 'dryrun_ui.open_html_report';
  static String _prefsVendor(String module) => 'dryrun_ui.vendor.$module';

  List<String> _modules = [];
  String? _selectedModule;
  int? _moduleCtype;
  List<PartNumber> _allPartNumbers = [];
  bool _isLoading = false;
  bool _selectAll = false;

  String _selectedVendor = 'All';

  // Group state
  List<String> _groups = [];
  String? _selectedGroup;

  String? _archivePath;
  bool _isRunning = false;
  bool _showOutput = true;
  bool _openHtmlReport = false;
  String? _hoveredRowKey;
  final List<String> _runLog = [];
  final ScrollController _logScrollController = ScrollController();
  Process? _activeProcess;
  bool _stopRequested = false;

  List<PartNumber> get _filteredPartNumbers {
    if (_selectedVendor == 'All') return _allPartNumbers;
    return _allPartNumbers.where((p) => p.vendor == _selectedVendor).toList();
  }

  List<String> get _vendors {
    final set =
        _allPartNumbers.map((p) => p.vendor).where((v) => v.isNotEmpty).toSet();
    final ordered = _vendorOrder.where((v) => set.contains(v)).toList();
    final others = set.where((v) => !_vendorOrder.contains(v)).toList()..sort();
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

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final archivePath = prefs.getString(_prefsArchivePath);
    final openHtmlReport = prefs.getBool(_prefsOpenHtmlReport) ?? false;
    final archiveOk = archivePath != null &&
        archivePath.trim().isNotEmpty &&
        File(archivePath).existsSync();
    if (!archiveOk && archivePath != null) {
      await prefs.remove(_prefsArchivePath);
    }
    setState(() {
      _archivePath = archiveOk ? archivePath : null;
      _openHtmlReport = openHtmlReport;
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
      builder: (ctx) => AlertDialog(
        title: const Text('Modules folder not found'),
        content: Text(
          'Local Modules folder is missing or empty.\n\n'
          'Load from:\n$_defaultModulesSourcePath\n\n'
          'Copy to:\n${ModuleService.modulesDirPath}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Load'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await ModuleService.copyModulesFrom(_defaultModulesSourcePath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Modules loaded')),
      );
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Load failed'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadModules() async {
    final modules = await ModuleService.listModules();
    if (!mounted) return;
    setState(() {
      _modules = modules;
      if (_selectedModule == null && modules.isNotEmpty) {
        _selectedModule = modules.first;
      }
    });
    if (_selectedModule != null) {
      await _loadPartNumbers();
    }
  }

  Future<void> _loadPartNumbers() async {
    if (_selectedModule == null) return;
    setState(() => _isLoading = true);
    final moduleData = await ModuleService.loadModuleData(_selectedModule!);
    final prefs = await SharedPreferences.getInstance();
    final savedVendor = prefs.getString(_prefsVendor(_selectedModule!));
    final vendorsSet = moduleData.partNumbers
        .map((p) => p.vendor)
        .where((v) => v.isNotEmpty)
        .toSet();
    final ordered = _vendorOrder.where((v) => vendorsSet.contains(v)).toList();
    final others = vendorsSet.where((v) => !_vendorOrder.contains(v)).toList()
      ..sort();
    final validVendors = {'All', ...ordered, ...others};
    final restoredVendor =
        (savedVendor != null && validVendors.contains(savedVendor))
            ? savedVendor
            : 'All';
    setState(() {
      _allPartNumbers = moduleData.partNumbers;
      _moduleCtype = moduleData.ctype;
      _isLoading = false;
      _selectAll = false;
      _selectedVendor = restoredVendor;
    });
    _loadGroups();
  }

  // --- Group methods ---
  Future<void> _loadGroups() async {
    final groups = await GroupService.listGroups();
    final prefs = await SharedPreferences.getInstance();
    final savedGroup = prefs.getString(_prefsSelectedGroup);
    setState(() {
      _groups = groups;
      _selectedGroup = (savedGroup != null && groups.contains(savedGroup))
          ? savedGroup
          : null;
    });
    if (_selectedGroup != null) {
      await _loadGroup(_selectedGroup);
    }
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
        return AlertDialog(
          title: const Text('Save Group'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Group Name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty) return;
    await GroupService.saveGroup(name.trim(), _allPartNumbers);
    _loadGroups();
  }

  Future<void> _loadGroup(String? name) async {
    if (name == null || name.isEmpty) return;
    final selections = await GroupService.loadGroupSelections(name);
    if (selections.isEmpty) return;
    setState(() {
      _allPartNumbers =
          GroupService.applySelections(_allPartNumbers, selections);
      _selectedGroup = name;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSelectedGroup, name);
  }

  Future<void> _deleteGroup() async {
    if (_selectedGroup == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text('Delete group "$_selectedGroup"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await GroupService.deleteGroup(_selectedGroup!);
    final prefs = await SharedPreferences.getInstance();
    final savedGroup = prefs.getString(_prefsSelectedGroup);
    if (savedGroup == _selectedGroup) {
      await prefs.remove(_prefsSelectedGroup);
    }
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

  String _joinBaseRel(String base, String rel) {
    return p.joinAll([base, ...p.split(rel)]);
  }

  String? _findExistingFileRelPath(List<String> relCandidates) {
    for (final base in _searchBases()) {
      for (final rel in relCandidates) {
        final absPath = _joinBaseRel(base, rel);
        final abs = File(absPath);
        if (abs.existsSync()) {
          return p.relative(abs.path, from: _exeDirPath);
        }
      }
    }
    return null;
  }

  String? _findExistingDirRelPath(List<String> relCandidates) {
    for (final base in _searchBases()) {
      for (final rel in relCandidates) {
        final absPath = _joinBaseRel(base, rel);
        final abs = Directory(absPath);
        if (abs.existsSync()) {
          return p.relative(abs.path, from: _exeDirPath);
        }
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
      final exe = cand.first;
      final args = <String>[
        ...cand.skip(1),
        '-V',
      ];
      try {
        final result = await Process.run(
          exe,
          args,
          runInShell: true,
        );
        if (result.exitCode == 0) return cand;
      } catch (_) {}
    }
    return null;
  }

  void _appendLog(String line) {
    setState(() {
      _runLog.add(line);
    });
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

  Future<void> _generateAndOpenHtmlReport(
    String archivePath,
    List<String> targets,
    Map<String, int> exitCodes,
    Map<String, Map<String, int>> deviceExitCodesByTarget,
  ) async {
    final now = DateTime.now();
    final safeTime = now.toIso8601String().replaceAll(':', '-');
    final fileName = 'dryrun_report_$safeTime.html';
    final reportsDir = Directory(p.join(_exeDirPath, 'Reports'));
    if (!reportsDir.existsSync()) {
      reportsDir.createSync(recursive: true);
    }
    final reportFile = File(p.join(reportsDir.path, fileName));

    const escape = HtmlEscape();
    final moduleName = _selectedModule ?? '';
    final ctypeText = _moduleCtype?.toString() ?? '-';
    final archiveName = p.basename(archivePath);

    final rows = <String>[];
    int passCount = 0;
    int failCount = 0;
    for (final t in targets) {
      final code = exitCodes[t] ?? -9999;
      final ok = code == 0;
      if (ok) {
        passCount++;
      } else {
        failCount++;
      }
      final deviceMap = deviceExitCodesByTarget[t] ?? const <String, int>{};
      final deviceNames = deviceMap.keys.toList()..sort();
      final deviceRows = deviceNames.map((dev) {
        final dcode = deviceMap[dev] ?? -9999;
        final dok = dcode == 0;
        return '''
              <tr class="${dok ? 'pass' : 'fail'}">
                <td>${escape.convert(dev)}</td>
                <td>${dok ? 'PASS' : 'FAIL'}</td>
                <td>${escape.convert(dcode.toString())}</td>
              </tr>
            ''';
      }).join('\n');
      final deviceDetails = deviceNames.isEmpty
          ? ''
          : '''
            <details>
              <summary>Device Results</summary>
              <table class="sub">
                <thead>
                  <tr>
                    <th>Device</th>
                    <th>Status</th>
                    <th>Exit Code</th>
                  </tr>
                </thead>
                <tbody>
                  $deviceRows
                </tbody>
              </table>
            </details>
          ''';

      rows.add('''
        <tr class="${ok ? 'pass' : 'fail'}">
          <td>${escape.convert(t)}</td>
          <td>${ok ? 'PASS' : 'FAIL'}</td>
          <td>${escape.convert(code.toString())}</td>
          <td>$deviceDetails</td>
        </tr>
      ''');
    }

    final html = '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>DryRun Report</title>
  <style>
    body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#f8fafc;color:#0f172a}
    .meta{display:grid;grid-template-columns:max-content 1fr;gap:8px 16px;margin:0 0 16px 0}
    .meta div{padding:2px 0}
    .badge{display:inline-block;padding:2px 10px;border-radius:999px;font-weight:700;font-size:12px}
    .badge.pass{background:#dcfce7;color:#166534}
    .badge.fail{background:#fee2e2;color:#991b1b}
    table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;border-radius:8px;overflow:hidden}
    th,td{padding:10px 12px;border-bottom:1px solid #e2e8f0;font-size:13px;vertical-align:top}
    th{background:#f1f5f9;text-align:left;font-weight:800;color:#334155}
    tr.pass td:nth-child(2){color:#166534;font-weight:800}
    tr.fail td:nth-child(2){color:#991b1b;font-weight:800}
    details{margin:2px 0}
    summary{cursor:pointer;color:#334155;font-weight:700}
    table.sub{width:100%;border-collapse:collapse;margin-top:8px;border:1px solid #e2e8f0}
    table.sub th,table.sub td{padding:8px 10px;font-size:12px}
    table.sub th{background:#f8fafc}
    .footer{margin-top:14px;color:#64748b;font-size:12px}
  </style>
</head>
<body>
  <h2 style="margin:0 0 12px 0;">DryRun Report</h2>
  <div class="meta">
    <div><b>Time</b></div><div>${escape.convert(now.toString())}</div>
    <div><b>Module</b></div><div>${escape.convert(moduleName)}</div>
    <div><b>Controller Type</b></div><div>${escape.convert(ctypeText)}</div>
    <div><b>Archive</b></div><div>${escape.convert(archiveName)}</div>
    <div><b>Result</b></div>
    <div>
      <span class="badge pass">PASS ${escape.convert(passCount.toString())}</span>
      <span style="display:inline-block;width:8px"></span>
      <span class="badge fail">FAIL ${escape.convert(failCount.toString())}</span>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th>Target</th>
        <th>Status</th>
        <th>Exit Code</th>
        <th>Details</th>
      </tr>
    </thead>
    <tbody>
      ${rows.join('\n')}
    </tbody>
  </table>

  <div class="footer">Dump folder: ${escape.convert(p.join(_exeDirPath, 'Dump'))}</div>
</body>
</html>
''';

    await reportFile.writeAsString(html, encoding: utf8);
    _appendLog('[Info] Report: ${reportFile.path}');

    try {
      if (Platform.isWindows) {
        await Process.start(
          'cmd',
          ['/c', 'start', '', reportFile.path],
          runInShell: true,
          workingDirectory: _exeDirPath,
        );
      } else if (Platform.isMacOS) {
        await Process.start('open', [reportFile.path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [reportFile.path]);
      }
    } catch (e) {
      _appendLog('[Error] Open report failed: $e');
    }
  }

  Future<void> _runDryRun() async {
    if (_isRunning) return;

    final archivePath = _archivePath;
    if (archivePath == null || archivePath.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先選擇 MPTool .7z 檔案')),
      );
      return;
    }

    final selected = _allPartNumbers.where((p) => p.isSelected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先選擇至少一個 Part Number')),
      );
      return;
    }

    final targetSet = <String>{};
    for (final pn in selected) {
      final vendor = pn.vendor.trim();
      final dirPn =
          pn.dirPn.trim().isNotEmpty ? pn.dirPn.trim() : pn.name.trim();
      if (vendor.isEmpty || dirPn.isEmpty) continue;
      targetSet.add('$vendor/$dirPn');
    }

    if (targetSet.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('選取的資料缺少 Vendor/PartNumber 目錄資訊')),
      );
      return;
    }
    final targets = targetSet.toList()..sort();

    final scriptRel = _findExistingFileRelPath(const [
      'scripts/run_dryrun.py',
      'run_dryrun.py',
    ]);
    if (scriptRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('找不到 scripts/run_dryrun.py，請確認 exe 同層有 scripts 資料夾')),
      );
      return;
    }

    final readFeatureRel = _findExistingFileRelPath(const [
      'scripts/read_feature.py',
      'read_feature.py',
    ]);
    if (readFeatureRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('找不到 scripts/read_feature.py，無法檢查 MPTool CLI 支援')),
      );
      return;
    }

    final devicesDirRel = _findExistingDirRelPath(const [
      'DryRunUI/GeneratedDevices',
      'GeneratedDevices',
    ]);
    if (devicesDirRel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                '找不到 DryRunUI/GeneratedDevices（或 GeneratedDevices），無法執行 dry run')),
      );
      return;
    }

    final pyCmd = await _resolvePythonCommand();
    if (pyCmd == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('找不到可用的 Python（py / python），無法執行 dry run')),
      );
      return;
    }

    setState(() {
      _isRunning = true;
      _stopRequested = false;
      _showOutput = true;
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

    final exe = pyCmd.first;
    final prefixArgs = pyCmd.skip(1).toList();
    final workingDir = _exeDirPath;
    const workRootRel = '_dryrun_work';
    String? workName;
    try {
      final archiveFile = File(archivePath);
      final stat = archiveFile.statSync();
      final stem = p.basenameWithoutExtension(archivePath);
      final safeStem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
      workName =
          'mptool_${safeStem}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {}

    _appendLog('[Info] work-root: $workRootRel');
    if (workName != null) {
      _appendLog('[Info] work-name: $workName');
    }

    final exitCodes = <String, int>{};
    final deviceExitCodesByTarget = <String, Map<String, int>>{};

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
          '--devices-dir',
          devicesDirRel,
          '--output-base',
          '.',
          '--work-root',
          workRootRel,
          '--keep-temp',
        ];
        if (_moduleCtype != null) {
          args.addAll(['--ctype', _moduleCtype.toString()]);
        }
        if (workName != null) {
          args.addAll(['--work-name', workName]);
        }

        final process = await Process.start(
          exe,
          args,
          runInShell: true,
          workingDirectory: workingDir,
        );

        _activeProcess = process;

        final stdoutDone = Completer<void>();
        final stderrDone = Completer<void>();

        deviceExitCodesByTarget[target] = {};

        void handleLine(String line) {
          if (line.startsWith('@@DRYRUN_RUN ')) {
            try {
              final jsonStr = line.substring('@@DRYRUN_RUN '.length);
              final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
              final dev = (obj['device'] ?? '').toString();
              final exit =
                  int.tryParse((obj['exit_code'] ?? '').toString()) ?? -9999;
              if (dev.isNotEmpty) {
                final cur = deviceExitCodesByTarget[target]![dev];
                if (cur == null) {
                  deviceExitCodesByTarget[target]![dev] = exit;
                } else if (cur == 0 && exit != 0) {
                  deviceExitCodesByTarget[target]![dev] = exit;
                }
              }
            } catch (_) {}
          }
          _appendLog(line);
        }

        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              handleLine,
              onDone: () => stdoutDone.complete(),
              onError: (_) => stdoutDone.complete(),
            );

        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              handleLine,
              onDone: () => stderrDone.complete(),
              onError: (_) => stderrDone.complete(),
            );

        final exitCode = await process.exitCode;
        await Future.wait([stdoutDone.future, stderrDone.future]);
        exitCodes[target] = exitCode;
        _appendLog('[Exit] $exitCode');
      }

      if (_openHtmlReport && !_stopRequested && exitCodes.isNotEmpty) {
        await _generateAndOpenHtmlReport(
          archivePath,
          targets,
          exitCodes,
          deviceExitCodesByTarget,
        );
      }
    } catch (e) {
      _appendLog('[Error] $e');
    } finally {
      _activeProcess = null;
      setState(() {
        _isRunning = false;
      });
    }
  }

  void _toggleSelection(int index) {
    final list = _filteredPartNumbers;
    final target = list[index];
    setState(() {
      _allPartNumbers = _allPartNumbers.map((pn) {
        if (pn.flashId == target.flashId && pn.name == target.name) {
          return pn.copyWith(isSelected: !target.isSelected);
        }
        return pn;
      }).toList();
    });
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
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredPartNumbers;
    final archiveText = _archivePath?.trim() ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: Row(
        children: [
          // --- Vendor Sidebar ---
          Container(
            width: 180,
            color: const Color(0xFF2D3748),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title area
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Row(
                    children: [
                      Icon(Icons.memory, color: Colors.white, size: 22),
                      SizedBox(width: 10),
                      Text(
                        'MP Dry Run',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Text(
                    'Flash Configuration Tool',
                    style: TextStyle(
                      color: Color(0xFF718096),
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'VENDOR',
                    style: TextStyle(
                      color: Color(0xFFA0AEC0),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _vendors.length,
                    itemBuilder: (context, index) {
                      final vendor = _vendors[index];
                      final count = vendor == 'All'
                          ? _allPartNumbers.length
                          : _allPartNumbers
                              .where((p) => p.vendor == vendor)
                              .length;
                      final isActive = _selectedVendor == vendor;

                      return InkWell(
                        onTap: () {
                          setState(() => _selectedVendor = vendor);
                          final module = _selectedModule;
                          if (module != null) {
                            SharedPreferences.getInstance().then(
                              (prefs) =>
                                  prefs.setString(_prefsVendor(module), vendor),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFF3182CE)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  vendor,
                                  style: TextStyle(
                                    color: isActive
                                        ? Colors.white
                                        : const Color(0xFFE2E8F0),
                                    fontSize: 13.5,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? Colors.white.withOpacity(0.2)
                                      : const Color(0xFF4A5568),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$count',
                                  style: TextStyle(
                                    color: isActive
                                        ? Colors.white
                                        : const Color(0xFFA0AEC0),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // --- Main Content ---
          Expanded(
            child: Column(
              children: [
                // --- Header ---
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  color: const Color(0xFF2D3748),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isRunning ? null : _pickArchive,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('MPTool'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF3182CE),
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 520,
                        child: Text(
                          archiveText.isEmpty
                              ? 'No archive selected'
                              : archiveText,
                          style: TextStyle(
                            color: archiveText.isEmpty
                                ? Colors.white.withOpacity(0.45)
                                : Colors.white.withOpacity(0.9),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Spacer(),
                      _CompactDropdown<String>(
                        value: _selectedModule,
                        hintText: 'Module',
                        items: _modules
                            .map(
                                (m) => _CompactDropdownItem(value: m, label: m))
                            .toList(),
                        onChanged: (val) {
                          setState(() => _selectedModule = val);
                          _loadPartNumbers();
                        },
                        height: 32,
                        itemHeight: 32,
                        backgroundColor: const Color(0xFF4A5568),
                        borderColor: Colors.white.withOpacity(0.3),
                        textColor: Colors.white,
                        hintColor: Colors.white70,
                        iconColor: Colors.white70,
                        borderRadius:
                            const BorderRadius.all(Radius.circular(8)),
                        menuColor: const Color(0xFF4A5568),
                      ),
                    ],
                  ),
                ),

                // --- Stats Bar ---
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Text('Total: ${_allPartNumbers.length}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 24),
                      Text(
                          'Selected: ${_allPartNumbers.where((p) => p.isSelected).length}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 24),
                      Text(
                        'Controller Type: ${_moduleCtype?.toString() ?? '-'}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 24),
                      // Group controls
                      OutlinedButton.icon(
                        onPressed: _saveGroup,
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('Save'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF3182CE),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _CompactDropdown<String>(
                        value: _selectedGroup,
                        hintText: 'Load Group',
                        items: _groups
                            .map(
                                (g) => _CompactDropdownItem(value: g, label: g))
                            .toList(),
                        onChanged: (val) {
                          _loadGroup(val);
                        },
                        height: 32,
                        itemHeight: 32,
                        backgroundColor: Colors.white,
                        borderColor: Colors.grey.shade300,
                        textColor: Colors.black87,
                        hintColor: Colors.black45,
                        iconColor: Colors.black45,
                        menuColor: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: _deleteGroup,
                        icon: Icon(Icons.delete_outline,
                            size: 18, color: Colors.grey.shade600),
                        tooltip: 'Delete Group',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _openHtmlReport,
                            onChanged: _isRunning
                                ? null
                                : (v) {
                                    final next = v ?? false;
                                    setState(() => _openHtmlReport = next);
                                    SharedPreferences.getInstance().then(
                                      (prefs) => prefs.setBool(
                                          _prefsOpenHtmlReport, next),
                                    );
                                  },
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                          ),
                          Text(
                            'Report',
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () =>
                            setState(() => _showOutput = !_showOutput),
                        icon: Icon(
                          _showOutput ? Icons.subject : Icons.subject_outlined,
                          size: 18,
                          color: Colors.grey.shade700,
                        ),
                        tooltip: _showOutput ? 'Hide Output' : 'Show Output',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 12),
                      if (_isRunning)
                        OutlinedButton.icon(
                          onPressed: _stopRun,
                          icon: const Icon(Icons.stop, size: 16),
                          label: const Text('Stop'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      if (_isRunning) const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isRunning ? null : _runDryRun,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: Text(_isRunning ? 'Running...' : 'Run Dry Run'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3182CE),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ),

                // --- Table Header ---
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  color: const Color(0xFFE2E8F0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: Checkbox(
                          value: _selectAll,
                          onChanged: (_) => _toggleSelectAll(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _headerCell('#', 40),
                      _headerCell('PART NUMBER', 280),
                      _headerCell('FLASH ID', 200),
                      _headerCell('DIE', 50, center: true),
                      _headerCell('CELL TYPE', 70, center: true),
                      _headerCell('PLANE', 60, center: true),
                      const Expanded(child: _HeaderText('ALIAS')),
                    ],
                  ),
                ),

                // --- Data List ---
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : filtered.isEmpty
                                ? const Center(child: Text('No data'))
                                : ListView.builder(
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final pn = filtered[index];
                                      final rowKey = '${pn.flashId}|${pn.name}';
                                      final isHovered =
                                          _hoveredRowKey == rowKey;
                                      final baseColor = pn.isSelected
                                          ? const Color(0xFFEAF4FF)
                                          : (index.isEven
                                              ? Colors.white
                                              : const Color(0xFFF7FAFC));
                                      final rowColor = isHovered
                                          ? const Color(0xFFDCEBFF)
                                          : baseColor;

                                      return MouseRegion(
                                        onEnter: (_) => setState(
                                            () => _hoveredRowKey = rowKey),
                                        onExit: (_) => setState(() {
                                          if (_hoveredRowKey == rowKey) {
                                            _hoveredRowKey = null;
                                          }
                                        }),
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _toggleSelection(index),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 24, vertical: 8),
                                            color: rowColor,
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  width: 40,
                                                  child: AbsorbPointer(
                                                    child: Checkbox(
                                                      value: pn.isSelected,
                                                      onChanged: (_) {},
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                _dataCell('${index + 1}', 40,
                                                    color: Colors.grey),
                                                _dataCell(pn.name, 280,
                                                    weight: FontWeight.w600),
                                                _dataCell(pn.flashId, 200,
                                                    mono: true,
                                                    color:
                                                        Colors.grey.shade700),
                                                _dataCell(pn.die, 50,
                                                    center: true),
                                                _dataCell(pn.cellType, 70,
                                                    center: true),
                                                _dataCell(pn.plane, 60,
                                                    center: true),
                                                Expanded(
                                                  child: Text(
                                                    pn.alias,
                                                    style: TextStyle(
                                                      color:
                                                          Colors.grey.shade600,
                                                      fontSize: 13,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                      ),
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

  Widget _buildOutputPanel() {
    return Container(
      height: 220,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border(
          top: BorderSide(color: Colors.black.withOpacity(0.08), width: 1),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              border: Border(
                bottom: BorderSide(color: Colors.white.withOpacity(0.08)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  _isRunning ? 'Output (Running)' : 'Output',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _runLog.clear()),
                  child: const Text(
                    'Clear',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _runLog.isEmpty
                ? const Center(
                    child: Text(
                      'No output',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    itemCount: _runLog.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _runLog[index],
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontFamily: 'Courier New',
                          height: 1.35,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(String text, double width, {bool center = false}) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF718096),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _dataCell(String text, double width,
      {bool center = false,
      FontWeight weight = FontWeight.normal,
      bool mono = false,
      Color? color}) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: weight,
          fontFamily: mono ? 'Courier New' : null,
          color: color ?? Colors.black87,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  final String text;
  const _HeaderText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: Color(0xFF718096),
        letterSpacing: 0.5,
      ),
    );
  }
}

class _CompactDropdownItem<T> {
  final T value;
  final String label;

  const _CompactDropdownItem({required this.value, required this.label});
}

class _CompactDropdown<T> extends StatelessWidget {
  final T? value;
  final String hintText;
  final List<_CompactDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  final double height;
  final double itemHeight;
  final Color backgroundColor;
  final Color borderColor;
  final Color textColor;
  final Color hintColor;
  final Color iconColor;
  final Color menuColor;
  final double fontSize;
  final BorderRadius borderRadius;

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
    this.fontSize = 13,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  @override
  Widget build(BuildContext context) {
    String? selected;
    if (value != null) {
      for (final it in items) {
        if (it.value == value) {
          selected = it.label;
          break;
        }
      }
    }

    return SizedBox(
      height: height,
      child: PopupMenuButton<T>(
        padding: EdgeInsets.zero,
        tooltip: '',
        offset: Offset(0, height),
        color: menuColor,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(color: borderColor, width: 1),
        ),
        onSelected: onChanged,
        itemBuilder: (context) {
          return items
              .map(
                (it) => PopupMenuItem<T>(
                  value: it.value,
                  height: itemHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    it.label,
                    style: TextStyle(
                      fontSize: fontSize,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList();
        },
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                selected ?? hintText,
                style: TextStyle(
                  fontSize: fontSize,
                  color: selected == null ? hintColor : textColor,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: 6),
              Icon(Icons.expand_more, size: 18, color: iconColor),
            ],
          ),
        ),
      ),
    );
  }
}
