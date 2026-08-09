import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/user_provider.dart';

part 'connectivity_provider.g.dart';

enum ServerReachability {
  checking,
  online,
  offline,
}

enum NetworkType {
  none,
  mobile,
  wifi,
  ethernet,
  other,
}

@immutable
class ConnectivitySnapshot {
  const ConnectivitySnapshot({
    this.reachability = ServerReachability.checking,
    this.networkType = NetworkType.none,
    this.serverIsLocal = false,
  });

  final ServerReachability reachability;
  final NetworkType networkType;
  final bool serverIsLocal;

  bool get isOffline => reachability == ServerReachability.offline;

  bool get homeInternet =>
      reachability == ServerReachability.online &&
      (serverIsLocal || networkType == NetworkType.wifi || networkType == NetworkType.ethernet);

  ConnectivitySnapshot copyWith({
    ServerReachability? reachability,
    NetworkType? networkType,
    bool? serverIsLocal,
  }) {
    return ConnectivitySnapshot(
      reachability: reachability ?? this.reachability,
      networkType: networkType ?? this.networkType,
      serverIsLocal: serverIsLocal ?? this.serverIsLocal,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectivitySnapshot &&
          reachability == other.reachability &&
          networkType == other.networkType &&
          serverIsLocal == other.serverIsLocal;

  @override
  int get hashCode => Object.hash(reachability, networkType, serverIsLocal);
}

abstract interface class ConnectivityAdapter {
  Future<List<ConnectivityResult>> checkConnectivity();

  Stream<List<ConnectivityResult>> get onConnectivityChanged;
}

class SystemConnectivityAdapter implements ConnectivityAdapter {
  SystemConnectivityAdapter([Connectivity? connectivity]) : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() => _connectivity.checkConnectivity();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _connectivity.onConnectivityChanged;
}

typedef JellyfinReachabilityProbe = Future<String?> Function(String baseUrl);
typedef JellyfinIdentityProbe = Future<PublicSystemInfo?> Function(String baseUrl);

final connectivityAdapterProvider = Provider<ConnectivityAdapter>((ref) => SystemConnectivityAdapter());
final jellyfinReachabilityProbeProvider = Provider<JellyfinReachabilityProbe>((ref) => probeJellyfinUrl);
final jellyfinIdentityProbeProvider = Provider<JellyfinIdentityProbe>((ref) => fetchSystemInfoDynamic);
final connectivityRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ],
);

final offlineStateProvider = Provider<bool>((ref) {
  final isLoggedIn = ref.watch(userProvider.select((value) => value != null));
  return ref.watch(connectivityStatusProvider.select((value) => value.isOffline)) && isLoggedIn;
});

@Riverpod(keepAlive: true)
class ConnectivityStatus extends _$ConnectivityStatus {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _retryTimer;
  List<ConnectivityResult> _connectivityResults = const [ConnectivityResult.none];
  int _generation = 0;
  int _retryAttempt = 0;

  @override
  ConnectivitySnapshot build() {
    final adapter = ref.read(connectivityAdapterProvider);

    _connectivitySubscription = adapter.onConnectivityChanged.listen((results) {
      _connectivityResults = results;
      unawaited(refresh(connectivityResults: results));
    });

    ref.listen(
      userProvider.select(
        (value) => (
          url: value?.credentials.url,
          localUrl: value?.credentials.localUrl,
          serverId: value?.credentials.serverId,
        ),
      ),
      (previous, next) {
        if (previous == next) return;
        ref.read(localConnectionAvailableProvider.notifier).state = false;
        _retryAttempt = 0;
        unawaited(refresh());
      },
    );

    ref.onDispose(() {
      _generation++;
      _retryTimer?.cancel();
      unawaited(_connectivitySubscription?.cancel());
    });

    Future.microtask(refresh);
    return const ConnectivitySnapshot();
  }

  Future<void> refresh({List<ConnectivityResult>? connectivityResults}) async {
    final generation = ++_generation;
    _retryTimer?.cancel();
    _retryTimer = null;

    final account = ref.read(userProvider);
    if (account == null) {
      ref.read(localConnectionAvailableProvider.notifier).state = false;
      state = ConnectivitySnapshot(networkType: _networkType(_connectivityResults));
      return;
    }

    List<ConnectivityResult> results;
    if (connectivityResults != null) {
      results = connectivityResults;
    } else {
      try {
        results = await ref.read(connectivityAdapterProvider).checkConnectivity();
      } catch (error) {
        log('Unable to classify the active network adapter: $error');
        results = _connectivityResults;
      }
    }
    if (!_isCurrent(generation)) return;
    _connectivityResults = results;

    final primaryUrl = normalizeUrl(account.credentials.url);
    final localUrl = normalizeUrl(account.credentials.localUrl ?? '');
    var localAvailable = false;

    if (localUrl.isNotEmpty) {
      final localInfo = await ref.read(jellyfinIdentityProbeProvider)(localUrl);
      if (!_isCurrentAccount(generation, account)) return;
      localAvailable = localInfo?.id == account.credentials.serverId;
    }

    ref.read(localConnectionAvailableProvider.notifier).state = localAvailable;
    final activeUrl = localAvailable ? localUrl : primaryUrl;

    if (activeUrl.isEmpty) {
      _setOffline(activeUrl);
      return;
    }

    final reachable = localAvailable || await ref.read(jellyfinReachabilityProbeProvider)(activeUrl) != null;
    if (!_isCurrentAccount(generation, account) || activeUrl != _activeServerUrl()) return;

    if (reachable) {
      _setOnline(activeUrl);
    } else {
      _setOffline(activeUrl);
    }
  }

  void reportRequestSuccess(String url) {
    final normalizedUrl = normalizeUrl(url);
    if (normalizedUrl.isEmpty || normalizedUrl != _activeServerUrl()) return;

    _generation++;
    _setOnline(normalizedUrl);
  }

  void reportRequestFailure(String url, Object error) {
    if (!isConnectionFailure(error)) return;

    final normalizedUrl = normalizeUrl(url);
    if (normalizedUrl.isEmpty || normalizedUrl != _activeServerUrl()) return;

    _generation++;
    _setOffline(normalizedUrl);
  }

  bool _isCurrent(int generation) => generation == _generation;

  bool _isCurrentAccount(int generation, AccountModel account) {
    if (!_isCurrent(generation)) return false;
    final current = ref.read(userProvider);
    return current?.id == account.id && current?.credentials == account.credentials;
  }

  String _activeServerUrl() {
    final account = ref.read(userProvider);
    if (account == null) return '';

    final useLocalUrl = ref.read(localConnectionAvailableProvider);
    final url = useLocalUrl ? account.credentials.localUrl : account.credentials.url;
    return normalizeUrl(url ?? '');
  }

  void _setOnline(String activeUrl) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    state = ConnectivitySnapshot(
      reachability: ServerReachability.online,
      networkType: _networkType(_connectivityResults),
      serverIsLocal: isLocalServerUrl(activeUrl),
    );
  }

  void _setOffline(String activeUrl) {
    state = ConnectivitySnapshot(
      reachability: ServerReachability.offline,
      networkType: _networkType(_connectivityResults),
      serverIsLocal: isLocalServerUrl(activeUrl),
    );
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (ref.read(userProvider) == null || _activeServerUrl().isEmpty || _retryTimer != null) return;

    final delays = ref.read(connectivityRetryDelaysProvider);
    if (delays.isEmpty) return;
    final index = _retryAttempt.clamp(0, delays.length - 1);
    _retryAttempt++;
    _retryTimer = Timer(delays[index], () {
      _retryTimer = null;
      unawaited(refresh());
    });
  }
}

bool isConnectionFailure(Object error) => error is IOException || error is TimeoutException;

NetworkType _networkType(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.ethernet)) return NetworkType.ethernet;
  if (results.contains(ConnectivityResult.wifi)) return NetworkType.wifi;
  if (results.contains(ConnectivityResult.mobile)) return NetworkType.mobile;
  if (results.any(
    (result) =>
        result == ConnectivityResult.vpn ||
        result == ConnectivityResult.other ||
        result == ConnectivityResult.bluetooth,
  )) {
    return NetworkType.other;
  }
  return NetworkType.none;
}

bool isLocalServerUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;

  final host = uri.host.toLowerCase();
  if (host == 'localhost') return true;

  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;

  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }

  return bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc;
}

Future<PublicSystemInfo?> fetchSystemInfoDynamic(String baseUrl) async {
  if (baseUrl.isEmpty) return null;
  try {
    final uri = buildServerUriFromBase(baseUrl, pathSegments: const ['System', 'Info', 'Public']);
    if (uri == null) return null;
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    if (response.statusCode == 200) {
      return PublicSystemInfo.fromJson(jsonDecode(response.body));
    }
    return null;
  } catch (e) {
    log(e.toString());
    return null;
  }
}

final localConnectionAvailableProvider = StateProvider<bool>((ref) => false);
