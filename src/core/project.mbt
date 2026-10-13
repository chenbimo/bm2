///|
/// One registered project and the state the daemon keeps about it.
///
/// This is the value the rest of the core passes around. A project's identity is
/// its name plus the config file it was registered from, and the per-project
/// state that used to live in several separate maps keyed by that name belongs
/// here — where adding a field is adding a field, not a new map plus a new
/// cleanup obligation for every place that forgets a project.
///
/// What stays on `Supervisor` is daemon-level: the state directory, the interval
/// gates, the control and rotation queues, the notify subsystem.
pub(all) struct Project {
  /// The project's configuration, as last registered.
  config : @config.Config
  /// Canonical config file this project was registered from. Canonical so that
  /// the same file reached through a symlink or `..` compares equal.
  config_path : String
  /// The project's instances. Rebuilt in place when the instance count or the
  /// config generation changes; the instance records themselves are mutated
  /// through the array, which is why this is the one mutable field here.
  mut instances : Array[Instance]
  /// A full restart is in flight: the old generation is stopping.
  mut restarting : Bool
  /// Retiring: the state is released once every instance has stopped.
  mut removing : Bool
  /// Stopped on purpose: supervision never starts it again. Only `bm2 start`
  /// clears this, and it is persisted with the project.
  mut stopped : Bool
}
