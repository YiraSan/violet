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
use std::fs::File;
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::process::Command;

use anyhow::anyhow;
use escargot::CargoBuild;
use clap::{Parser, Subcommand, ValueEnum};
use fatfs::Dir;
use gpt::GptConfig;
use zip::ZipArchive;

use owo_colors::OwoColorize;

fn log_info(msg: &str) {
    println!("{}: {}", "info".bold().blue(), msg);
}

fn log_success(msg: &str) {
    println!("{}:   {}", "ok".bold().green(), msg);
}

#[derive(Parser, Clone, Copy)]
#[command(name = "forge", about = "The violetOS build system")]
struct Args {
    #[arg(long, value_enum, default_value_t = Platform::Aarch64Qemu, global = true)]
    platform: Platform,
    #[arg(long, default_value_t = false, global = true)]
    release: bool,
    #[arg(long, default_value_t = false, global = true)]
    debug: bool,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Copy, Clone, Subcommand)]
enum Commands {
    Build,
    Run,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, ValueEnum)]
enum Platform {
    Aarch64Qemu,
    Riscv64Qemu,
    Rpi4,
    Rk3588,
}

impl Platform {
    fn name(&self) -> &str {
        match self {
            Platform::Aarch64Qemu => "aarch64-qemu",
            Platform::Riscv64Qemu => "riscv64-qemu",
            Platform::Rpi4 => "rpi4",
            Platform::Rk3588 => "rk3588",
        }
    }
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let version = env!("CARGO_PKG_VERSION");
    println!("violetOS - forge v{}\n", version.bold());

    match args.command {
        Commands::Build => {
            build(args)?;
        }
        Commands::Run => {
            build(args)?;
            run(args)?;
        }
    }

    Ok(())
}

fn fetch_limine() -> anyhow::Result<PathBuf> {
    let cache_dir = PathBuf::from(".violet/limine/");

    if cache_dir.exists() { 
        log_info("limine is already downloaded.");

        return Ok(cache_dir);
    } else {
        std::fs::create_dir_all(&cache_dir)?;
    }
    
    log_info("downloading limine...");

    let url = "https://codeberg.org/Limine/Limine/archive/v11.x-binary.zip";
    
    let mut response = ureq::get(url).call()?;
    let mut buffer = Vec::new();
    response.body_mut().as_reader().read_to_end(&mut buffer)?;

    let reader = Cursor::new(buffer);
    let mut archive = ZipArchive::new(reader)?;

    archive.extract(".violet/")?;

    Ok(cache_dir)
}

fn fetch_rpi4_uefi() -> anyhow::Result<PathBuf> {
    let cache_dir = PathBuf::from(".violet/rpi4_uefi/");

    if cache_dir.exists() { 
        log_info("rpi4 uefi firmware is already downloaded.");
    
        return Ok(cache_dir);
    } else {
        std::fs::create_dir_all(&cache_dir)?;
    }

    log_info("downloading rpi4 uefi firmware...");

    let url = "https://github.com/pftf/RPi4/releases/download/v1.51/RPi4_UEFI_Firmware_v1.51.zip";
    
    let mut response = ureq::get(url).call()?;
    let mut buffer = Vec::new();
    response.body_mut().as_reader().read_to_end(&mut buffer)?;

    let reader = Cursor::new(buffer);
    let mut archive = ZipArchive::new(reader)?;

    archive.extract(".violet/rpi4_uefi/")?;

    Ok(cache_dir)
}

fn build(args: Args) -> anyhow::Result<()> {
    let target_name = args.platform.name();

    log_info(&format!("building violetOS for {}", target_name.purple().bold()));

    let img_path = format!("bin/violet_{}.img", target_name);

    if !fs::exists("bin")? {
        fs::create_dir_all("bin")?;
    }

    {
        let disk = fs::File::create(&img_path)?;
        disk.set_len(64 * 1024 * 1024)?;
    }

    let mut gpt = GptConfig::new()
        .writable(true)
        .logical_block_size(gpt::disk::LogicalBlockSize::Lb512)
        .create(&img_path)?;

    gpt.add_partition("BIOS", 1024 * 1024, gpt::partition_types::BIOS, 0, None)?;

    let efi_size_bytes = 33 * 1024 * 1024;
    gpt.add_partition("VIOLET_OS", efi_size_bytes, gpt::partition_types::EFI, 0, None)?;

    let efi_part = gpt.partitions().values()
        .find(|p| p.part_type_guid == gpt::partition_types::EFI)
        .expect("EFI partition not found");
    
    let efi_start_bytes = efi_part.first_lba * 512;

    gpt.write()?;

    {
        let mut disk_for_mbr = fs::OpenOptions::new().write(true).open(&img_path)?;
        let total_sectors = u32::try_from((64 * 1024 * 1024) / 512 - 1).unwrap_or(0xFFFFFFFF);
        let pmbr = gpt::mbr::ProtectiveMBR::with_lb_size(total_sectors);
        pmbr.overwrite_lba0(&mut disk_for_mbr)?;
    }

    let mut disk = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&img_path)?;

    let mut efi_view = PartitionView::new(&mut disk, efi_start_bytes, efi_size_bytes);
    fatfs::format_volume(&mut efi_view, fatfs::FormatVolumeOptions::new().fat_type(fatfs::FatType::Fat32))?;

    let fs = fatfs::FileSystem::new(efi_view, fatfs::FsOptions::new())?;
    let root_dir = fs.root_dir();

    {
        let limine_dir = root_dir.create_dir("limine/")?;

        let limine = fetch_limine()?;

        log_info("installing limine...");
        
        let mut limine_conf_fat = limine_dir.create_file("limine.conf")?;
        let limine_conf_data = fs::read("forge/limine.conf")?;
        limine_conf_fat.write_all(&limine_conf_data)?;

        let mut limine_uefi_cd_fat = limine_dir.create_file("limine-uefi-cd.bin")?;
        let limine_uefi_cd_data = fs::read(limine.join("limine-uefi-cd.bin"))?;
        limine_uefi_cd_fat.write_all(&limine_uefi_cd_data)?;

        let efi_dir = root_dir.create_dir("EFI/")?;
        let boot_efi_dir = efi_dir.create_dir("BOOT/")?;

        match args.platform {
            Platform::Aarch64Qemu | Platform::Rpi4 | Platform::Rk3588 => {
                let mut boot_file = boot_efi_dir.create_file("BOOTAA64.EFI")?;
                let boot_file_data = fs::read(limine.join("BOOTAA64.EFI"))?;
                boot_file.write_all(&boot_file_data)?;
            },
            Platform::Riscv64Qemu => {
                let mut boot_file = boot_efi_dir.create_file("BOOTRISCV64.EFI")?;
                let boot_file_data = fs::read(limine.join("BOOTRISCV64.EFI"))?;
                boot_file.write_all(&boot_file_data)?;
            },
        }

        log_success("limine installed");
    }

    match args.platform {
        Platform::Rpi4 => {
            let rpi4_uefi = fetch_rpi4_uefi()?;
            log_info("installing rpi4 uefi firmware...");
            copy_dir_recursively(rpi4_uefi, &root_dir)?;
            root_dir.remove("Readme.md")?;
            log_success("rpi4 uefi firmware installed");
        },
        _ => {},
    }

    {
        let target_file = match args.platform {
            Platform::Rpi4 => "kernel/aarch64-v8a.json",
            Platform::Aarch64Qemu | Platform::Rk3588 => "kernel/aarch64-v8.2a-lse.json",
            _ => anyhow::bail!("'{}' is unsupported", target_name),
        };

        log_info("building kernel...");

        let mut build_command = CargoBuild::new()
            .package("kernel")
            .target(target_file)
            .arg("-Z").arg("json-target-spec")
            .arg("-Z").arg("build-std=core,compiler_builtins")
            .env("RUSTFLAGS", "-C target-feature=-fp-armv8,-neon");

        if args.release { 
            build_command = build_command.release();
        }

        let result = build_command.run()?;
        let kernel_bin_path = result.path();

        log_info("installing kernel...");

        let violet_dir = root_dir.create_dir("violet/")?;

        let mut kernel_file_fat = violet_dir.create_file("kernel.elf")?;
        let kernel_data = fs::read(&kernel_bin_path)?;
        kernel_file_fat.write_all(&kernel_data)?;

        log_success("kernel installed");
    }

    log_success(&format!("violetOS successfully built at '{}'", img_path));

    drop(root_dir);
    drop(fs);

    disk.sync_all()?;

    Ok(())
}

fn copy_dir_recursively(
    src_path: PathBuf,
    dest_dir: &Dir<'_, PartitionView<'_>>,
) -> anyhow::Result<()> {
    let src_dir = src_path.read_dir()?;

    for entry in src_dir {
        let entry = entry?;
        let entry_type = entry.file_type()?;

        let file_path = src_path.join(entry.file_name());
        let file_name = entry.file_name();
        let file_name_str = file_name.to_str().expect("No file name found.");

        if entry_type.is_dir() {
            let fs_dir = dest_dir.create_dir(file_name_str)?;
            copy_dir_recursively(file_path, &fs_dir)?;
        } else if entry_type.is_file() {
            let mut fs_file = dest_dir.create_file(file_name_str)?;
            let file_data = fs::read(&file_path)?;
            fs_file.write_all(&file_data)?;
        }
    }

    Ok(())
}

fn fetch_edk2(platform: Platform) -> anyhow::Result<PathBuf> {
    let path = PathBuf::from(match platform {
        Platform::Aarch64Qemu => ".violet/edk2/AA64.fd",
        Platform::Riscv64Qemu => ".violet/edk2/RISCV64.fd",
        _ => return Err(anyhow!("'{}' platform is not supported on QEMU", platform.name())),
    });

    if path.exists() {
        return Ok(path);
    } else {
        fs::create_dir_all(".violet/edk2/")?;
    }

    let url = match platform {
        Platform::Aarch64Qemu => "https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
        Platform::Riscv64Qemu => "https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd",
        _ => return Err(anyhow!("...")),
    };

    let mut response = ureq::get(url).call()?;
    let mut buffer = Vec::new();
    response.body_mut().as_reader().read_to_end(&mut buffer)?;

    fs::write(&path, buffer)?;

    Ok(path)
}

fn run(args: Args) -> anyhow::Result<()> {
    let target_name = args.platform.name();
    let img_path = format!("bin/violet-{}.img", target_name);

    let uefi_firmware = fetch_edk2(args.platform)?;

    let qemu_command_str = match args.platform {
        Platform::Aarch64Qemu => "qemu-system-aarch64",
        Platform::Riscv64Qemu => "qemu-system-riscv64",
        _ => return Err(anyhow!("'{}' platform is not supported on QEMU", target_name)),
    };

    let mut qemu_command = Command::new(qemu_command_str);

    qemu_command
        .arg("-cpu").arg("cortex-a76")
        .arg("-machine").arg("virt,secure=off,virtualization=off")
        .arg("-m").arg("4G")
        .arg("-smp").arg("4")
        .arg("-bios").arg(uefi_firmware)
        .arg("-device").arg("virtio-blk-pci,drive=disk0,disable-legacy=on")
        .arg("-drive").arg(format!("file={},if=none,id=disk0,format=raw", img_path))
        .arg("-device").arg("virtio-gpu-pci")
        .arg("-serial").arg("stdio")
        .arg("--no-reboot")
        .arg("--no-shutdown");

    if args.debug {
        qemu_command
            .arg("-boot").arg("d")
            .arg("-d").arg("int")
            .arg("-D").arg("debug.log");
    }

    let status = qemu_command.status()?;

    if !status.success() {
        anyhow::bail!("qemu failed !");
    }

    Ok(())
}

pub struct PartitionView<'a> {
    file: &'a mut File,
    start: u64,
    end: u64,
    pos: u64,
}

impl<'a> PartitionView<'a> {
    pub fn new(file: &'a mut File, start: u64, size: u64) -> Self {
        Self { file, start, end: start + size, pos: 0 }
    }
}

impl<'a> Read for PartitionView<'a> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.file.seek(SeekFrom::Start(self.start + self.pos))?;
        let max_read = (self.end - (self.start + self.pos)) as usize;
        let len = std::cmp::min(buf.len(), max_read);
        let n = self.file.read(&mut buf[..len])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl<'a> Write for PartitionView<'a> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.seek(SeekFrom::Start(self.start + self.pos))?;
        let max_write = (self.end - (self.start + self.pos)) as usize;
        let len = std::cmp::min(buf.len(), max_write);
        let n = self.file.write(&buf[..len])?;
        self.pos += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl<'a> Seek for PartitionView<'a> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new_pos = match pos {
            SeekFrom::Start(p) => p as i64,
            SeekFrom::End(p) => (self.end - self.start) as i64 + p,
            SeekFrom::Current(p) => self.pos as i64 + p,
        };
        if new_pos < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid seek"));
        }
        self.pos = new_pos as u64;
        Ok(self.pos)
    }
}
