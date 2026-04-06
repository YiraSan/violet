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

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

use anyhow::{Context, Result};

const IMAGE_SIZE: u64 = 64 * 1024 * 1024;
const BIOS_PART_SIZE: u64 = 1024 * 1024;
const EFI_PART_SIZE: u64 = 33 * 1024 * 1024;

pub fn create_image(path: &Path) -> Result<(File, u64)> {
    {
        let file = File::create(path).context("creating disk image")?;
        file.set_len(IMAGE_SIZE).context("sizing disk image")?;
    }

    let mut gpt = gpt::GptConfig::new()
        .writable(true)
        .logical_block_size(gpt::disk::LogicalBlockSize::Lb512)
        .create(path)
        .context("creating GPT")?;

    gpt.add_partition("BIOS", BIOS_PART_SIZE, gpt::partition_types::BIOS, 0, None)?;
    gpt.add_partition("VIOLET_OS", EFI_PART_SIZE, gpt::partition_types::EFI, 0, None)?;

    let efi_start_lba = gpt
        .partitions()
        .values()
        .find(|p| p.part_type_guid == gpt::partition_types::EFI)
        .expect("EFI partition not found")
        .first_lba;

    gpt.write()?;

    {
        let mut f = OpenOptions::new().write(true).open(path)?;
        let total_sectors = u32::try_from(IMAGE_SIZE / 512 - 1).unwrap_or(u32::MAX);
        gpt::mbr::ProtectiveMBR::with_lb_size(total_sectors).overwrite_lba0(&mut f)?;
    }

    let disk = OpenOptions::new().read(true).write(true).open(path)?;
    let efi_start_bytes = efi_start_lba * 512;

    Ok((disk, efi_start_bytes))
}

pub fn format_efi<'a>(
    disk: &'a mut File,
    efi_start: u64,
) -> Result<fatfs::FileSystem<PartitionView<'a>>> {
    let mut view = PartitionView::new(disk, efi_start, EFI_PART_SIZE);

    fatfs::format_volume(
        &mut view,
        fatfs::FormatVolumeOptions::new().fat_type(fatfs::FatType::Fat32),
    )
    .context("formatting EFI partition")?;

    fatfs::FileSystem::new(view, fatfs::FsOptions::new()).context("mounting EFI filesystem")
}

pub fn copy_to_fat<IO: Read + Write + Seek>(
    dir: &fatfs::Dir<'_, IO>,
    name: &str,
    host_path: &Path,
) -> Result<()> {
    let data = fs::read(host_path)
        .with_context(|| format!("reading {}", host_path.display()))?;

    let mut f = dir.create_file(name)?;
    f.write_all(&data)?;
    Ok(())
}

pub fn copy_dir_to_fat<IO: Read + Write + Seek>(
    src: &Path,
    dest: &fatfs::Dir<'_, IO>,
) -> Result<()> {
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_str().expect("non-UTF8 filename");
        let path = entry.path();

        if entry.file_type()?.is_dir() {
            let sub = dest.create_dir(name_str)?;
            copy_dir_to_fat(&path, &sub)?;
        } else {
            copy_to_fat(dest, name_str, &path)?;
        }
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
        Self {
            file,
            start,
            end: start + size,
            pos: 0,
        }
    }

    fn clamp_len(&self, len: usize) -> usize {
        let remaining = (self.end - (self.start + self.pos)) as usize;
        len.min(remaining)
    }
}

impl Read for PartitionView<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let len = self.clamp_len(buf.len());
        self.file.seek(SeekFrom::Start(self.start + self.pos))?;
        let n = self.file.read(&mut buf[..len])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Write for PartitionView<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let len = self.clamp_len(buf.len());
        self.file.seek(SeekFrom::Start(self.start + self.pos))?;
        let n = self.file.write(&buf[..len])?;
        self.pos += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Seek for PartitionView<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let size = self.end - self.start;
        let new_pos = match pos {
            SeekFrom::Start(p) => p as i64,
            SeekFrom::End(p) => size as i64 + p,
            SeekFrom::Current(p) => self.pos as i64 + p,
        };

        if new_pos < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek before partition start",
            ));
        }

        self.pos = new_pos as u64;
        Ok(self.pos)
    }
}
