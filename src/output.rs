use std::io::{self, Write};

pub fn print_usage(mut writer: impl Write) -> io::Result<()> {
    writer.write_all(
        b"shlice\n\n  shlice start [--id <shell-id>] -- <command...>\n  shlice exec [--id <shell-id>] [--timeout <seconds>] <command>\n  echo \"<command>\" | shlice exec [--id <shell-id>]\n  shlice stop [<shell-id>]\n  shlice status [--id <shell-id>]\n  shlice list\n\nHelp flags: -h, --help, -?\nDefault shell id: main\n",
    )
}

pub fn print_started(id: &str) {
    let _ = writeln!(io::stdout(), "started {id}");
}

pub fn print_stopped(id: &str) {
    let _ = writeln!(io::stdout(), "stopped {id}");
}

pub fn print_error(msg: &str) {
    let _ = writeln!(io::stderr(), "error: {msg}");
}

pub fn print_status_header(mut writer: impl Write) -> io::Result<()> {
    writer.write_all(b"id\tstatus\tpid\tbroker\tcmd\n")
}

pub fn print_no_shells(mut writer: impl Write) -> io::Result<()> {
    writer.write_all(b"no shells\n")
}

pub fn print_status_line(
    mut writer: impl Write,
    id: &str,
    status: &str,
    pid: Option<u32>,
    broker_pid: Option<u32>,
    command_line: &str,
) -> io::Result<()> {
    match (pid, broker_pid) {
        (Some(pid), Some(broker_pid)) => writeln!(
            writer,
            "{id}\t{status}\t{pid}\t{broker_pid}\t{command_line}"
        ),
        (Some(pid), None) => writeln!(writer, "{id}\t{status}\t{pid}\t-\t{command_line}"),
        (None, Some(broker_pid)) => {
            writeln!(writer, "{id}\t{status}\t-\t{broker_pid}\t{command_line}")
        }
        (None, None) => writeln!(writer, "{id}\t{status}\t-\t-\t{command_line}"),
    }
}
