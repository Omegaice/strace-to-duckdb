use crate::types::Syscall;

/// Parse a regular strace line: HH:MM:SS.micro syscall(args) = ret <duration>
pub fn parse_regular(line: &str) -> Option<Syscall> {
    // Split timestamp from rest: "HH:MM:SS.micro syscall(args) = ret <duration>"
    let (timestamp, rest) = line.split_once(' ')?;

    // Find the opening parenthesis to get syscall name
    let paren_pos = rest.find('(')?;
    let syscall = rest[..paren_pos].trim();

    // Find the matching closing parenthesis and equals sign
    // We need to find ") = " pattern (with possible extra spaces) to split args from return value
    let rest_from_paren = &rest[paren_pos + 1..];

    // Find the position of ") = " with flexible whitespace
    // Look for ")" followed by whitespace and "="
    let close_paren_pos = rest_from_paren.find(')')?;
    let after_paren = &rest_from_paren[close_paren_pos + 1..];
    let _equals_pos_in_after = after_paren.trim_start().strip_prefix("= ")?;
    let equals_pos = close_paren_pos;

    // Extract args (everything between parentheses)
    let args = &rest_from_paren[..equals_pos];

    // Everything after ") = " (with flexible whitespace)
    // Skip past the ")" and whitespace and "="
    let after_close_paren = &rest_from_paren[equals_pos + 1..]; // Skip ")"
    let after_equals = after_close_paren
        .trim_start()
        .strip_prefix("=")?
        .trim_start();

    // Parse return value and optional error/duration
    // Format could be:
    // "0 <0.000004>"
    // "-1 ENOENT (No such file or directory) <0.000030>"
    // "0x55edad95f000 <0.000004>"

    // Find duration (always at the end in angle brackets)
    let duration = if let Some(duration_start) = after_equals.rfind('<') {
        let duration_end = after_equals.rfind('>')?;
        let duration_str = &after_equals[duration_start + 1..duration_end];
        duration_str.parse::<f64>().ok()
    } else {
        None
    };

    // Remove duration part to parse return value and error
    let before_duration = if let Some(pos) = after_equals.rfind('<') {
        after_equals[..pos].trim()
    } else {
        after_equals.trim()
    };

    // Parse return value and optional error
    let parts: Vec<&str> = before_duration.splitn(2, ' ').collect();
    let return_value_str = parts[0];

    // Parse return value (handle hex like 0x55edad95f000)
    let return_value = if return_value_str.starts_with("0x") {
        i64::from_str_radix(&return_value_str[2..], 16).ok()
    } else if return_value_str.starts_with("-0x") {
        i64::from_str_radix(&return_value_str[3..], 16)
            .map(|v| -v)
            .ok()
    } else {
        return_value_str.parse::<i64>().ok()
    };

    // Parse error code and message if present
    let (error_code, error_message) = if parts.len() > 1 {
        let error_part = parts[1];
        // Format: "ENOENT (No such file or directory)"
        if let Some(paren_pos) = error_part.find('(') {
            let code = error_part[..paren_pos].trim();
            let msg_start = paren_pos + 1;
            let msg_end = error_part.rfind(')')?;
            let msg = &error_part[msg_start..msg_end];
            (Some(code.to_string()), Some(msg.to_string()))
        } else {
            (Some(error_part.to_string()), None)
        }
    } else {
        (None, None)
    };

    Some(Syscall {
        timestamp: timestamp.to_string(),
        syscall: syscall.to_string(),
        args: args.to_string(),
        return_value,
        error_code,
        error_message,
        duration,
        unfinished: false,
        resumed: false,
    })
}

/// Parse an unfinished strace line: HH:MM:SS.micro syscall(args <unfinished ...>) = ?
pub fn parse_unfinished(line: &str) -> Option<Syscall> {
    // Check if line contains the unfinished marker
    if !line.contains("<unfinished ...>") {
        return None;
    }

    // Split timestamp from rest
    let (timestamp, rest) = line.split_once(' ')?;

    // Find the opening parenthesis to get syscall name
    let paren_pos = rest.find('(')?;
    let syscall = rest[..paren_pos].trim();

    // Find the unfinished marker and extract args
    let rest_from_paren = &rest[paren_pos + 1..];
    let unfinished_pos = rest_from_paren.find("<unfinished ...>")?;

    // Args is everything before <unfinished ...>
    let args = rest_from_paren[..unfinished_pos].trim();

    Some(Syscall {
        timestamp: timestamp.to_string(),
        syscall: syscall.to_string(),
        args: args.to_string(),
        return_value: None, // Unfinished syscalls show "= ?"
        error_code: None,
        error_message: None,
        duration: None,
        unfinished: true,
        resumed: false,
    })
}

/// Parse a resumed strace line: HH:MM:SS.micro <... syscall resumed>args) = ret
pub fn parse_resumed(line: &str) -> Option<Syscall> {
    // Check if line contains the resumed marker
    if !line.contains("resumed>") {
        return None;
    }

    // Split timestamp from rest
    let (timestamp, rest) = line.split_once(' ')?;

    // Format: <... syscall resumed>args) = ret <duration>
    // Find the syscall name between "<... " and " resumed>"
    let resumed_start = rest.find("<... ")?;
    let resumed_end = rest.find(" resumed>")?;
    let syscall = &rest[resumed_start + 5..resumed_end];

    // Everything after "resumed>" is: args) = ret <duration>
    let after_resumed = &rest[resumed_end + 9..]; // Skip " resumed>"

    // Find the closing parenthesis and "="
    let close_paren_pos = after_resumed.find(')')?;
    let args = &after_resumed[..close_paren_pos];

    // Find "=" to get return value
    let equals_pos = after_resumed.find(" = ")?;
    let after_equals = &after_resumed[equals_pos + 3..];

    // Parse return value and optional error/duration (same as regular)
    let duration = if let Some(duration_start) = after_equals.rfind('<') {
        let duration_end = after_equals.rfind('>')?;
        let duration_str = &after_equals[duration_start + 1..duration_end];
        duration_str.parse::<f64>().ok()
    } else {
        None
    };

    let before_duration = if let Some(pos) = after_equals.rfind('<') {
        after_equals[..pos].trim()
    } else {
        after_equals.trim()
    };

    let parts: Vec<&str> = before_duration.splitn(2, ' ').collect();
    let return_value_str = parts[0];

    let return_value = if return_value_str.starts_with("0x") {
        i64::from_str_radix(&return_value_str[2..], 16).ok()
    } else if return_value_str.starts_with("-0x") {
        i64::from_str_radix(&return_value_str[3..], 16)
            .map(|v| -v)
            .ok()
    } else {
        return_value_str.parse::<i64>().ok()
    };

    let (error_code, error_message) = if parts.len() > 1 {
        let error_part = parts[1];
        if let Some(paren_pos) = error_part.find('(') {
            let code = error_part[..paren_pos].trim();
            let msg_start = paren_pos + 1;
            let msg_end = error_part.rfind(')')?;
            let msg = &error_part[msg_start..msg_end];
            (Some(code.to_string()), Some(msg.to_string()))
        } else {
            (Some(error_part.to_string()), None)
        }
    } else {
        (None, None)
    };

    Some(Syscall {
        timestamp: timestamp.to_string(),
        syscall: syscall.to_string(),
        args: args.to_string(),
        return_value,
        error_code,
        error_message,
        duration,
        unfinished: false,
        resumed: true,
    })
}

/// Parse any strace line by trying all formats
pub fn parse_line(line: &str) -> Option<Syscall> {
    // Try unfinished and resumed first since they have specific markers
    parse_unfinished(line)
        .or_else(|| parse_resumed(line))
        .or_else(|| parse_regular(line))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_regular_simple_success() {
        let line = "22:21:11.524449 brk(NULL) = 0x55edad95f000 <0.000004>";
        let result = parse_regular(line);

        assert!(result.is_some(), "Should parse simple success line");
        let syscall = result.unwrap();

        assert_eq!(syscall.timestamp, "22:21:11.524449");
        assert_eq!(syscall.syscall, "brk");
        assert_eq!(syscall.args, "NULL");
        assert_eq!(syscall.return_value, Some(0x55edad95f000_i64));
        assert_eq!(syscall.duration, Some(0.000004));
        assert_eq!(syscall.error_code, None);
        assert_eq!(syscall.error_message, None);
        assert!(!syscall.unfinished);
        assert!(!syscall.resumed);
    }

    #[test]
    fn test_parse_regular_with_error() {
        let line = r#"22:21:11.524519 access("/etc/ld-nix.so.preload", R_OK) = -1 ENOENT (No such file or directory) <0.000030>"#;
        let result = parse_regular(line);

        assert!(result.is_some(), "Should parse error line");
        let syscall = result.unwrap();

        assert_eq!(syscall.timestamp, "22:21:11.524519");
        assert_eq!(syscall.syscall, "access");
        assert_eq!(syscall.args, r#""/etc/ld-nix.so.preload", R_OK"#);
        assert_eq!(syscall.return_value, Some(-1));
        assert_eq!(syscall.error_code, Some("ENOENT".to_string()));
        assert_eq!(
            syscall.error_message,
            Some("No such file or directory".to_string())
        );
        assert_eq!(syscall.duration, Some(0.000030));
    }

    #[test]
    fn test_parse_regular_complex_args() {
        let line = r#"22:21:11.524791 newfstatat(AT_FDCWD, "/nix/store/ga8daf4c0airy2v5akmg3lcv5saik7nf-pipewire-1.4.9-jack/lib/", {st_mode=S_IFDIR|0555, st_size=11, ...}, 0) = 0 <0.000006>"#;
        let result = parse_regular(line);

        assert!(result.is_some(), "Should parse complex args");
        let syscall = result.unwrap();

        assert_eq!(syscall.timestamp, "22:21:11.524791");
        assert_eq!(syscall.syscall, "newfstatat");
        assert_eq!(
            syscall.args,
            r#"AT_FDCWD, "/nix/store/ga8daf4c0airy2v5akmg3lcv5saik7nf-pipewire-1.4.9-jack/lib/", {st_mode=S_IFDIR|0555, st_size=11, ...}, 0"#
        );
        assert_eq!(syscall.return_value, Some(0));
        assert_eq!(syscall.error_code, None);
        assert_eq!(syscall.duration, Some(0.000006));
    }

    #[test]
    fn test_parse_line_tries_all_formats() {
        let line = "22:21:11.524449 brk(NULL) = 0x55edad95f000 <0.000004>";
        let result = parse_line(line);
        assert!(result.is_some(), "parse_line should use parse_regular");
    }

    #[test]
    fn test_parse_invalid_line_returns_none() {
        let line = "This is not a valid strace line";
        let result = parse_line(line);
        assert!(result.is_none(), "Should return None for invalid lines");
    }

    #[test]
    fn test_parse_unfinished() {
        let line = "22:21:24.927885 poll([{fd=8, events=POLLIN}, {fd=7, events=POLLIN}], 2, -1 <unfinished ...>) = ?";
        let result = parse_unfinished(line);

        assert!(result.is_some(), "Should parse unfinished line");
        let syscall = result.unwrap();

        assert_eq!(syscall.timestamp, "22:21:24.927885");
        assert_eq!(syscall.syscall, "poll");
        assert_eq!(
            syscall.args,
            "[{fd=8, events=POLLIN}, {fd=7, events=POLLIN}], 2, -1"
        );
        assert_eq!(syscall.return_value, None);
        assert_eq!(syscall.duration, None);
        assert!(syscall.unfinished);
        assert!(!syscall.resumed);
    }

    #[test]
    fn test_parse_unfinished_simple() {
        let line = "22:21:24.927885 wait4(1387721 <unfinished ...>) = ?";
        let result = parse_unfinished(line);

        assert!(result.is_some(), "Should parse simple unfinished line");
        let syscall = result.unwrap();

        assert_eq!(syscall.timestamp, "22:21:24.927885");
        assert_eq!(syscall.syscall, "wait4");
        assert_eq!(syscall.args, "1387721");
        assert!(syscall.unfinished);
    }

    #[test]
    fn test_parse_line_tries_unfinished() {
        let line = "22:21:24.927885 poll([{fd=8, events=POLLIN}], 2, -1 <unfinished ...>) = ?";
        let result = parse_line(line);

        assert!(result.is_some(), "parse_line should handle unfinished");
        let syscall = result.unwrap();
        assert!(syscall.unfinished);
    }
}
