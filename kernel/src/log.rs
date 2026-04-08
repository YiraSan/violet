// Copyright (c) 2024-2026 YiraSan
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use core::fmt::{self, Write};
use crate::serial::SERIAL_IMPL;
use owo_colors::OwoColorize;

#[derive(Clone, Copy)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
}

#[doc(hidden)]
pub fn _log(level: LogLevel, scope: &str, args: fmt::Arguments) {
    let mut port = SERIAL_IMPL.lock();

    let _ = write!(port, "{}", "[kernel".magenta());

    if !scope.is_empty() && scope != "default" {
        let _ = write!(port, ":{}", scope.magenta());
    }
    let _ = write!(port, "{}", "] ".magenta());

    match level {
        LogLevel::Error => { let _ = write!(port, "{}: ", "error".red()); },
        LogLevel::Warn  => { let _ = write!(port, "{}: ", "warn".yellow()); },
        LogLevel::Info  => { let _ = write!(port, "{}: ", "info".cyan()); },
        LogLevel::Debug => { let _ = write!(port, "{}: ", "debug".bright_black()); },
    }

    let _ = port.write_fmt(args);
    let _ = port.write_char('\n');
}

#[macro_export]
macro_rules! info {
    (scope: $scope:expr, $($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Info, $scope, format_args!($($arg)*)) };
    ($($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Info, "default", format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! warn {
    (scope: $scope:expr, $($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Warn, $scope, format_args!($($arg)*)) };
    ($($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Warn, "default", format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! error {
    (scope: $scope:expr, $($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Error, $scope, format_args!($($arg)*)) };
    ($($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Error, "default", format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! debug {
    (scope: $scope:expr, $($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Debug, $scope, format_args!($($arg)*)) };
    ($($arg:tt)*) => { $crate::log::_log($crate::log::LogLevel::Debug, "default", format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! clear_console {
    () => {
        $crate::print!("\x1b[2J\x1b[H");
    };
}
