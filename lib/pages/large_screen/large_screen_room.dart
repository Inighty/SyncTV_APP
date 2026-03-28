import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:synctv_app/models/watch_together_models.dart';
import 'package:synctv_app/models/simple_proto.dart';
import 'package:synctv_app/services/watch_together_service.dart';
import 'package:synctv_app/widgets/add_movie_dialog.dart';
import 'package:synctv_app/widgets/custom_video_player.dart';
import 'package:synctv_app/managers/webrtc_manager.dart';
import 'package:synctv_app/models/danmaku_model.dart';

class LargeScreenRoom extends StatefulWidget {
  final WRoom room;

  const LargeScreenRoom({super.key, required this.room});

  @override
  State<LargeScreenRoom> createState() => _LargeScreenRoomState();
}

class _LargeScreenRoomState extends State<LargeScreenRoom> {
  // BetterPlayer（基于 ExoPlayer，解决 Android TV 画面问题）
  BetterPlayerController? _betterPlayerController;
  String _currentUrl = '';
  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _movieScrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  Timer? _syncTimer;
  WPlaybackStatus? _currentStatus;
  WebSocketChannel? _channel;
  List<WUser> _members = [];
  List<WMovie> _movies = [];
  bool _isLoadingMovies = true;
  
  // Pagination
  int _currentPage = 1;
  final int _pageSize = 20;
  bool _hasMoreMovies = true;
  bool _isLoadingMoreMovies = false;

  // Folder navigation
  List<WMovie> _folderStack = [];
  List<String> _folderNameStack = ['根目录'];

  WUser? _currentUser;

  // Sync state
  bool _isSyncing = false;
  Timer? _updateDebounce;
  bool _lastPlaying = false;
  double _lastRate = 1.0;
  double _lastPosition = 0.0;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;

  StreamSubscription? _authErrorSubscription;

  // WebRTC
  WebRTCManager? _webrtcManager;
  
  // Danmaku Stream
  final DanmakuController _danmakuController = DanmakuController();

  // TV Focus Handling
  final FocusNode _videoFocus = FocusNode();
  final FocusNode _movieListFocus = FocusNode();
  
  // Side Panel State
  bool _showSidePanel = false;
  int _selectedTabIndex = 0; // 0: Movies, 1: Chat, 2: Members

  @override
  void initState() {
    super.initState();
    // Force landscape
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _authErrorSubscription = WatchTogetherService.onAuthError.listen((_) {
      if (mounted) {
        _disposeVideoController();
        _channel?.sink.close();
        _reconnectTimer?.cancel();
        _webrtcManager?.leave();
        Navigator.of(context).pop();
      }
    });
    
    // Initialize WebRTC Manager (simplified for TV - usually listen only or no mic)
    _webrtcManager = WebRTCManager(
      onSignalingMessage: (type, data) {
        if (_channel != null) {
          MessageType msgType;
          switch (type) {
            case 'offer': msgType = MessageType.WEBRTC_OFFER; break;
            case 'answer': msgType = MessageType.WEBRTC_ANSWER; break;
            case 'candidate': msgType = MessageType.WEBRTC_ICE_CANDIDATE; break;
            case 'join': msgType = MessageType.WEBRTC_JOIN; break;
            case 'leave': msgType = MessageType.WEBRTC_LEAVE; break;
            default: return;
          }
          
          try {
            final payload = {'data': jsonEncode(data)};
            if (data['to'] != null) {
              payload['to'] = data['to'];
            }
            final bytes = SimpleProto.encodeWebRTC(msgType, payload);
            _channel!.sink.add(bytes);
          } catch (e) {
            debugPrint('WebRTC encode error: $e');
          }
        }
      },
      onStateChange: () {
        if (mounted) setState(() {});
      },
    );
    
    _joinRoom();
  }

  Future<void> _joinRoom() async {
    _connectWebSocket();
    _syncState();
    await Future.wait([
      _fetchCurrentUser(),
      _fetchMembers(),
      _fetchMovies(),
    ]);
  }

  // Reuse fetch methods from other screens...
  Future<void> _fetchCurrentUser() async {
    try {
      final user = await WatchTogetherService.getMe();
      if (mounted) setState(() => _currentUser = user);
    } catch (_) {}
  }

  Future<void> _fetchMembers() async {
    try {
      final members = await WatchTogetherService.getRoomMembers(widget.room.roomId);
      if (mounted) setState(() => _members = members);
    } catch (_) {}
  }

  Future<void> _fetchMovies() async {
    try {
      _currentPage = 1;
      _hasMoreMovies = true;
      final parentFolder = _folderStack.isNotEmpty ? _folderStack.last : null;
      final result = await WatchTogetherService.getMovies(
        widget.room.roomId, 
        parentId: parentFolder?.id,
        subPath: parentFolder?.subPath,
        page: 1,
        max: _pageSize
      );
      final movies = result['movies'] as List<WMovie>;
      final total = result['total'] as int;

      if (mounted) {
        setState(() {
          _movies = movies;
          _isLoadingMovies = false;
          _hasMoreMovies = _movies.length < total;
        });
        if (_movieScrollController.hasClients) _movieScrollController.jumpTo(0);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMovies = false);
    }
  }

  // WebSocket and Sync Logic (Reused)
  Future<void> _connectWebSocket() async {
    _reconnectTimer?.cancel();
    try {
      final token = await WatchTogetherService.getToken();
      if (token == null) return;

      final httpUri = Uri.parse(WatchTogetherService.baseUrl);
      final wsScheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
      final wsUrl = httpUri.replace(
        scheme: wsScheme,
        path: '${httpUri.path}/room/ws',
        queryParameters: {'roomId': widget.room.roomId},
      );
      
      _channel = IOWebSocketChannel.connect(wsUrl, protocols: [token]);
      _channel!.stream.listen((data) {
        _reconnectAttempts = 0;
        if (data is Uint8List || data is List<int>) {
           try {
             final message = SimpleProto.decode(data is Uint8List ? data : Uint8List.fromList(data));
             _handleWebSocketMessage(message);
           } catch (e) {
             debugPrint('WebSocket消息解析失败: $e');
           }
        }
      }, onError: (e) {
        debugPrint('WebSocket连接错误: $e');
        _scheduleReconnect();
      }, onDone: _scheduleReconnect);
    } catch (e) {
      debugPrint('WebSocket连接失败: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: _reconnectAttempts * 2), () {
      if (mounted) _connectWebSocket();
    });
  }

  void _handleWebSocketMessage(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == MessageType.CHAT) {
      final content = message['chatContent'];
      final username = message['sender']?['username'] ?? 'Unknown';
      
      // TV Danmaku
      if (_currentUrl.isNotEmpty) {
        Duration pos = Duration.zero;
        try {
          pos = _betterPlayerController?.videoPlayerController?.value.position ?? Duration.zero;
        } catch (_) {}
        final danmaku = DanmakuItem(
          text: '$username: $content',
          startTime: pos,
          endTime: pos + const Duration(seconds: 8),
          color: Colors.white,
          type: DanmakuType.floating,
          fontSize: 24, // Larger font for TV
        );
        _danmakuController.add(danmaku);
      }
      
      if (mounted) {
        setState(() {
          _messages.add({
            'username': username,
            'content': content,
            'timestamp': message['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
          });
          if (_messages.length > 50) _messages.removeAt(0);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScrollController.hasClients) {
            _chatScrollController.jumpTo(_chatScrollController.position.maxScrollExtent);
          }
        });
      }
    } else if (type == MessageType.SYNC || type == MessageType.STATUS || type == MessageType.CHECK_STATUS) {
      final status = message['status'];
      if (status != null) {
        _performSync(
          status['is_playing'] == true,
          (status['current_time'] as num).toDouble(),
          (status['playback_rate'] as num?)?.toDouble() ?? 1.0
        );
      }
    } else if (type == MessageType.CURRENT) {
       _syncState();
    } else if (type == MessageType.MOVIES) {
       _fetchMovies();
    }
  }

  Future<void> _performSync(bool isPlaying, double currentTime, double playbackRate) async {
    if (_betterPlayerController == null) return;
    _isSyncing = true;
    try {
      final ctrl = _betterPlayerController!;
      // 调整倍速
      if ((_lastRate - playbackRate).abs() > 0.05) {
        ctrl.setSpeed(playbackRate);
        _lastRate = playbackRate;
      }
      // seek（误差超过2秒才 seek）
      final posMs = await ctrl.videoPlayerController?.position;
      final currentPos = (posMs?.inMilliseconds ?? 0) / 1000.0;
      if ((currentPos - currentTime).abs() > 2.0) {
        ctrl.seekTo(Duration(milliseconds: (currentTime * 1000).toInt()));
        _lastPosition = currentTime;
      }
      // 暂停 / 播放
      final playing = ctrl.isPlaying() ?? false;
      if (!isPlaying && playing) {
        ctrl.pause();
        _lastPlaying = false;
      } else if (isPlaying && !playing) {
        ctrl.play();
        _lastPlaying = true;
      }
    } catch (_) {} finally {
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) _isSyncing = false;
      });
    }
  }

  void _videoListener(BetterPlayerEvent event) {
    if (_isSyncing) return;
    if (_betterPlayerController == null) return;
    final ctrl = _betterPlayerController!;
    final playing = ctrl.isPlaying() ?? false;
    final posMs = ctrl.videoPlayerController?.value.position;
    final position = (posMs?.inMilliseconds ?? 0) / 1000.0;
    final rate = _lastRate; // better_player 不暴露当前速度，使用缓存值

    bool changed = false;
    if (playing != _lastPlaying) { _lastPlaying = playing; changed = true; }
    if ((rate - _lastRate).abs() > 0.05) { _lastRate = rate; changed = true; }
    if ((position - _lastPosition).abs() > 2.0) { _lastPosition = position; changed = true; } else { _lastPosition = position; }

    // 仅在状态变化时触发 UI 重建
    if (changed && mounted) setState(() {});

    if (changed) {
      if (_updateDebounce?.isActive ?? false) _updateDebounce!.cancel();
      _updateDebounce = Timer(const Duration(milliseconds: 1000), () {
        if (mounted && !_isSyncing) {
          _sendStatus(playing, position, rate);
        }
      });
    }
  }

  void _sendStatus(bool isPlaying, double position, double rate) {
    if (_channel != null) {
      try {
        final bytes = SimpleProto.encodeStatus(isPlaying, position, rate);
        _channel!.sink.add(bytes);
      } catch (_) {}
    }
  }

  Future<void> _syncState() async {
    try {
      final status = await WatchTogetherService.getCurrentMovie(widget.room.roomId);
      if (mounted) {
        if (_currentStatus?.movie?.id != status.movie?.id) _danmakuController.clear();
        setState(() => _currentStatus = status);
        
        if (status.movie != null && status.movie!.url.isNotEmpty) {
          String newUrl = status.movie!.url;
          if (newUrl.startsWith('/')) newUrl = '${WatchTogetherService.baseUrl.replaceAll('/api', '')}$newUrl';

          if (_currentUrl != newUrl) {
            await _initVideo(newUrl, headers: status.movie!.headers);
            // 新影片：等下一帧渲染完成后再 seek/play，避免黑屏
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _currentUrl == newUrl) {
                _performSync(status.isPlaying, status.currentTime, status.playbackRate);
              }
            });
          } else {
            // 同一影片：直接同步播放状态
            _performSync(status.isPlaying, status.currentTime, status.playbackRate);
          }

          String? streamUrl = status.movie!.streamDanmu;
          if (streamUrl != null && streamUrl.startsWith('/')) {
            streamUrl = '${WatchTogetherService.baseUrl.replaceAll('/api', '')}$streamUrl';
          }

          String? danmuUrl = status.movie!.danmu;
          if (danmuUrl != null && danmuUrl.startsWith('/')) danmuUrl = '${WatchTogetherService.baseUrl.replaceAll('/api', '')}$danmuUrl';

          _danmakuController.updateConfig(
            danmakuUrl: danmuUrl,
            streamDanmakuUrl: streamUrl,
            controller: null, // better_player 不使用 VideoPlayerController
          );
        } else {
          if (_currentUrl.isNotEmpty) {
            _disposeVideoController();
            _currentUrl = '';
            setState(() {});
          }
        }
      }
    } catch (e) {
      debugPrint('Sync state error: $e');
    }
  }

  Future<void> _initVideo(String url, {Map<String, String>? headers}) async {
    if (url.isEmpty) return;
    try {
      _disposeVideoController();

      final dataSource = BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        url,
        headers: headers,
        videoFormat: BetterPlayerVideoFormat.other,
      );

      _betterPlayerController = BetterPlayerController(
        const BetterPlayerConfiguration(
          autoPlay: false, // 等 _performSync 决定
          looping: false,
          handleLifecycle: false,
          controlsConfiguration: BetterPlayerControlsConfiguration(
            showControls: false, // TV 端用自定义控制
          ),
          fit: BoxFit.contain,
        ),
        betterPlayerDataSource: dataSource,
      );

      _betterPlayerController!.addEventsListener(_videoListener);
      _currentUrl = url;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Video init error: $e');
    }
  }

  void _disposeVideoController() {
    _updateDebounce?.cancel();
    _betterPlayerController?.dispose();
    _betterPlayerController = null;
  }

  @override
  void dispose() {
    _authErrorSubscription?.cancel();
    _disposeVideoController();
    _syncTimer?.cancel();
    _channel?.sink.close();
    _chatScrollController.dispose();
    _movieScrollController.dispose();
    _webrtcManager?.dispose();
    _danmakuController.dispose();
    _videoFocus.dispose();
    _movieListFocus.dispose();
    super.dispose();
  }

  // TV Logic
  void _enterFolder(WMovie folder) {
    setState(() {
      _folderStack.add(folder);
      _folderNameStack.add(folder.name);
      _isLoadingMovies = true;
    });
    _fetchMovies();
  }

  void _exitFolder() {
    if (_folderStack.isEmpty) return;
    setState(() {
      _folderStack.removeLast();
      _folderNameStack.removeLast();
      _isLoadingMovies = true;
    });
    _fetchMovies();
  }

  Future<void> _switchMovie(WMovie movie) async {
    try {
      await WatchTogetherService.switchMovie(widget.room.roomId, movie.id, subPath: movie.subPath);
      await _syncState(); 
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.enter): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.contextMenu): const ActivateIntent(), // Map menu key
        LogicalKeySet(LogicalKeyboardKey.keyM): const ActivateIntent(), // M for Menu
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.contextMenu || 
                  event.logicalKey == LogicalKeyboardKey.keyM) {
                setState(() => _showSidePanel = !_showSidePanel);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.escape || 
                  event.logicalKey == LogicalKeyboardKey.goBack) {
                if (_showSidePanel) {
                  setState(() => _showSidePanel = false);
                  return KeyEventResult.handled;
                }
              }
            }
            return KeyEventResult.ignored;
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                // Main Video Area
                Positioned.fill(
                  child: Center(
                    child: _currentUrl.isNotEmpty && _betterPlayerController != null
                        ? AspectRatio(
                            aspectRatio: 16 / 9,
                            child: BetterPlayer(controller: _betterPlayerController!),
                          )
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.tv, color: Colors.white24, size: 80),
                              SizedBox(height: 16),
                              Text('等待播放...', style: TextStyle(color: Colors.white54, fontSize: 24)),
                            ],
                          ),
                  ),
                ),

                // Side Panel (Overlay)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  right: _showSidePanel ? 0 : -400,
                  top: 0,
                  bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.35 < 300 ? 300 : (MediaQuery.of(context).size.width * 0.35 > 500 ? 500 : MediaQuery.of(context).size.width * 0.35),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor.withOpacity(0.95),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 20,
                          offset: const Offset(-5, 0),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Tab Header
                        SizedBox(
                          height: 60,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              _buildTabItem(0, Icons.movie, '影片'),
                              _buildTabItem(1, Icons.chat, '聊天'),
                              _buildTabItem(2, Icons.people, '成员'),
                              // Close Button
                              Container(
                                width: 60,
                                alignment: Alignment.center,
                                child: IconButton(
                                  icon: Icon(Icons.close, color: isDark ? Colors.white54 : Colors.black54),
                                  onPressed: () => setState(() => _showSidePanel = false),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: theme.dividerColor),
                        
                        // Tab Content
                        Expanded(
                          child: IndexedStack(
                            index: _selectedTabIndex,
                            children: [
                              _buildMoviesTab(),
                              _buildChatTab(),
                              _buildMembersTab(),
                            ],
                          ),
                        ),
                      ],
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

  Widget _buildTabItem(int index, IconData icon, String label) {
    final isSelected = _selectedTabIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedColor = isDark ? Colors.white54 : Colors.black54;
    
    return InkWell(
      onTap: () => setState(() => _selectedTabIndex = index),
      focusColor: const Color(0xFF5D5FEF).withOpacity(0.3),
      child: Container(
        width: 133,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: isSelected ? const Border(bottom: BorderSide(color: Color(0xFF5D5FEF), width: 4)) : null,
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF5D5FEF) : unselectedColor),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: isSelected ? const Color(0xFF5D5FEF) : unselectedColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildMoviesTab() {
    return Column(
      children: [
        if (_folderStack.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_back, color: Colors.white),
            title: Text('返回: ${_folderNameStack.last}', style: const TextStyle(color: Colors.white)),
            onTap: _exitFolder,
            tileColor: Colors.white10,
          ),
        Expanded(
          child: _isLoadingMovies 
            ? const Center(child: CircularProgressIndicator()) 
            : ListView.builder(
                controller: _movieScrollController,
                itemCount: _movies.length,
                itemBuilder: (context, index) {
                  final movie = _movies[index];
                  final isCurrent = _currentStatus?.movie?.id == movie.id;
                  return ListTile(
                    autofocus: index == 0,
                    leading: Icon(
                      movie.isFolder ? Icons.folder : Icons.movie,
                      color: movie.isFolder ? Colors.amber : (isCurrent ? const Color(0xFF5D5FEF) : Colors.white54),
                    ),
                    title: Text(
                      movie.name,
                      style: TextStyle(
                        color: isCurrent ? const Color(0xFF5D5FEF) : Colors.white,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        fontSize: 18,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => movie.isFolder ? _enterFolder(movie) : _switchMovie(movie),
                    focusColor: const Color(0xFF5D5FEF).withOpacity(0.3),
                  );
                },
              ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('添加影片'),
            onPressed: () => AddMovieDialog.show(context, widget.room.roomId),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              backgroundColor: const Color(0xFF5D5FEF),
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${msg['username']}: ', style: const TextStyle(color: Color(0xFF5D5FEF), fontWeight: FontWeight.bold, fontSize: 16)),
                    Expanded(child: Text(msg['content'], style: const TextStyle(color: Colors.white, fontSize: 16))),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMembersTab() {
    return ListView.builder(
      itemCount: _members.length,
      itemBuilder: (context, index) {
        final member = _members[index];
        return ListTile(
          leading: CircleAvatar(child: Text(member.username[0].toUpperCase())),
          title: Text(member.username, style: const TextStyle(color: Colors.white, fontSize: 18)),
          subtitle: Text(
            member.role == 3 ? '房主' : '成员',
            style: const TextStyle(color: Colors.white54),
          ),
        );
      },
    );
  }
}
