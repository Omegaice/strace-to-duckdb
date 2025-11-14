/// Represents a parsed syscall from strace output
#[derive(Debug, Clone, PartialEq)]
pub struct Syscall {
    pub timestamp: String,
    pub syscall: String,
    pub args: String,
    pub return_value: Option<i64>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub duration: Option<f64>,
    pub unfinished: bool,
    pub resumed: bool,
}
