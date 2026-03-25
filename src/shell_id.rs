use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

pub fn validate(value: &str) -> Result<(), &'static str> {
    if value.is_empty() {
        return Err("empty shell id");
    }
    if is_reserved_windows_name(value) {
        return Err("invalid shell id");
    }
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            continue;
        }
        return Err("invalid shell id");
    }
    Ok(())
}

pub fn generate() -> String {
    let n = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    format!("{pid:x}{n:x}")
}

fn is_reserved_windows_name(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "con"
            | "prn"
            | "aux"
            | "nul"
            | "com1"
            | "com2"
            | "com3"
            | "com4"
            | "com5"
            | "com6"
            | "com7"
            | "com8"
            | "com9"
            | "lpt1"
            | "lpt2"
            | "lpt3"
            | "lpt4"
            | "lpt5"
            | "lpt6"
            | "lpt7"
            | "lpt8"
            | "lpt9"
    )
}
