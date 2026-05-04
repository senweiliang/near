import 'dart:convert';
import 'dart:typed_data';

class Peer {
  final String id;
  final String name;
  final String host;
  final int port;
  bool online;
  DateTime? lastActiveAt;
  Peer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.online = true,
    this.lastActiveAt,
  });
}

enum SendStatus { pending, delivered, failed }

enum FanoutState { offered, sending, delivered, declined, failed }

class FanoutEntry {
  FanoutState state;
  int bytesTransferred;
  FanoutEntry({this.state = FanoutState.offered, this.bytesTransferred = 0});
}

class ChatMessage {
  final String id;
  final String fromId;
  final String fromName;
  final String text;
  final DateTime ts;
  final String? toId;
  String? imageBase64;
  String? imageMime;
  double? imageAspect;
  SendStatus status;

  // File fields. Wire-transmitted: fileName, fileSize, fileMime.
  // Local-only: cachePath, bytesTransferred.
  String? fileName;
  int? fileSize;
  String? fileMime;
  String? cachePath;
  int bytesTransferred;

  // Offer/accept handshake state. Wire-only via separate file_offer/accept/decline frames.
  bool offerPending;     // sender side: at least one peer hasn't replied yet
  bool awaitingAccept;   // receiver side: waiting for local user to tap accept
  bool declined;         // sender side: terminal state, all peers declined / failed

  // Sender-only per-peer fanout state. Empty on receiver side.
  final Map<String, FanoutEntry> fanout = {};

  Uint8List? _cachedBytes;
  String? _cachedKey;
  Uint8List? get cachedImageBytes {
    final b64 = imageBase64;
    if (b64 == null) {
      _cachedBytes = null;
      _cachedKey = null;
      return null;
    }
    if (_cachedKey == b64 && _cachedBytes != null) return _cachedBytes;
    try {
      _cachedBytes = base64Decode(b64);
      _cachedKey = b64;
      return _cachedBytes;
    } catch (_) {
      return null;
    }
  }

  ChatMessage({
    required this.id,
    required this.fromId,
    required this.fromName,
    required this.text,
    required this.ts,
    this.toId,
    this.imageBase64,
    this.imageMime,
    this.fileName,
    this.fileSize,
    this.fileMime,
    this.cachePath,
    this.bytesTransferred = 0,
    this.status = SendStatus.delivered,
    this.offerPending = false,
    this.awaitingAccept = false,
    this.declined = false,
  });

  bool get hasImage => imageBase64 != null;
  bool get hasFile => fileName != null;
  bool get fileReady =>
      hasFile && fileSize != null && bytesTransferred >= fileSize!;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromId': fromId,
        'fromName': fromName,
        'text': text,
        'ts': ts.millisecondsSinceEpoch,
        if (toId != null) 'toId': toId,
        if (imageBase64 != null) 'image': imageBase64,
        if (imageMime != null) 'imageMime': imageMime,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (fileMime != null) 'fileMime': fileMime,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: (j['id'] as String?) ?? '',
        fromId: j['fromId'] as String,
        fromName: j['fromName'] as String,
        text: (j['text'] as String?) ?? '',
        ts: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        toId: j['toId'] as String?,
        imageBase64: j['image'] as String?,
        imageMime: j['imageMime'] as String?,
        fileName: j['fileName'] as String?,
        fileSize: j['fileSize'] as int?,
        fileMime: j['fileMime'] as String?,
      );
}
