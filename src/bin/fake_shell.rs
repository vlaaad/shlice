use std::io::{self, BufRead, Write};
use std::thread;
use std::time::Duration;

const READY_MARKER: &str = "\x1b]133;A\x07";
const PROMPT_END_MARKER: &str = "\x1b]133;B\x07";
const COMMAND_BEGIN_MARKER: &str = "\x1b]133;C\x07";
const COMMAND_DONE_PREFIX: &str = "\x1b]133;D;";

fn main() {
    let _ = write!(io::stdout(), "{READY_MARKER}fake> {PROMPT_END_MARKER}");
    let _ = io::stdout().flush();
    let stdin = io::stdin();
    let mut current = String::new();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        current.push_str(&line);
        current.push('\n');
        if !balanced(&current) {
            continue;
        }
        let command = current.trim().to_string();
        current.clear();
        let _ = write!(io::stdout(), "{COMMAND_BEGIN_MARKER}");
        let _ = io::stdout().flush();
        match eval(&command) {
            Ok((stdout, stderr, code, sleep_ms)) => {
                if let Some(text) = stderr {
                    let _ = write!(io::stderr(), "{text}");
                    let _ = io::stderr().flush();
                }
                if sleep_ms > 0 {
                    thread::sleep(Duration::from_millis(sleep_ms));
                }
                if let Some(text) = stdout {
                    let _ = write!(io::stdout(), "{text}");
                    let _ = io::stdout().flush();
                }
                let _ = write!(io::stdout(), "{COMMAND_DONE_PREFIX}{code}\x07{READY_MARKER}fake> {PROMPT_END_MARKER}");
                let _ = io::stdout().flush();
            }
            Err(text) => {
                let _ = writeln!(io::stderr(), "error: {text}");
                let _ = write!(io::stdout(), "{COMMAND_DONE_PREFIX}1\x07{READY_MARKER}fake> {PROMPT_END_MARKER}");
                let _ = io::stdout().flush();
            }
        }
    }
}

fn balanced(value: &str) -> bool {
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escape = false;
    for ch in value.chars() {
        if in_string {
            if escape {
                escape = false;
                continue;
            }
            match ch {
                '\\' => escape = true,
                '"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => depth -= 1,
            _ => {}
        }
    }
    depth == 0 && !in_string
}

fn eval(command: &str) -> Result<(Option<String>, Option<String>, i32, u64), String> {
    let normalized = command.replace('\n', " ");
    let trimmed = normalized.trim();
    if trimmed == "(+ 1 2)" {
        return Ok((Some("3\n".to_string()), None, 0, 0));
    }
    if trimmed == "(* 6 7)" {
        return Ok((Some("42\n".to_string()), None, 0, 0));
    }
    if trimmed.contains("println \"warn\"") {
        return Ok((Some(":done\n".to_string()), Some("warn\n".to_string()), 0, 0));
    }
    if trimmed.contains("Thread/sleep 6000") {
        return Ok((Some("one\n:first\n".to_string()), None, 0, 6000));
    }
    if trimmed.contains("Thread/sleep 1000") {
        return Ok((Some("one\n:first\n".to_string()), None, 0, 1000));
    }
    if trimmed.contains("Thread/sleep 200") {
        let tag = trimmed
            .split_whitespace()
            .find(|s| s.starts_with("thread-"))
            .unwrap_or("thread");
        return Ok((Some(format!("{tag}\n:{tag}\n")), None, 0, 200));
    }
    if trimmed == "(+ 1 2)" || trimmed == "2)" {
        return Ok((Some("3\n".to_string()), None, 0, 0));
    }
    if trimmed == "(+ 1" {
        thread::sleep(Duration::from_millis(1500));
        return Ok((None, None, 0, 0));
    }
    if trimmed == "2)" {
        return Ok((Some("3\n".to_string()), None, 0, 0));
    }
    if trimmed.starts_with("(do ") && trimmed.contains(":first") {
        return Ok((Some("one\n:first\n".to_string()), None, 0, 1000));
    }
    if trimmed.starts_with("(do ") && trimmed.contains(":second") {
        return Ok((Some("two\nclear\n:second\n".to_string()), None, 0, 0));
    }
    if trimmed.starts_with("(do ") && trimmed.contains(":thread-") {
        let tag = trimmed.split(':').nth(1).unwrap_or("thread");
        return Ok((Some(format!("{tag}\n:{tag}\n")), None, 0, 200));
    }
    Err(format!("unsupported command: {trimmed}"))
}
