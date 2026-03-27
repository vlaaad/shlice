use crate::{shell_id, AppError, Result};
use pico_args::Arguments;
use std::ffi::OsString;

#[derive(Debug, Clone)]
pub enum Command {
    Help,
    List,
    Status(StatusOptions),
    Start(StartOptions),
    Exec(ExecOptions),
    Stop(StopOptions),
    Broker(BrokerOptions),
}

#[derive(Debug, Clone)]
pub struct StatusOptions {
    pub id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StartOptions {
    pub id: Option<String>,
    pub command: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ExecOptions {
    pub id: String,
    pub timeout_seconds: u64,
    pub command: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StopOptions {
    pub id: String,
}

#[derive(Debug, Clone)]
pub struct BrokerOptions {
    pub root: String,
    pub id: String,
    pub cwd: String,
    pub command: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Cli {
    pub command: Command,
}

pub fn parse(argv: &[String]) -> Result<Cli> {
    let argv: Vec<OsString> = argv.iter().map(OsString::from).collect();
    parse_os(argv)
}

fn parse_os(argv: Vec<OsString>) -> Result<Cli> {
    if argv.len() <= 1 {
        return Ok(Cli {
            command: Command::Help,
        });
    }
    if is_help(&argv[1]) {
        return Ok(Cli {
            command: Command::Help,
        });
    }

    let (left, trailing) = split_dash_dash(&argv[1..]);
    let mut args = Arguments::from_vec(left);
    if has_help(&mut args) {
        return Ok(Cli {
            command: Command::Help,
        });
    }

    let subcommand = match args
        .subcommand()
        .map_err(|err| AppError::Msg(err.to_string()))?
    {
        Some(value) => value,
        None => {
            return Ok(Cli {
                command: Command::Help,
            })
        }
    };

    let command = match subcommand.as_str() {
        "help" => Command::Help,
        "list" => {
            ensure_empty(args)?;
            Command::List
        }
        "status" => Command::Status(parse_status(args)?),
        "start" => Command::Start(parse_start(args, trailing)?),
        "exec" => Command::Exec(parse_exec(args)?),
        "stop" => Command::Stop(parse_stop(args)?),
        "broker" => Command::Broker(parse_broker(args, trailing)?),
        _ => return Err(AppError::Msg("unknown command".to_string())),
    };
    Ok(Cli { command })
}

fn parse_status(mut args: Arguments) -> Result<StatusOptions> {
    let id = opt_shell_id(&mut args, "--id")?;
    ensure_empty(args)?;
    Ok(StatusOptions { id })
}

fn parse_start(mut args: Arguments, command: Vec<String>) -> Result<StartOptions> {
    let id = opt_shell_id(&mut args, "--id")?;
    ensure_empty(args)?;
    if command.is_empty() {
        return Err(AppError::Msg("invalid arguments".to_string()));
    }
    Ok(StartOptions { id, command })
}

fn parse_exec(mut args: Arguments) -> Result<ExecOptions> {
    let id = opt_shell_id(&mut args, "--id")?.unwrap_or_else(|| "main".to_string());
    let timeout_seconds = opt_u64(&mut args, "--timeout")?.unwrap_or(5);
    let command = args.finish();
    let command = match command.len() {
        0 => None,
        1 => Some(string_arg(command.into_iter().next().unwrap())?),
        _ => return Err(AppError::Msg("invalid arguments".to_string())),
    };
    Ok(ExecOptions {
        id,
        timeout_seconds,
        command,
    })
}

fn parse_stop(mut args: Arguments) -> Result<StopOptions> {
    let id = opt_shell_id(&mut args, "--id")?.unwrap_or_else(|| "main".to_string());
    ensure_empty(args)?;
    Ok(StopOptions { id })
}

fn parse_broker(mut args: Arguments, command: Vec<String>) -> Result<BrokerOptions> {
    let root = opt_string(&mut args, "--root")?
        .ok_or_else(|| AppError::Msg("invalid arguments".to_string()))?;
    let id = opt_shell_id(&mut args, "--id")?
        .ok_or_else(|| AppError::Msg("invalid arguments".to_string()))?;
    let cwd = opt_string(&mut args, "--cwd")?
        .ok_or_else(|| AppError::Msg("invalid arguments".to_string()))?;
    ensure_empty(args)?;
    if command.is_empty() {
        return Err(AppError::Msg("invalid arguments".to_string()));
    }
    Ok(BrokerOptions {
        root,
        id,
        cwd,
        command,
    })
}

fn opt_string(args: &mut Arguments, key: &'static str) -> Result<Option<String>> {
    Ok(args
        .opt_value_from_str::<_, String>(key)
        .map_err(|err| AppError::Msg(err.to_string()))?)
}

fn opt_u64(args: &mut Arguments, key: &'static str) -> Result<Option<u64>> {
    Ok(args
        .opt_value_from_str::<_, u64>(key)
        .map_err(|err| AppError::Msg(err.to_string()))?)
}

fn opt_shell_id(args: &mut Arguments, key: &'static str) -> Result<Option<String>> {
    let value = opt_string(args, key)?;
    if let Some(ref value) = value {
        shell_id::validate(value).map_err(|m| AppError::Msg(m.to_string()))?;
    }
    Ok(value)
}

fn ensure_empty(args: Arguments) -> Result<()> {
    let remaining = args.finish();
    if remaining.is_empty() {
        Ok(())
    } else {
        Err(AppError::Msg("invalid arguments".to_string()))
    }
}

fn string_arg(value: OsString) -> Result<String> {
    value
        .into_string()
        .map_err(|_| AppError::Msg("invalid arguments".to_string()))
}

fn split_dash_dash(args: &[OsString]) -> (Vec<OsString>, Vec<String>) {
    let mut left = Vec::new();
    let mut right = Vec::new();
    let mut seen = false;
    for arg in args {
        if !seen && arg == "--" {
            seen = true;
            continue;
        }
        if seen {
            right.push(arg.to_string_lossy().into_owned());
        } else {
            left.push(arg.clone());
        }
    }
    (left, right)
}

fn has_help(args: &mut Arguments) -> bool {
    args.contains(["-h", "--help"]) || args.contains("-?")
}

fn is_help(value: &OsString) -> bool {
    matches!(
        value.to_string_lossy().as_ref(),
        "-h" | "--help" | "-?" | "help"
    )
}
