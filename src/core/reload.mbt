///|
/// Apply a freshly parsed config on a start request. While any instance
/// is alive only numeric limits may change: the structural fields (name,
/// cwd, script, instances, base_port) must stay identical, otherwise the
/// request is rejected with ConfigChanged. When nothing is alive the
/// supervisor is rebuilt from the new config.
pub fn Supervisor::reload(
  self : Supervisor,
  config : @config.Config,
) -> Unit raise SupervisorError {
  let mut busy = false
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      if inst.pid != 0 {
        busy = true
        break
      }
    }
    if busy {
      break
    }
  }
  if busy {
    if config.apps.length() != self.apps.length() {
      raise ConfigChanged
    }
    for app in config.apps {
      match self.apps.get(app.name) {
        Some(old) => if !structural_equal(old, app) { raise ConfigChanged }
        None => raise ConfigChanged
      }
    }
    // Numeric limits are safe to swap live: instances look up their app
    // config through the map on every check.
    for app in config.apps {
      self.apps[app.name] = app
    }
  } else {
    let fresh = try
      Supervisor::new(
        config,
        state_dir=self.state_dir,
        bun_path=self.bun_path,
        memory_interval_ms=self.memory_interval_ms,
      )
    catch {
      e => raise IoError(e.to_string())
    } noraise {
      created => created
    }
    self.apps = fresh.apps
    self.instances = fresh.instances
    self.pending_restart = fresh.pending_restart
  }
}

///|
fn structural_equal(a : @config.AppConfig, b : @config.AppConfig) -> Bool {
  a.name == b.name &&
  a.cwd == b.cwd &&
  a.script == b.script &&
  a.instances == b.instances &&
  a.base_port == b.base_port
}
