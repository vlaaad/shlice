mod app;
mod broker;
mod cli;
mod ipc;
mod output;
mod process;
mod protocol;
mod shell_id;
mod state;

use thiserror::Error;

pub use app::run_main;

#[derive(Debug, Error)]
pub enum AppError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("{0}")]
    Msg(String),
    #[error("exit {0}")]
    Exit(u8),
}

pub type Result<T> = std::result::Result<T, AppError>;

pub(crate) use broker::run_broker;
pub(crate) use cli::BrokerOptions;
pub(crate) use cli::{parse, Command, ExecOptions, StartOptions, StopOptions};
pub(crate) use ipc::*;
pub(crate) use output::*;
pub(crate) use process::*;
pub(crate) use protocol::*;
pub(crate) use shell_id::*;
pub(crate) use state::*;
