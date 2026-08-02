///|
/// One bm2.toml configures exactly one project (single app, one or more
/// instances). The project name is also the app name and must be unique
/// among all registered projects.
pub(all) struct Config {
  name : String
  cwd : String
  script : String
  runtime : String
  instances : Int
  base_port : Int
  max_memory_mb : Int
  max_restarts : Int
  restart_delay_ms : Int
  min_uptime_ms : Int
  stop_timeout_ms : Int
  env : Map[String, String]
} derive(Debug)

///|
pub(all) suberror ConfigError {
  InvalidDocument(String)
  InvalidField(String)
}

///|
pub impl Show for ConfigError with fn output(self, logger) {
  match self {
    InvalidDocument(message) => {
      logger.write_string("InvalidDocument: ")
      logger.write_string(message)
    }
    InvalidField(message) => {
      logger.write_string("InvalidField: ")
      logger.write_string(message)
    }
  }
}
