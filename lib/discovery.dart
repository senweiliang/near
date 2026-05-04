import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

const _serviceType = '_near._tcp';

class Discovery {
  final String myId;
  String myName;
  final int port;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;

  Discovery({required this.myId, required this.myName, required this.port});

  Future<void> start({
    required void Function(ResolvedBonsoirService) onPeerFound,
    required void Function(BonsoirService) onPeerLost,
  }) async {
    final service = BonsoirService(
      name: 'near-${myId.substring(0, 8)}',
      type: _serviceType,
      port: port,
      attributes: {'id': myId, 'name': myName},
    );
    debugPrint('[discovery] starting broadcast: name=${service.name} port=$port');
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
    final service = BonsoirService(
      name: 'near-${myId.substring(0, 8)}',
      type: _serviceType,
      port: port,
      attributes: {'id': myId, 'name': myName},
    );
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
