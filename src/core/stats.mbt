///|
/// Fold an RSS sample into the project's stats window. A name that is not
/// registered is not an error and not an entry: there is nothing to sample.
fn Supervisor::record_stats_peak(
  self : Supervisor,
  app_name : String,
  kb : Int32,
) -> Unit {
  if self.projects.get(app_name) is Some(project) {
    if kb > project.stats.peak_kb {
      project.stats = { ..project.stats, peak_kb: kb, }
    }
  }
}

///|
/// Count one automatic restart into the project's stats window.
fn Supervisor::record_stats_restart(
  self : Supervisor,
  app_name : String,
) -> Unit {
  if self.projects.get(app_name) is Some(project) {
    let window = project.stats
    project.stats = { ..window, restarts: window.restarts + 1, }
  }
}

///|
/// Take (and clear) the project's stats window.
fn Supervisor::take_stats_window(
  self : Supervisor,
  app_name : String,
) -> StatsWindow {
  match self.projects.get(app_name) {
    Some(project) => {
      let taken = project.stats
      project.stats = { peak_kb: 0, restarts: 0, }
      taken
    }
    None => { peak_kb: 0, restarts: 0, }
  }
}
