// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connectivity_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ConnectivityStatus)
final connectivityStatusProvider = ConnectivityStatusProvider._();

final class ConnectivityStatusProvider
    extends $NotifierProvider<ConnectivityStatus, ConnectivitySnapshot> {
  ConnectivityStatusProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'connectivityStatusProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$connectivityStatusHash();

  @$internal
  @override
  ConnectivityStatus create() => ConnectivityStatus();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ConnectivitySnapshot value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ConnectivitySnapshot>(value),
    );
  }
}

String _$connectivityStatusHash() =>
    r'0dc015f8204f88d39f0d56ff147cb82d6acad17b';

abstract class _$ConnectivityStatus extends $Notifier<ConnectivitySnapshot> {
  ConnectivitySnapshot build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ConnectivitySnapshot, ConnectivitySnapshot>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ConnectivitySnapshot, ConnectivitySnapshot>,
              ConnectivitySnapshot,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
