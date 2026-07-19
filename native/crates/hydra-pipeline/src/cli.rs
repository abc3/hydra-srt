#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessKind {
    Route {
        route_id: String,
        process_instance_id: String,
    },
    /// Dry run: parse, plan and build a route config without starting it.
    ValidateConfig,
    NdiDiscovery {
        helper_instance_id: String,
    },
    NdiProbe {
        probe_instance_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError {
    message: String,
}

impl CliError {
    pub fn json_line(&self) -> String {
        serde_json::json!({"event": "error", "message": self.message}).to_string()
    }
}

pub fn parse_args<I>(args: I) -> Result<ProcessKind, CliError>
where
    I: IntoIterator<Item = String>,
{
    let args: Vec<_> = args.into_iter().collect();

    match args.as_slice() {
        [command, rest @ ..] if command == "route" => parse_route(rest),
        [command] if command == "validate-config" => Ok(ProcessKind::ValidateConfig),
        [command, rest @ ..] if command == "ndi-discovery" => {
            parse_single_identity(rest, "--helper-instance-id")
                .map(|helper_instance_id| ProcessKind::NdiDiscovery { helper_instance_id })
        }
        [command, rest @ ..] if command == "ndi-probe" => {
            parse_single_identity(rest, "--probe-instance-id")
                .map(|probe_instance_id| ProcessKind::NdiProbe { probe_instance_id })
        }
        _ => Err(CliError {
            message: "unknown or invalid command".to_string(),
        }),
    }
}

fn parse_route(args: &[String]) -> Result<ProcessKind, CliError> {
    let route_id = option_value(args, "--route-id")?;
    let process_instance_id = option_value(args, "--process-instance-id")?;

    if args.len() != 4 || route_id.is_empty() || process_instance_id.is_empty() {
        return Err(CliError {
            message: "route requires --route-id and --process-instance-id".to_string(),
        });
    }

    Ok(ProcessKind::Route {
        route_id,
        process_instance_id,
    })
}

fn parse_single_identity(args: &[String], flag: &str) -> Result<String, CliError> {
    let value = option_value(args, flag)?;
    if args.len() != 2 || value.is_empty() {
        return Err(CliError {
            message: format!("command requires {flag}"),
        });
    }
    Ok(value)
}

fn option_value(args: &[String], wanted: &str) -> Result<String, CliError> {
    args.windows(2)
        .find(|pair| pair[0] == wanted)
        .map(|pair| pair[1].clone())
        .ok_or_else(|| CliError {
            message: format!("missing {wanted}"),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_positional_cli_is_rejected() {
        assert!(parse_args(["route-123".to_string()]).is_err());
    }

    #[test]
    fn validate_config_takes_no_arguments() {
        assert_eq!(
            parse_args(["validate-config".to_string()]),
            Ok(ProcessKind::ValidateConfig)
        );
        assert!(parse_args(["validate-config".to_string(), "extra".to_string()]).is_err());
    }
}
