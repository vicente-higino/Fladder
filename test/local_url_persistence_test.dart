import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';

void main() {
  test('local Jellyfin URL is normalized and persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final helper = SharedHelper(sharedPreferences: preferences);
    final account = AccountModel(
      name: 'Test User',
      id: 'user-id',
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
        token: 'token',
        url: 'http://192.168.1.100:8096',
        serverName: 'Test Server',
        serverId: 'server-id',
        deviceId: 'device-id',
      ),
    );
    await helper.saveAccounts([account]);

    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    container.read(userProvider.notifier).loginUser(account);
    container.read(userProvider.notifier).setLocalURL(' localhost:8096 ');

    await _waitFor(() => helper.getAccounts().single.credentials.localUrl != null);
    container.dispose();

    final reloaded = SharedHelper(sharedPreferences: preferences).getAccounts().single;
    expect(reloaded.credentials.localUrl, 'http://localhost:8096');
  });
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
