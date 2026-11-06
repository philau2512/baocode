import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent_kernel.dart';

/// Reads Antigravity CLI's local chat records from `~/.gemini/tmp`.
class AgyStorage implements SessionCatalog {
  const AgyStorage({this.home});

  @override
  Future<void> delete(String id) async {
    if (id.trim().isEmpty) return;
    final brain = _brain(id);
    if (await brain.exists()) await brain.delete(recursive: true);
    await _deleteOldRecords(id);
    await _deleteMetadata(id);
  }

  Future<void> _deleteOldRecords(String id) async {
    if (!await _root.exists()) return;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      for (final file in await _chatFiles(entity)) {
        try {
          final raw = jsonDecode(await file.readAsString());
          if (raw is Map && _string(raw['sessionId']) == id) {
            await file.delete();
          }
        } on Object {
          // A malformed legacy record should not prevent deleting the session.
        }
      }
    }
  }

  Future<void> _deleteMetadata(String id) async {
    if (!await _metadata.exists()) return;
    try {
      final raw = jsonDecode(await _metadata.readAsString());
      if (raw is! Map || raw['conversations'] is! Map) return;
      final conversations = (raw['conversations'] as Map).cast<Object?, Object?>();
      if (conversations.remove(id) == null) return;
      await _metadata.writeAsString(jsonEncode({
        ...raw.cast<Object?, Object?>(),
        'conversations': conversations,
      }));
    } on Object {
      // The transcript is already removed; stale metadata is harmless.
    }
  }

  final String? home;

  Directory get _home => Directory(
    home ?? Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.',
  );

  Directory get _root => Directory(p.join(_home.path, '.gemini', 'tmp'));
  Directory get _newRoot => Directory(
    p.join(_home.path, '.gemini', 'antigravity-cli'),
  );

  File get _metadata => File(
    p.join(_newRoot.path, 'cache', 'conversation_metadata.json'),
  );

  Directory _brain(String id) => Directory(p.join(_newRoot.path, 'brain', id));

  File _transcript(String id) => File(
    p.join(
      _brain(id).path,
      '.system_generated',
      'logs',
      'transcript_full.jsonl',
    ),
  );

  File _transcriptFallback(String id) => File(
    p.join(
      _brain(id).path,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    ),
  );

  Future<Map<String, Map<String, Object?>>> _conversationMetadata() async {
    if (!await _metadata.exists()) return const {};
    try {
      final raw = jsonDecode(await _metadata.readAsString());
      final conversations = raw is Map ? raw['conversations'] : null;
      if (conversations is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in conversations.entries)
          if (value is Map) '$key': value.cast<String, Object?>(),
      };
    } on Object {
      return const {};
    }
  }

  Future<List<SessionRecord>> _newRecords() async {
    final metadata = await _conversationMetadata();
    final brainRoot = Directory(p.join(_newRoot.path, 'brain'));
    if (!await brainRoot.exists()) return const [];
    final records = <SessionRecord>[];
    await for (final entity in brainRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      final file = _transcript(id);
      final fallback = _transcriptFallback(id);
      if (!await file.exists() && !await fallback.exists()) continue;
      final summary = metadata[id]?['summary'];
      final summaryMap = summary is Map
          ? summary.cast<String, Object?>()
          : const <String, Object?>{};
      final cwd = _workspace(summaryMap['WorkspaceURIs']);
      if (cwd == null) continue;
      final updated = DateTime.tryParse(
            _string(summaryMap['UpdatedAt']) ?? '',
          ) ??
          (await (await file.exists() ? file : fallback).stat()).modified;
      final title = _string(summaryMap['Preview']) ?? '';
      records.add(
        SessionRecord(
          id: id,
          title: _title(title),
          updatedAt: updated.toLocal(),
          cwd: cwd,
          path: (await file.exists() ? file : fallback).path,
        ),
      );
    }
    return records;
  }

  static String? _workspace(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final uri = Uri.tryParse('${raw.first}');
    if (uri == null || uri.path.isEmpty) return null;
    var path = Uri.decodeComponent(uri.path);
    if (Platform.isWindows &&
        path.length >= 3 &&
        path[0] == '/' &&
        RegExp(r'[A-Za-z]:').hasMatch(path.substring(1, 3))) {
      path = path.substring(1).replaceAll('/', '\\');
    }
    return p.normalize(path);
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final records = <String, SessionRecord>{
      for (final record in await _newRecords()) record.id: record,
    };
    final root = _root;
    if (root.existsSync()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        for (final file in await _chatFiles(entity)) {
          final record = await _record(file);
          if (record != null) records.putIfAbsent(record.id, () => record);
        }
      }
    }
    final byPath = <String, List<SessionRecord>>{};
    for (final record in records.values) {
      byPath.putIfAbsent(record.cwd, () => []).add(record);
    }
    return _projects(byPath);
  }

  static List<ProjectRecord> _projects(
    Map<String, List<SessionRecord>> byPath,
  ) => [
    for (final entry in byPath.entries)
      ProjectRecord(path: entry.key, sessions: _sorted(entry.value)),
  ]..sort((a, b) =>
      (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final projects = await this.projects();
    return projects.where((project) => project.path == cwd).firstOrNull?.sessions ?? const [];
  }

  Future<List<File>> _chatFiles(Directory project) async => [
    for (final entity in await project.list(followLinks: false).toList())
      if (entity is File && p.basename(entity.path).startsWith('session-') && p.extension(entity.path) == '.json') entity,
  ];

  Future<SessionRecord?> _record(File file) async {
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final json = raw.cast<String, Object?>();
      final id = _string(json['sessionId']);
      final projectHash = _string(json['projectHash']);
      if (id == null || projectHash == null) return null;
      final messages = json['messages'] is List ? json['messages'] as List : const [];
      final firstPrompt = messages.cast<Object?>().map(_map).map((m) => _string(m['content'])).whereType<String>().firstOrNull;
      final updated = DateTime.tryParse(_string(json['lastUpdated']) ?? '') ?? (await file.stat()).modified;
      final cwd = await _cwdForConversation(id) ?? _string(json['cwd']);
      if (cwd == null) return null;
      return SessionRecord(
        id: id,
        title: firstPrompt == null ? '' : _title(firstPrompt),
        updatedAt: updated.toLocal(),
        cwd: cwd,
        path: file.path,
      );
    } on Object {
      return null;
    }
  }

  Future<String?> _cwdForConversation(String id) async {
    final metadata = File(p.join(_root.path, '..', 'antigravity-cli', 'cache', 'conversation_metadata.json'));
    if (!metadata.existsSync()) return null;
    try {
      final raw = jsonDecode(await metadata.readAsString());
      final conversations = raw is Map ? raw['conversations'] : null;
      if (conversations is! Map) return null;
      for (final MapEntry(:key, :value) in conversations.entries) {
        if ('$key' != id) continue;
        final summary = value is Map ? value['summary'] : null;
        if (summary is! Map) continue;
        final workspaces = summary['WorkspaceURIs'];
        if (workspaces is List && workspaces.isNotEmpty) {
          final uri = Uri.tryParse('${workspaces.first}');
          if (uri != null && uri.path.isNotEmpty) return Uri.decodeComponent(uri.path);
        }
      }
    } on Object {
      // Metadata is optional; session records without a resolvable workspace
      // are ignored by the caller.
    }
    return null;
  }

  static List<SessionRecord> _sorted(List<SessionRecord> records) => [...records]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  static String? _string(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
  static Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : const {};
  static String _title(String text) {
    final line = text.split('\n').first.trim().replaceFirst(RegExp(r'^/\S+\s*'), '');
    return line.substring(0, line.length > 80 ? 80 : line.length);
  }
}
