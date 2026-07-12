import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import '../models/models.dart';

// FFI Signatures
typedef UnilabInitNative = Int32 Function(Pointer<Utf8> backendPath);
typedef UnilabInit = int Function(Pointer<Utf8> backendPath);

typedef UnilabCreateSessionNative = Pointer<Utf8> Function(Pointer<Utf8> username);
typedef UnilabCreateSession = Pointer<Utf8> Function(Pointer<Utf8> username);

typedef UnilabExecuteNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> code, Double timeout);
typedef UnilabExecute = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> code, double timeout);

typedef UnilabExecuteWithFilenameNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> code, Pointer<Utf8> filename, Double timeout);
typedef UnilabExecuteWithFilename = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> code, Pointer<Utf8> filename, double timeout);

typedef UnilabGetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId);
typedef UnilabGetWorkspace = Pointer<Utf8> Function(Pointer<Utf8> sessionId);

typedef UnilabGetAutocompleteNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> text, Pointer<Utf8> line);
typedef UnilabGetAutocomplete = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> text, Pointer<Utf8> line);

typedef UnilabListFilesNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId);
typedef UnilabListFiles = Pointer<Utf8> Function(Pointer<Utf8> sessionId);

typedef UnilabTranspileNative = Pointer<Utf8> Function(Pointer<Utf8> code);
typedef UnilabTranspile = Pointer<Utf8> Function(Pointer<Utf8> code);

typedef UnilabCreateFileNative = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> filename, Pointer<Utf8> content);
typedef UnilabCreateFile = Pointer<Utf8> Function(Pointer<Utf8> sessionId, Pointer<Utf8> filename, Pointer<Utf8> content);

typedef UnilabFreeStringNative = Void Function(Pointer<Utf8> ptr);
typedef UnilabFreeString = void Function(Pointer<Utf8> ptr);

typedef UnilabPingNative = Int32 Function();
typedef UnilabPing = int Function();

typedef WorkspaceCallbackNative = Void Function(Pointer<Utf8> sessionId, Pointer<Utf8> variablesJson);
typedef UnilabSetWorkspaceCallbackNative = Void Function(Pointer<NativeFunction<WorkspaceCallbackNative>> callback);
typedef UnilabSetWorkspaceCallback = void Function(Pointer<NativeFunction<WorkspaceCallbackNative>> callback);
typedef EventCallbackNative = Void Function(Pointer<Utf8> sessionId, Pointer<Utf8> eventType, Pointer<Utf8> dataJson);
typedef UnilabSetEventCallbackNative = Void Function(Pointer<NativeFunction<EventCallbackNative>> callback);
typedef UnilabSetEventCallback = void Function(Pointer<NativeFunction<EventCallbackNative>> callback);

typedef UnilabSendSimEventNative = Void Function(Pointer<Utf8> eventJson);
typedef UnilabSendSimEvent = void Function(Pointer<Utf8> eventJson);


class UniLabBridge {
  static UniLabBridge? _instance;
  static final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  // Shared library and free function (available in main isolate)
  static DynamicLibrary? _mainLib;
  static UnilabFreeString? _unilabFreeString;

  String? _sessionId;
  bool _initialized = false;
  
  // Keep callback alive
  NativeCallable<WorkspaceCallbackNative>? _wsCallback;
  NativeCallable<EventCallbackNative>? _eventCallback;

  // Isolate communication
  SendPort? _workerSendPort;
  final ReceivePort _mainReceivePort = ReceivePort();
  final Completer<void> _workerReady = Completer<void>();

  UniLabBridge._() {
    _startWorker();
  }

  static UniLabBridge get instance {
    _instance ??= UniLabBridge._();
    return _instance!;
  }

  static void resetInstance() {
    _instance?._initialized = false;
    _instance?._workerSendPort?.send({'command': 'shutdown'});
    _instance = null;
  }

  String? get sessionId => _sessionId;
  bool get initialized => _initialized;
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  static DynamicLibrary _loadLibraryHandle(String backendPath) {
    String libName = Platform.isLinux ? 'libunilab_core.so' : (Platform.isMacOS ? 'libunilab_core.dylib' : 'unilab_core.dll');
    
    // In a packaged build, the library will be in a known relative location.
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    final locations = [
      // Packaged paths
      p.join(exeDir, 'lib', libName), 
      p.join(exeDir, '..', 'Frameworks', libName), // macOS Frameworks dir
      p.join(exeDir, libName),
      // Path for bundled python dependencies
      p.join(p.dirname(exeDir), 'python', 'lib', libName),
      // Dev paths for local testing
      p.join(backendPath, 'target', 'release', libName),
      p.join(backendPath, 'target', 'debug', libName),
      libName,
    ];
    
    for (final loc in locations) {
      try {
        debugPrint('[UniLabBridge] Attempting to load library from: $loc');
        return DynamicLibrary.open(loc);
      } catch (e) {
        debugPrint('[UniLabBridge] Failed to load from $loc: $e');
      }
    }
    throw Exception('Could not load library $libName. Searched in: $locations');
  }

  Future<void> _startWorker() async {
    await Isolate.spawn(_workerEntry, _mainReceivePort.sendPort);
    
    _mainReceivePort.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        _workerReady.complete();
      } else if (message is Map<String, dynamic>) {
        if (message['type'] == 'event') {
          _eventController.add(message);
        }
      }
    });
  }

  Future<dynamic> _sendCommand(String command, Map<String, dynamic> params) async {
    await _workerReady.future;
    final responsePort = ReceivePort();
    _workerSendPort!.send({
      'command': command,
      'params': params,
      'replyPort': responsePort.sendPort,
    });
    
    try {
      final result = await responsePort.first.timeout(const Duration(seconds: 300));
      if (result is Map && result['error'] != null) {
        throw Exception(result['error']);
      }
      return result;
    } on TimeoutException {
      throw Exception('Command $command timed out');
    } finally {
      responsePort.close();
    }
  }

  /// Initialize the bridge.
  Future<void> initialize() async {
    if (_initialized) return;

    debugPrint('[UniLabBridge] Starting initialization sequence...');

    // 1. Resolve paths
    final backendPath = await findBackendPath();
    debugPrint('[UniLabBridge] Resolved backend path: $backendPath');

    // 2. Load library in main isolate (for callbacks)
    _mainLib = _loadLibraryHandle(backendPath);
    _unilabFreeString = _mainLib!.lookupFunction<UnilabFreeStringNative, UnilabFreeString>('unilab_free_string');

    _wsCallback = NativeCallable<WorkspaceCallbackNative>.listener(_onWorkspaceChanged);
    _eventCallback = NativeCallable<EventCallbackNative>.listener(_onSimEvent);
    
    final unilabSetWorkspaceCallback = _mainLib!.lookupFunction<UnilabSetWorkspaceCallbackNative, UnilabSetWorkspaceCallback>('unilab_set_workspace_callback');
    unilabSetWorkspaceCallback(_wsCallback!.nativeFunction);

    final unilabSetEventCallback = _mainLib!.lookupFunction<UnilabSetEventCallbackNative, UnilabSetEventCallback>('unilab_set_event_callback');
    unilabSetEventCallback(_eventCallback!.nativeFunction);

    // 3. Initialize worker isolate and wait for backend readiness
    await _sendCommand('initialize', {'backendPath': backendPath});

    bool isReady = false;
    int retries = 0;
    const maxRetries = 20;
    
    while (!isReady && retries < maxRetries) {
      try {
        final res = await _sendCommand('ping', {});
        if (res['success'] == true) {
          isReady = true;
          debugPrint('[UniLabBridge] Backend is ready after ${retries + 1} checks.');
        } else {
          throw Exception('Ping failed');
        }
      } catch (e) {
        retries++;
        debugPrint('[UniLabBridge] Backend not ready yet (Attempt $retries/$maxRetries). Waiting...');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    if (!isReady) {
      throw StateError('Backend failed to reach ready state after $maxRetries attempts.');
    }

    _initialized = true;
    debugPrint('[UniLabBridge] Bridge and Backend initialized successfully.');
  }

  static void _onSimEvent(Pointer<Utf8> sessionIdPtr, Pointer<Utf8> eventTypePtr, Pointer<Utf8> dataJsonPtr) {
    if (sessionIdPtr.address == 0 || eventTypePtr.address == 0 || dataJsonPtr.address == 0) return;

    final sessionId = sessionIdPtr.toDartString();
    final eventType = eventTypePtr.toDartString();
    final dataJson = dataJsonPtr.toDartString();
    
    _unilabFreeString?.call(sessionIdPtr);
    _unilabFreeString?.call(eventTypePtr);
    _unilabFreeString?.call(dataJsonPtr);
    
    try {
      final data = jsonDecode(dataJson);
      _eventController.add({
        'type': 'sim_event',
        'event': eventType,
        'session_id': sessionId,
        'data': data,
      });
    } catch (e) {
      debugPrint('[UniLabBridge] Error parsing sim event: $e');
    }
  }

  static void _onWorkspaceChanged(Pointer<Utf8> sessionIdPtr, Pointer<Utf8> variablesJsonPtr) {
    if (sessionIdPtr.address == 0 || variablesJsonPtr.address == 0) return;

    final sessionId = sessionIdPtr.toDartString();
    final variablesJson = variablesJsonPtr.toDartString();
    
    _unilabFreeString?.call(sessionIdPtr);
    _unilabFreeString?.call(variablesJsonPtr);
    
    try {
      final variables = jsonDecode(variablesJson) as Map<String, dynamic>;
      _eventController.add({
        'type': 'event',
        'event': 'workspace_updated',
        'session_id': sessionId,
        'variables': variables,
      });
    } catch (e) {
      debugPrint('[UniLabBridge] Error parsing workspace update: $e');
    }
  }

  /// Create a new session
  Future<String> createSession(String username) async {
    final response = await _sendCommand('create_session', {'username': username});
    _sessionId = response['session_id'];
    return _sessionId!;
  }

  /// Execute code in the current session
  Future<ExecutionResult> execute(String code, {String? filename, double timeout = 300.0}) async {
    if (_sessionId == null) throw StateError('Session not created');
    final response = await _sendCommand('execute', {
      'sessionId': _sessionId,
      'code': code,
      'filename': filename,
      'timeout': timeout,
    });
    return ExecutionResult.fromJson(response);
  }

  /// Get workspace variables
  Future<Map<String, dynamic>> getWorkspace() async {
    if (_sessionId == null) return {};
    final response = await _sendCommand('get_workspace', {'sessionId': _sessionId});
    return response['variables'] ?? {};
  }

  /// Get autocomplete suggestions
  Future<List<String>> getAutocomplete(String text, {String? fullLine}) async {
    if (_sessionId == null) return [];
    final response = await _sendCommand('get_autocomplete', {
      'sessionId': _sessionId,
      'text': text,
      'line': fullLine ?? text,
    });
    return List<String>.from(response['suggestions'] ?? []);
  }

  /// List files in the session workspace
  Future<List<Map<String, dynamic>>> listFiles() async {
    if (_sessionId == null) {
      // If session isn't created, we can't list files, but we can't use this as a ping.
      // Let's create a temporary session if needed for the ping.
      return [];
    }
    final response = await _sendCommand('list_files', {'sessionId': _sessionId});
    return List<Map<String, dynamic>>.from(response['files'] ?? []);
  }

  /// Transpile code to Python
  Future<String> transpile(String code) async {
    final response = await _sendCommand('transpile', {'code': code});
    if (response['success'] == true) {
      return response['python_code'];
    } else {
      throw Exception(response['error'] ?? 'Transpilation failed');
    }
  }

  /// Send an event to the active simulation
  Future<void> sendSimEvent(Map<String, dynamic> event) async {
    await _sendCommand('send_sim_event', {'event': jsonEncode(event)});
  }

  Future<void> createFile(String filename, String content) async {
    if (_sessionId == null) return;
    await _sendCommand('create_file', {
      'sessionId': _sessionId,
      'filename': filename,
      'content': content,
    });
  }

  Future<Map<String, dynamic>> getInfo() async {
    return {
      'version': '0.1.0 (FFI-Worker)',
      'name': 'UniLab Core FFI Worker',
      'status': 'active',
      'capabilities': ['execution', 'workspace', 'files', 'autocomplete']
    };
  }

  static Future<String> findBackendPath() async {
    final exePath = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final exeDir = Directory(exePath).parent.path;
    
    final locations = [
      p.dirname(exeDir), // To find /opt/unilab when exeDir is /opt/unilab/gui
      p.join(exeDir, 'backend'), 
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'backend'),
      p.join(exeDir, '..', 'Resources', 'flutter_assets', 'assets', 'backend'),
      Directory.current.path,
    ];

    final envPath = Platform.environment['UNILAB_BACKEND_PATH'];
    if (envPath != null) {
      locations.insert(0, envPath);
    }

    for (final path in locations) {
      final backendDir = p.join(path, 'backend');
      if (await Directory(backendDir).exists()) {
        return path;
      }
    }
    throw StateError('Cannot find backend directory. Searched in: $locations');
  }

  static Future<String> findSamplesPath() async {
    final exePath = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final exeDir = Directory(exePath).parent.path;

    final locations = [
      p.join(exeDir, 'sample'),
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'samples'),
      p.join(exeDir, '..', 'Resources', 'flutter_assets', 'assets', 'samples'),
      p.join(Directory.current.path, 'sample'),
      p.join(Directory.current.path, 'assets', 'samples'),
    ];

    for (final path in locations) {
      if (await Directory(path).exists()) return path;
    }
    return p.join(Directory.current.path, 'sample'); // Fallback
  }

  // --- Worker Isolate Entry Point ---
  static void _workerEntry(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);

    late DynamicLibrary lib;
    late UnilabInit unilabInit;
    late UnilabCreateSession unilabCreateSession;
    late UnilabExecute unilabExecute;
    late UnilabExecuteWithFilename unilabExecuteWithFilename;
    late UnilabGetWorkspace unilabGetWorkspace;
    late UnilabGetAutocomplete unilabGetAutocomplete;
    late UnilabListFiles unilabListFiles;
    late UnilabTranspile unilabTranspile;
    late UnilabCreateFile unilabCreateFile;
    late UnilabSendSimEvent unilabSendSimEvent;
    late UnilabPing unilabPing;
    late UnilabFreeString unilabFreeString;

    workerReceivePort.listen((message) {
      if (message is! Map) return;
      final command = message['command'];
      final params = message['params'] ?? {};
      final SendPort? replyPort = message['replyPort'];

      try {
        switch (command) {
          case 'initialize':
            final backendPath = params['backendPath'] as String;
            lib = _loadLibraryHandle(backendPath);

            unilabInit = lib.lookupFunction<UnilabInitNative, UnilabInit>('unilab_init');
            unilabCreateSession = lib.lookupFunction<UnilabCreateSessionNative, UnilabCreateSession>('unilab_create_session');
            unilabExecute = lib.lookupFunction<UnilabExecuteNative, UnilabExecute>('unilab_execute');
            unilabExecuteWithFilename = lib.lookupFunction<UnilabExecuteWithFilenameNative, UnilabExecuteWithFilename>('unilab_execute_with_filename');
            unilabGetWorkspace = lib.lookupFunction<UnilabGetWorkspaceNative, UnilabGetWorkspace>('unilab_get_workspace');
            unilabGetAutocomplete = lib.lookupFunction<UnilabGetAutocompleteNative, UnilabGetAutocomplete>('unilab_get_autocomplete');
            unilabListFiles = lib.lookupFunction<UnilabListFilesNative, UnilabListFiles>('unilab_list_files');
            unilabTranspile = lib.lookupFunction<UnilabTranspileNative, UnilabTranspile>('unilab_transpile');
            unilabCreateFile = lib.lookupFunction<UnilabCreateFileNative, UnilabCreateFile>('unilab_create_file');
            unilabSendSimEvent = lib.lookupFunction<UnilabSendSimEventNative, UnilabSendSimEvent>('unilab_send_sim_event');
            unilabPing = lib.lookupFunction<UnilabPingNative, UnilabPing>('unilab_ping');
            unilabFreeString = lib.lookupFunction<UnilabFreeStringNative, UnilabFreeString>('unilab_free_string');

            final pathPtr = backendPath.toNativeUtf8();
            unilabInit(pathPtr);
            malloc.free(pathPtr);
            
            replyPort?.send({'success': true});
            break;

          case 'ping':
            final res = unilabPing();
            replyPort?.send({'success': res == 0});
            break;

          case 'create_session':
            final userPtr = (params['username'] as String).toNativeUtf8();
            final resPtr = unilabCreateSession(userPtr);
            malloc.free(userPtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'execute':
            final sidPtr = (params['sessionId'] as String).toNativeUtf8();
            final codePtr = (params['code'] as String).toNativeUtf8();
            final filename = params['filename'] as String?;
            final timeout = (params['timeout'] as num?)?.toDouble() ?? 300.0;
            
            Pointer<Utf8> resPtr;
            if (filename != null) {
              final filePtr = filename.toNativeUtf8();
              resPtr = unilabExecuteWithFilename(sidPtr, codePtr, filePtr, timeout);
              malloc.free(filePtr);
            } else {
              resPtr = unilabExecute(sidPtr, codePtr, timeout);
            }
            malloc.free(sidPtr);
            malloc.free(codePtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'get_workspace':
            final sidPtr = (params['sessionId'] as String).toNativeUtf8();
            final resPtr = unilabGetWorkspace(sidPtr);
            malloc.free(sidPtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'get_autocomplete':
            final sidPtr = (params['sessionId'] as String).toNativeUtf8();
            final textPtr = (params['text'] as String).toNativeUtf8();
            final linePtr = (params['line'] as String? ?? params['text'] as String).toNativeUtf8();
            final resPtr = unilabGetAutocomplete(sidPtr, textPtr, linePtr);
            malloc.free(sidPtr);
            malloc.free(textPtr);
            malloc.free(linePtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'list_files':
            final sidPtr = (params['sessionId'] as String).toNativeUtf8();
            final resPtr = unilabListFiles(sidPtr);
            malloc.free(sidPtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'transpile':
            final codePtr = (params['code'] as String).toNativeUtf8();
            final resPtr = unilabTranspile(codePtr);
            malloc.free(codePtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'send_sim_event':
            final evPtr = (params['event'] as String).toNativeUtf8();
            unilabSendSimEvent(evPtr);
            malloc.free(evPtr);
            replyPort?.send({'success': true});
            break;

          case 'create_file':
            final sidPtr = (params['sessionId'] as String).toNativeUtf8();
            final namePtr = (params['filename'] as String).toNativeUtf8();
            final contPtr = (params['content'] as String).toNativeUtf8();
            final resPtr = unilabCreateFile(sidPtr, namePtr, contPtr);
            malloc.free(sidPtr);
            malloc.free(namePtr);
            malloc.free(contPtr);
            final res = jsonDecode(resPtr.toDartString());
            unilabFreeString(resPtr);
            replyPort?.send(res);
            break;

          case 'shutdown':
            Isolate.exit();
        }
      } catch (e) {
        replyPort?.send({'error': e.toString()});
      }
    });
  }
}
