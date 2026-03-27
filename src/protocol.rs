use crate::{AppError, Result};
use std::io::Write;

pub const READY_MARKER: &str = "\x1b]133;A\x07";
pub const PROMPT_END_MARKER: &str = "\x1b]133;B\x07";
pub const COMMAND_BEGIN_MARKER: &str = "\x1b]133;C\x07";
pub const COMMAND_DONE_PREFIX: &str = "\x1b]133;D;";

#[derive(Debug, Clone)]
pub struct ExecRequest {
    pub reply_path: String,
    pub timeout_ms: u64,
    pub command: String,
}

#[derive(Debug, Clone)]
pub struct StopRequest {
    pub reply_path: String,
}

#[derive(Debug, Clone)]
pub struct Completion {
    pub exit_code: i32,
    pub timed_out: bool,
}

#[derive(Debug, Clone)]
pub enum FrameKind {
    Exec,
    Stop,
    Ready,
    Stdout,
    Stderr,
    Complete,
    Stopped,
    Err,
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub kind: FrameKind,
    pub payload: Vec<u8>,
}

pub fn build_exec_command(command: &str) -> String {
    if command.ends_with('\n') {
        command.to_string()
    } else {
        let mut value = String::from(command);
        value.push('\n');
        value
    }
}

pub fn encode_exec_request(request: &ExecRequest) -> Vec<u8> {
    format!(
        "reply_path={}\ntimeout_ms={}\ncommand={}\n",
        request.reply_path,
        request.timeout_ms,
        hex_encode(request.command.as_bytes())
    )
    .into_bytes()
}

pub fn encode_stop_request(request: &StopRequest) -> Vec<u8> {
    format!("reply_path={}\n", request.reply_path).into_bytes()
}

pub fn parse_exec_request(bytes: &[u8]) -> Result<ExecRequest> {
    let mut reply_port = None;
    let mut timeout_ms = None;
    let mut command = None;
    let text =
        std::str::from_utf8(bytes).map_err(|_| AppError::Msg("invalid request".to_string()))?;
    for line in text.lines() {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| AppError::Msg("invalid request".to_string()))?;
        match key {
            "reply_path" => {
                reply_port = Some(value.to_string());
            }
            "timeout_ms" => {
                timeout_ms = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| AppError::Msg("invalid request".to_string()))?,
                )
            }
            "command" => {
                let bytes = hex_decode(value)?;
                command = Some(
                    String::from_utf8(bytes)
                        .map_err(|_| AppError::Msg("invalid request".to_string()))?,
                )
            }
            _ => {}
        }
    }
    Ok(ExecRequest {
        reply_path: reply_port.ok_or_else(|| AppError::Msg("invalid request".to_string()))?,
        timeout_ms: timeout_ms.ok_or_else(|| AppError::Msg("invalid request".to_string()))?,
        command: command.ok_or_else(|| AppError::Msg("invalid request".to_string()))?,
    })
}

pub fn parse_stop_request(bytes: &[u8]) -> Result<StopRequest> {
    let mut reply_path = None;
    let text =
        std::str::from_utf8(bytes).map_err(|_| AppError::Msg("invalid request".to_string()))?;
    for line in text.lines() {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| AppError::Msg("invalid request".to_string()))?;
        if key == "reply_path" {
            reply_path = Some(value.to_string());
        }
    }
    Ok(StopRequest {
        reply_path: reply_path.ok_or_else(|| AppError::Msg("invalid request".to_string()))?,
    })
}

pub fn encode_completion(completion: &Completion) -> Vec<u8> {
    let mut payload = Vec::with_capacity(5);
    payload.extend_from_slice(&completion.exit_code.to_le_bytes());
    payload.push(u8::from(completion.timed_out));
    payload
}

pub fn decode_completion(payload: &[u8]) -> Result<Completion> {
    if payload.len() != 5 {
        return Err(AppError::Msg("invalid completion payload".to_string()));
    }
    let mut code = [0u8; 4];
    code.copy_from_slice(&payload[..4]);
    Ok(Completion {
        exit_code: i32::from_le_bytes(code),
        timed_out: payload[4] != 0,
    })
}

pub fn chunk_contains_ready(chunk: &[u8]) -> bool {
    chunk
        .windows(READY_MARKER.len())
        .any(|window| window == READY_MARKER.as_bytes())
}

#[derive(Debug, Clone)]
pub struct StdoutParseState {
    pub inside_prompt: bool,
    pub pending: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct StdoutParse {
    pub wrote_data: bool,
    pub began_request: bool,
    pub ended_request: bool,
    pub finished_prompt: bool,
    pub exit_code: Option<i32>,
}

pub fn parse_stdout_chunk(
    mut writer: impl Write,
    chunk: &[u8],
    state: &mut StdoutParseState,
) -> std::io::Result<StdoutParse> {
    if !state.pending.is_empty() {
        let mut merged = state.pending.clone();
        merged.extend_from_slice(chunk);
        state.pending.clear();
        return parse_stdout_chunk_no_pending(&mut writer, &merged, state);
    }
    parse_stdout_chunk_no_pending(&mut writer, chunk, state)
}

fn parse_stdout_chunk_no_pending(
    writer: &mut impl Write,
    chunk: &[u8],
    state: &mut StdoutParseState,
) -> std::io::Result<StdoutParse> {
    let mut result = StdoutParse {
        wrote_data: false,
        began_request: false,
        ended_request: false,
        finished_prompt: false,
        exit_code: None,
    };
    let mut index = 0;
    while index < chunk.len() {
        let escape = match chunk[index..].iter().position(|b| *b == 0x1b) {
            Some(offset) => index + offset,
            None => {
                if !state.inside_prompt && index < chunk.len() {
                    writer.write_all(&chunk[index..])?;
                    result.wrote_data = true;
                }
                break;
            }
        };
        if !state.inside_prompt && escape > index {
            writer.write_all(&chunk[index..escape])?;
            result.wrote_data = true;
        }
        let marker_end = match chunk[escape..].iter().position(|b| *b == 0x07) {
            Some(offset) => escape + offset,
            None => {
                state.pending.extend_from_slice(&chunk[escape..]);
                break;
            }
        };
        let marker = &chunk[escape..=marker_end];
        if marker == READY_MARKER.as_bytes() {
            state.inside_prompt = true;
        } else if marker == PROMPT_END_MARKER.as_bytes() {
            state.inside_prompt = false;
            result.finished_prompt = true;
        } else if marker == COMMAND_BEGIN_MARKER.as_bytes() {
            state.inside_prompt = false;
            result.began_request = true;
        } else if let Some(exit_code) = parse_exit_code(marker) {
            state.inside_prompt = false;
            result.ended_request = true;
            result.exit_code = Some(exit_code);
        } else if !state.inside_prompt {
            writer.write_all(marker)?;
            result.wrote_data = true;
        }
        index = marker_end + 1;
    }
    Ok(result)
}

fn parse_exit_code(marker: &[u8]) -> Option<i32> {
    if !marker.starts_with(COMMAND_DONE_PREFIX.as_bytes()) {
        return None;
    }
    let body = &marker[COMMAND_DONE_PREFIX.len()..marker.len() - 1];
    std::str::from_utf8(body).ok()?.parse().ok()
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

fn hex_decode(value: &str) -> Result<Vec<u8>> {
    let bytes = value.as_bytes();
    if bytes.len() % 2 != 0 {
        return Err(AppError::Msg("invalid request".to_string()));
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut index = 0;
    while index < bytes.len() {
        let hi = from_hex(bytes[index])?;
        let lo = from_hex(bytes[index + 1])?;
        out.push((hi << 4) | lo);
        index += 2;
    }
    Ok(out)
}

fn from_hex(byte: u8) -> Result<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(AppError::Msg("invalid request".to_string())),
    }
}
