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

use std::fs::{self, OpenOptions};
use std::io::{Cursor, Read};
use std::path::PathBuf;

use anyhow::{Context, Result, anyhow};

use crate::log;
use crate::platform::Platform;

const LIMINE_URL: &str =
    "https://codeberg.org/Limine/Limine/archive/v11.x-binary.zip";
const LIMINE_DIR: &str = ".violet/limine/";

const RPI4_UEFI_URL: &str =
    "https://github.com/pftf/RPi4/releases/download/v1.51/RPi4_UEFI_Firmware_v1.51.zip";
const RPI4_UEFI_DIR: &str = ".violet/rpi4_uefi/";

const EDK2_DIR: &str = ".violet/edk2/";
const EDK2_PADDING: u64 = 64 * 1024 * 1024;

fn download(url: &str) -> Result<Vec<u8>> {
    let mut response = ureq::get(url).call().context("HTTP request failed")?;
    let mut buffer = Vec::new();
    response
        .body_mut()
        .as_reader()
        .read_to_end(&mut buffer)
        .context("reading response body")?;
    Ok(buffer)
}

fn download_and_extract(url: &str, dest_dir: &str) -> Result<()> {
    let data = download(url)?;
    let reader = Cursor::new(data);
    let mut archive = zip::ZipArchive::new(reader).context("opening zip archive")?;
    archive.extract(dest_dir).context("extracting zip archive")?;
    Ok(())
}

pub fn fetch_limine() -> Result<PathBuf> {
    let dir = PathBuf::from(LIMINE_DIR);

    if dir.exists() {
        log::info("limine already cached");
        return Ok(dir);
    }

    log::info("downloading limine...");
    fs::create_dir_all(&dir)?;
    download_and_extract(LIMINE_URL, ".violet/")?;
    log::success("limine downloaded");

    Ok(dir)
}

pub fn fetch_rpi4_uefi() -> Result<PathBuf> {
    let dir = PathBuf::from(RPI4_UEFI_DIR);

    if dir.exists() {
        log::info("rpi4 uefi firmware already cached");
        return Ok(dir);
    }

    log::info("downloading rpi4 uefi firmware...");
    fs::create_dir_all(&dir)?;
    download_and_extract(RPI4_UEFI_URL, RPI4_UEFI_DIR)?;
    log::success("rpi4 uefi firmware downloaded");

    Ok(dir)
}

pub fn fetch_edk2(platform: Platform) -> Result<PathBuf> {
    let cache_path = platform
        .edk2_cache_path()
        .ok_or_else(|| anyhow!("{} does not support QEMU", platform.name()))?;
    let url = platform
        .edk2_url()
        .ok_or_else(|| anyhow!("{} has no EDK2 firmware", platform.name()))?;

    let path = PathBuf::from(cache_path);

    if path.exists() {
        return Ok(path);
    }

    log::info(&format!("downloading edk2 firmware for {}...", platform.name()));
    fs::create_dir_all(EDK2_DIR)?;

    let data = download(url)?;
    fs::write(&path, data)?;

    if platform.edk2_needs_padding() {
        OpenOptions::new()
            .write(true)
            .open(&path)?
            .set_len(EDK2_PADDING)?;
    }

    log::success("edk2 firmware downloaded");

    Ok(path)
}
