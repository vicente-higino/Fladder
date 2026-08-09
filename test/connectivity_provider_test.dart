import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/user_provider.dart';

void main() {
  group('connectivity recovery', () {
    test('initial checking state does not display the offline banner', () async {
      final probe = Completer<String?>();
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.none]),
        reachabilityProbe: (url) => probe.future,
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account(url: 'http://localhost:8096'));

      expect(container.read(offlineStateProvider), isFalse);
      expect(container.read(connectivityStatusProvider).reachability, ServerReachability.checking);

      probe.complete('http://localhost:8096');
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);
    });

    test('reachable localhost stays online when Windows reports no adapter', () async {
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.none]),
        reachabilityProbe: (url) async => url,
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account(url: 'http://localhost:8096'));

      container.read(connectivityStatusProvider);
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);

      final snapshot = container.read(connectivityStatusProvider);
      expect(snapshot.networkType, NetworkType.none);
      expect(snapshot.serverIsLocal, isTrue);
      expect(snapshot.homeInternet, isTrue);
      expect(snapshot.isOffline, isFalse);
    });

    test('offline retry recovers without recreating the provider', () async {
      var attempt = 0;
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.wifi]),
        reachabilityProbe: (url) async => attempt++ == 0 ? null : url,
        retryDelays: const [Duration(milliseconds: 50)],
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account());

      container.read(connectivityStatusProvider);
      await _waitFor(() => container.read(connectivityStatusProvider).isOffline);
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);

      expect(attempt, greaterThanOrEqualTo(2));
    });

    test('changing the local URL while offline probes and selects it immediately', () async {
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.none]),
        reachabilityProbe: (url) async => null,
        identityProbe: (url) async => url == 'http://localhost:8096' ? const PublicSystemInfo(id: 'server-id') : null,
        retryDelays: const [],
      );
      addTearDown(container.dispose);
      final account = _account();
      container.read(userProvider.notifier).loginUser(account);

      container.read(connectivityStatusProvider);
      await _waitFor(() => container.read(connectivityStatusProvider).isOffline);

      container.read(userProvider.notifier).loginUser(
            account.copyWith(
              credentials: account.credentials.copyWith(localUrl: 'http://localhost:8096'),
            ),
          );
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);

      expect(container.read(localConnectionAvailableProvider), isTrue);
      expect(container.read(connectivityStatusProvider).serverIsLocal, isTrue);
    });

    test('an older failed probe cannot overwrite a newer success', () async {
      final firstProbe = Completer<String?>();
      final secondProbe = Completer<String?>();
      var probeCount = 0;
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.wifi]),
        reachabilityProbe: (url) {
          probeCount++;
          return probeCount == 1 ? firstProbe.future : secondProbe.future;
        },
        retryDelays: const [],
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account());
      final notifier = container.read(connectivityStatusProvider.notifier);

      await _waitFor(() => probeCount == 1);
      unawaited(notifier.refresh());
      await _waitFor(() => probeCount == 2);

      secondProbe.complete('http://192.168.1.100:8096');
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);
      firstProbe.complete(null);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(connectivityStatusProvider).reachability, ServerReachability.online);
    });

    test('VPN is classified as other and does not remain latched offline', () async {
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.vpn]),
        reachabilityProbe: (url) async => url,
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account(url: 'https://example.com'));

      container.read(connectivityStatusProvider);
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);

      expect(container.read(connectivityStatusProvider).networkType, NetworkType.other);
    });

    test('request reports ignore application errors and recover immediately on success', () async {
      const url = 'http://192.168.1.100:8096';
      final container = _container(
        adapter: _FakeConnectivityAdapter([ConnectivityResult.wifi]),
        reachabilityProbe: (url) async => url,
        retryDelays: const [],
      );
      addTearDown(container.dispose);
      container.read(userProvider.notifier).loginUser(_account());
      final notifier = container.read(connectivityStatusProvider.notifier);
      await _waitFor(() => container.read(connectivityStatusProvider).reachability == ServerReachability.online);

      notifier.reportRequestFailure(url, const FormatException('bad payload'));
      expect(container.read(connectivityStatusProvider).reachability, ServerReachability.online);

      notifier.reportRequestFailure(url, const SocketException('offline'));
      expect(container.read(connectivityStatusProvider).isOffline, isTrue);

      notifier.reportRequestSuccess(url);
      expect(container.read(connectivityStatusProvider).reachability, ServerReachability.online);
    });
  });

  group('connectivity classification', () {
    test('only I/O and timeout failures are connectivity failures', () {
      expect(isConnectionFailure(const SocketException('offline')), isTrue);
      expect(isConnectionFailure(TimeoutException('slow')), isTrue);
      expect(isConnectionFailure(const FormatException('bad payload')), isFalse);
      expect(isConnectionFailure(StateError('bad state')), isFalse);
    });

    test('loopback and private hosts use home-network quality', () {
      expect(isLocalServerUrl('http://localhost:8096'), isTrue);
      expect(isLocalServerUrl('http://127.0.0.1:8096'), isTrue);
      expect(isLocalServerUrl('http://192.168.1.100:8096'), isTrue);
      expect(isLocalServerUrl('http://172.31.1.1:8096'), isTrue);
      expect(isLocalServerUrl('https://example.com'), isFalse);
    });
  });
}

ProviderContainer _container({
  required _FakeConnectivityAdapter adapter,
  required JellyfinReachabilityProbe reachabilityProbe,
  JellyfinIdentityProbe? identityProbe,
  List<Duration>? retryDelays,
}) {
  return ProviderContainer(
    overrides: [
      connectivityAdapterProvider.overrideWithValue(adapter),
      jellyfinReachabilityProbeProvider.overrideWithValue(reachabilityProbe),
      jellyfinIdentityProbeProvider.overrideWithValue(identityProbe ?? (url) async => null),
      if (retryDelays != null) connectivityRetryDelaysProvider.overrideWithValue(retryDelays),
    ],
  );
}

AccountModel _account({String url = 'http://192.168.1.100:8096'}) {
  return AccountModel(
    name: 'Test User',
    id: 'user-id',
    avatar: '',
    lastUsed: DateTime(2026),
    credentials: CredentialsModel.internal(
      token: 'token',
      url: url,
      serverName: 'Test Server',
      serverId: 'server-id',
      deviceId: 'device-id',
    ),
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final timeout = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(timeout)) {
      fail('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakeConnectivityAdapter implements ConnectivityAdapter {
  _FakeConnectivityAdapter(this.result);

  List<ConnectivityResult> result;
  final StreamController<List<ConnectivityResult>> _changes = StreamController.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => result;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;
}
