enum AppMode {
  bridge,
  monitor;

  String get storageValue => name;

  String get label => switch (this) {
    AppMode.bridge => 'Modo Puente',
    AppMode.monitor => 'Modo Monitor',
  };

  static AppMode? fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) return mode;
    }
    return null;
  }
}
