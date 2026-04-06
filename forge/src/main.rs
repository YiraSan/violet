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

mod build;
mod deps;
mod disk;
mod log;
mod platform;
mod run;

use clap::{Parser, Subcommand};
use owo_colors::OwoColorize;

use platform::Platform;

#[derive(Parser)]
#[command(name = "forge", about = "The violetOS build system")]
struct Cli {
    /// Target platform.
    #[arg(long, value_enum, default_value_t = Platform::Aarch64Qemu, global = true)]
    platform: Platform,

    /// Build in release mode.
    #[arg(long, default_value_t = false, global = true)]
    release: bool,

    /// Log QEMU interrupts to debug.log.
    #[arg(long, default_value_t = false, global = true)]
    debug_int: bool,

    /// Start QEMU paused, waiting for GDB.
    #[arg(long, default_value_t = false, global = true)]
    debugger: bool,

    /// Enable hardware acceleration (KVM/HVF).
    #[arg(long, default_value_t = false, global = true)]
    accel: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Build the disk image.
    Build,
    /// Build and run in QEMU.
    Run,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    println!("violetOS — forge v{}\n", env!("CARGO_PKG_VERSION").bold());

    match cli.command {
        Command::Build => {
            build::build(cli.platform, cli.release)?;
        }
        Command::Run => {
            let img = build::build(cli.platform, cli.release)?;

            let opts = run::RunOptions {
                debug_int: cli.debug_int,
                debugger: cli.debugger,
                accel: cli.accel,
            };

            run::run(cli.platform, &img, &opts)?;
        }
    }

    Ok(())
}
