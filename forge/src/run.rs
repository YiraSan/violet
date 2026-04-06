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

use std::path::Path;
use std::process::Command;

use anyhow::{Result, bail};

use crate::deps;
use crate::log;
use crate::platform::Platform;

pub struct RunOptions {
    pub debug_int: bool,
    pub debugger: bool,
    pub accel: bool,
}

pub fn run(platform: Platform, img_path: &Path, opts: &RunOptions) -> Result<()> {
    let qemu_bin = platform
        .qemu_binary()
        .ok_or_else(|| anyhow::anyhow!("{} does not support QEMU", platform.name()))?;

    let uefi_fw = deps::fetch_edk2(platform)?;

    log::info(&format!("launching {} ...", qemu_bin));

    let mut cmd = Command::new(qemu_bin);

    platform.configure_qemu(&mut cmd, img_path, &uefi_fw);

    if opts.debug_int {
        cmd.args(["-d", "int"])
            .args(["-D", "debug.log"]);
    }

    if opts.debugger {
        cmd.arg("-s").arg("-S");
    }

    if opts.accel {
        cmd.args(["-cpu", "host"])
            .args(["-accel", "kvm"])
            .args(["-accel", "hvf"])
            .args(["-accel", "tcg"]);
    } else if let Some(cpu) = platform.qemu_default_cpu() {
        cmd.args(["-cpu", cpu]);
    }

    let status = cmd.status()?;

    if !status.success() {
        bail!("qemu exited with {}", status);
    }

    Ok(())
}
