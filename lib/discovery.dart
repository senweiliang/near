import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'transport.dart';

const _serviceType = '_near._tcp';

class Discovery {
  final String myId;
  String myName;
  final int port;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;

  Discovery({required this.myId, required this.myName, required this.port});

  // 自报本机局域网 IPv4，对端直接按 IP 拨号，绕开被代理劫持的 .local 解析
  static Future<String> _localIPv4List() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      return interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .where(isDialableIPv4)
          .join(',');
    } catch (e) {
      debugPrint('[discovery] list interfaces failed: $e');
      return '';
    }
  }

  Future<BonsoirService> _buildService() async {
    final ips = await _localIPv4List();
    return BonsoirService(
      name: 'near-${myId.substring(0, 8)}',
      type: _serviceType,
      port: port,
      attributes: {'id': myId, 'name': myName, if (ips.isNotEmpty) 'ips': ips},
    );
  }

  Future<void> start({
    required void Function(ResolvedBonsoirService) onPeerFound,
    required void Function(BonsoirService) onPeerLost,
  }) async {
    final service = await _buildService();
    debugPrint('[discovery] starting broadcast: name=${service.name} port=$port ips=${service.attributes['ips']}');
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;
    await _broadcast!.start();
    debugPrint('[discovery] broadcast started');

    _discovery = BonsoirDiscovery(type: _serviceType);
    await _discovery!.ready;
    _discovery!.eventStream!.listen((event) {
      debugPrint('[discovery] event=${event.type} service=${event.service?.name} attrs=${event.service?.attributes}');
      final svc = event.service;
      if (svc == null) return;
      if (svc.attributes['id'] == myId) return; // ignore self
      switch (event.type) {
        case BonsoirDiscoveryEventType.discoveryServiceFound:
          svc.resolve(_discovery!.serviceResolver);
        case BonsoirDiscoveryEventType.discoveryServiceResolved:
          if (svc is ResolvedBonsoirService) onPeerFound(svc);
        case BonsoirDiscoveryEventType.discoveryServiceLost:
          onPeerLost(svc);
        default:
          break;
      }
    });
    await _discovery!.start();
    debugPrint('[discovery] discovery started');
  }

  Future<void> updateName(String newName) async {
    if (newName == myName) return;
    myName = newName;
    final old = _broadcast;
    if (old == null) return;
    debugPrint('[discovery] rebroadcasting with new name=$newName');
    try {
      await old.stop();
    } catch (e) {
      debugPrint('[discovery] stop old broadcast failed: $e');
    }
    final service = await _buildService();
    final next = BonsoirBroadcast(service: service);
    _broadcast = next;
    try {
      await next.ready;
      await next.start();
      debugPrint('[discovery] rebroadcast started');
    } catch (e, st) {
      debugPrint('[discovery] rebroadcast failed: $e\n$st');
    }
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    await _discovery?.stop();
  }
}
