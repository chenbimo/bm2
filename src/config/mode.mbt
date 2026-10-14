///|
/// How a project is started, and the one fact that decides its environment.
///
/// `bm2 serve` and `bm2 dev` are the same supervision with different
/// environments: the mode is not a behavior switch. It picks which `.env` files
/// load, and it is the value of NODE_ENV. One word, three uses — the command,
/// the `.env.<mode>` suffix and NODE_ENV — so they cannot drift apart.
///
/// What the application *does* with NODE_ENV is the application's business.
/// bm2 guarantees that the value matches the files it read from.
pub(all) enum Mode {
  Development
  Production
} derive(Eq, Debug)

///|
pub extend Mode with Debug::{to_repr}

///|
pub extend Mode with Eq::{not_equal, equal}

///|
/// The mode's own name: used verbatim as the `.env.<mode>` suffix and as the
/// value of NODE_ENV, so the two can never disagree about what "development"
/// spells.
pub fn Mode::as_string(self : Mode) -> String {
  match self {
    Development => "development"
    Production => "production"
  }
}

///|
/// Read a mode back from its name. For values that come from outside the
/// compiler: a persisted project record. None means the name is not a mode, and
/// the caller decides what that costs.
pub fn Mode::from_string(value : String) -> Mode? {
  match value {
    "development" => Some(Development)
    "production" => Some(Production)
    _ => None
  }
}

///|
/// The mode a start verb names, or None for any other command. The verbs and
/// the modes are one vocabulary with two spellings, and this is the only place
/// that translates between them.
pub fn Mode::of_command(command : String) -> Mode? {
  match command {
    "dev" => Some(Development)
    "serve" => Some(Production)
    _ => None
  }
}
