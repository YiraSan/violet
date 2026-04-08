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

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::{disk, deps, log};
use crate::platform::Platform;

use owo_colors::OwoColorize;

const BIN_DIR: &str = "bin";
const LIMINE_CONF: &str = "forge/limine.conf";

pub fn build(platform: Platform, release: bool) -> Result<PathBuf> {
    log::info(&format!("building violetOS for {}", platform.name().bold().magenta()));

    let target_spec = platform
        .target_spec()
        .ok_or_else(|| anyhow::anyhow!("{} is not yet supported", platform.name()))?;

    log::info("compiling kernel...");
    let kernel_elf = compile_kernel(target_spec, platform, release)?;
    log::success("kernel compiled");

    fs::create_dir_all(BIN_DIR)?;
    let img_path = PathBuf::from(format!("{}/violet_{}.img", BIN_DIR, platform.name()));

    log::info("creating disk image...");
    let (mut disk, efi_start) = disk::create_image(&img_path)?;
    let fs = disk::format_efi(&mut disk, efi_start)?;
    let root = fs.root_dir();

    install_limine(&root, platform)?;

    if platform.needs_rpi4_uefi() {
        install_rpi4_uefi(&root)?;
    }

    if platform.needs_rpi3_uefi() {
        install_rpi3_uefi(&root)?;
    }

    log::info("installing kernel...");
    let violet_dir = root.create_dir("violet/")?;
    disk::copy_to_fat(&violet_dir, "kernel.elf", &kernel_elf)?;
    log::success("kernel installed");

    drop(violet_dir);
    drop(root);
    drop(fs);

    disk.sync_all()?;

    log::success(&format!("image ready at '{}'", img_path.display()));

    Ok(img_path)
}

fn compile_kernel(
    target_spec: &str,
    platform: Platform,
    release: bool,
) -> Result<PathBuf> {
    let mut cmd = escargot::CargoBuild::new()
        .package("kernel")
        .target(target_spec)
        .arg("-Z").arg("json-target-spec")
        .arg("-Z").arg("build-std=core,compiler_builtins")
        .arg("-Z").arg("build-std-features=compiler-builtins-mem");

    if let Some(flags) = platform.rustflags() {
        cmd = cmd.env("RUSTFLAGS", flags);
    }

    if release {
        cmd = cmd.release();
    }

    let result = cmd.run().context("cargo build failed")?;
    Ok(result.path().to_path_buf())
}

fn install_limine<IO: std::io::Read + std::io::Write + std::io::Seek>(
    root: &fatfs::Dir<'_, IO>,
    platform: Platform,
) -> Result<()> {
    let limine_host = deps::fetch_limine()?;

    log::info("installing limine...");

    let limine_dir = root.create_dir("limine/")?;
    disk::copy_to_fat(&limine_dir, "limine.conf", Path::new(LIMINE_CONF))?;
    disk::copy_to_fat(
        &limine_dir,
        "limine-uefi-cd.bin",
        &limine_host.join("limine-uefi-cd.bin"),
    )?;

    let efi_dir = root.create_dir("EFI/")?;
    let boot_dir = efi_dir.create_dir("BOOT/")?;

    let efi_name = platform.efi_boot_filename();
    disk::copy_to_fat(&boot_dir, efi_name, &limine_host.join(efi_name))?;

    log::success("limine installed");
    Ok(())
}

fn install_rpi4_uefi<IO: std::io::Read + std::io::Write + std::io::Seek>(
    root: &fatfs::Dir<'_, IO>,
) -> Result<()> {
    let fw_dir = deps::fetch_rpi4_uefi()?;

    log::info("installing rpi4 uefi firmware...");
    disk::copy_dir_to_fat(&fw_dir, root)?;

    let _ = root.remove("Readme.md");

    log::success("rpi4 uefi firmware installed");
    Ok(())
}

fn install_rpi3_uefi<IO: std::io::Read + std::io::Write + std::io::Seek>(
    root: &fatfs::Dir<'_, IO>,
) -> Result<()> {
    let fw_dir = deps::fetch_rpi3_uefi()?;

    log::info("installing rpi3 uefi firmware...");
    disk::copy_dir_to_fat(&fw_dir, root)?;

    let _ = root.remove("Readme.md");

    log::success("rpi3 uefi firmware installed");
    Ok(())
}
