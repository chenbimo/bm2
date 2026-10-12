///|
/// Fold an RSS sample into the project's stats window.
fn Supervisor::record_stats_peak(
  self : Supervisor,
  app_name : String,
  kb : Int32,
) -> Unit {
  match self.stats_window.get(app_name) {
    Some(w) =>
      if kb > w.peak_kb {
        self.stats_window[app_name] = { ..w, peak_kb: kb, }
      }
    None => self.stats_window[app_name] = { peak_kb: kb, restarts: 0, }
  }
}

///|
/// Count one automatic restart into the project's stats window.
fn Supervisor::record_stats_restart(
  self : Supervisor,
  app_name : String,
) -> Unit {
  match self.stats_window.get(app_name) {
    Some(w) => self.stats_window[app_name] = { ..w, restarts: w.restarts + 1, }
    None => self.stats_window[app_name] = { peak_kb: 0, restarts: 1, }
  }
}

///|
/// Take (and clear) the project's stats window.
fn Supervisor::take_stats_window(
  self : Supervisor,
  app_name : String,
) -> StatsWindow {
  let w = match self.stats_window.get(app_name) {
    Some(w) => w
    None => { peak_kb: 0, restarts: 0, }
  }
  self.stats_window[app_name] = { peak_kb: 0, restarts: 0, }
  w
}
