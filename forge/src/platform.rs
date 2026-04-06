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

use clap::ValueEnum;

#[derive(Debug, Copy, Clone, PartialEq, Eq, ValueEnum)]
pub enum Platform {
    Aarch64Qemu,
    Riscv64Qemu,
    X86_64Pc,
    Rpi4,
    Rpi3,
    Rk3588,
    Vf2,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Arch {
    Aarch64,
    Riscv64,
    X86_64,
}

impl Platform {
    pub fn name(self) -> &'static str {
        match self {
            Self::Aarch64Qemu => "aarch64-qemu",
            Self::Riscv64Qemu => "riscv64-qemu",
            Self::X86_64Pc => "x86-64pc",
            Self::Rpi4 => "rpi4",
            Self::Rpi3 => "rpi3",
            Self::Rk3588 => "rk3588",
            Self::Vf2 => "vf2",
        }
    }

    pub fn arch(self) -> Arch {
        match self {
            Self::Aarch64Qemu | Self::Rpi4 | Self::Rpi3 | Self::Rk3588 => Arch::Aarch64,
            Self::Riscv64Qemu | Self::Vf2 => Arch::Riscv64,
            Self::X86_64Pc => Arch::X86_64,
        }
    }

    pub fn target_spec(self) -> Option<&'static str> {
        match self {
            Self::Rpi4 | Self::Rpi3 => Some("kernel/aarch64-v8a.json"),
            Self::Aarch64Qemu | Self::Rk3588 => Some("kernel/aarch64-v8.2a-lse.json"),
            Self::X86_64Pc => Some("kernel/x86-64.json"),
            Self::Riscv64Qemu | Self::Vf2 => None,
        }
    }

    pub fn efi_boot_filename(self) -> &'static str {
        match self.arch() {
            Arch::Aarch64 => "BOOTAA64.EFI",
            Arch::Riscv64 => "BOOTRISCV64.EFI",
            Arch::X86_64 => "BOOTX64.EFI",
        }
    }

    pub fn rustflags(self) -> Option<&'static str> {
        match self.arch() {
            Arch::Aarch64 => {
                Some("-C target-feature=-fp-armv8,-neon")
            }
            _ => None,
        }
    }

    pub fn qemu_binary(self) -> Option<&'static str> {
        match self {
            Self::Aarch64Qemu => Some("qemu-system-aarch64"),
            Self::Riscv64Qemu => Some("qemu-system-riscv64"),
            Self::X86_64Pc => Some("qemu-system-x86_64"),
            _ => None,
        }
    }

    pub fn edk2_url(self) -> Option<&'static str> {
        match self.arch() {
            Arch::Aarch64 => Some("https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd"),
            Arch::Riscv64 => Some("https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd"),
            Arch::X86_64 => Some("https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"),
        }
    }

    pub fn edk2_cache_path(self) -> Option<&'static str> {
        match self.arch() {
            Arch::Aarch64 => Some(".violet/edk2/AA64.fd"),
            Arch::Riscv64 => Some(".violet/edk2/RISCV64.fd"),
            Arch::X86_64 => Some(".violet/edk2/X86_64.fd"),
        }
    }

    pub fn edk2_needs_padding(self) -> bool {
        self == Self::Aarch64Qemu
    }

    pub fn needs_rpi4_uefi(self) -> bool {
        self == Self::Rpi4
    }

    pub fn qemu_default_cpu(self) -> Option<&'static str> {
        match self {
            Self::Aarch64Qemu => Some("cortex-a76"),
            _ => None,
        }
    }

    pub fn configure_qemu(self, cmd: &mut Command, img_path: &Path, uefi_fw: &Path) {
        let fw = uefi_fw.to_str().expect("non-UTF8 firmware path");
        let img = img_path.to_str().expect("non-UTF8 image path");

        match self {
            Self::Aarch64Qemu => {
                cmd.args(["-machine", "virt,secure=off,virtualization=off"]);
            }
            Self::Riscv64Qemu => {
                cmd.args(["-machine", "virt"]);
            }
            Self::X86_64Pc => {
                cmd.args(["-machine", "q35"]);
            }
            _ => return,
        }

        cmd.args(["-m", "1G"])
            .args(["-smp", "1"])
            .args(["-drive", &format!("if=pflash,format=raw,readonly=on,file={fw}")])
            .args(["-device", "virtio-blk-pci,drive=disk0,disable-legacy=on"])
            .args(["-drive", &format!("file={img},if=none,id=disk0,format=raw")])
            .args(["-device", "virtio-gpu-pci"])
            .args(["-serial", "stdio"])
            .arg("--no-reboot")
            .arg("--no-shutdown");
    }
}
