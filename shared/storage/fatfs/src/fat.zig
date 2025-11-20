// Copyright (c) 2024-2025 The violetOS Authors
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

pub const FatVariant = enum {
    fat12,
    fat16,
    fat32,
};

pub const BIOSParameterBlock = packed struct {
    // zig fmt: off

    // Jump + OEM Name
    jmp_boot: [3]u8,              // 0x00
    oem_name: [8]u8,              // 0x03

    // BIOS Parameter Block (common)
    bytes_per_sector: u16,        // 0x0B
    sectors_per_cluster: u8,      // 0x0D
    reserved_sector_count: u16,   // 0x0E
    num_fats: u8,                 // 0x10
    root_entry_count: u16,        // 0x11
    total_sectors_16: u16,        // 0x13
    media: u8,                    // 0x15
    fat_size_16: u16,             // 0x16
    sectors_per_track: u16,       // 0x18
    num_heads: u16,               // 0x1A
    hidden_sectors: u32,          // 0x1C
    total_sectors_32: u32,        // 0x20

    // FAT32-only extended section
    fat_size_32: u32,             // 0x24 (used if fat_size_16 == 0)
    ext_flags: u16,               // 0x28
    fs_version: u16,              // 0x2A
    root_cluster: u32,            // 0x2C
    fs_info: u16,                 // 0x30
    backup_boot_sector: u16,      // 0x32
    reserved: [12]u8,             // 0x34

    // Drive + Volume Info
    drive_number: u8,             // 0x40
    reserved1: u8,                // 0x41
    boot_signature: u8,           // 0x42
    volume_id: u32,               // 0x43
    volume_label: [11]u8,         // 0x47
    fs_type: [8]u8,               // 0x52

    boot_code: [448]u8,           // 0x5A
    boot_sector_sig: u16,         // 0x1FE

    // zig fmt: on

    pub fn parse(sector: []const u8) !*const @This() {
        if (sector.len < 512) return error.BufferTooSmall;
        const bpb: *const BIOSParameterBlock = @ptrCast(sector.ptr);
        if (bpb.boot_sector_sig != 0xAA55) return error.InvalidSignature;
        if (bpb.bytes_per_sector & (bpb.bytes_per_sector - 1) != 0 or bpb.bytes_per_sector < 512 or bpb.bytes_per_sector > 4096)
            return error.InvalidSectorSize;
        return bpb;
    }

    pub fn fatSize(self: *const @This()) u32 {
        return if (self.fat_size_16 != 0)
            @as(u32, self.fat_size_16)
        else
            self.fat_size_32;
    }

    pub fn totalSectors(self: *const @This()) u32 {
        return if (self.total_sectors_16 != 0)
            @as(u32, self.total_sectors_16)
        else
            self.total_sectors_32;
    }

    pub fn rootDirSectors(self: *const @This()) u32 {
        return (@as(u32, self.root_entry_count) * 32 + @as(u32, self.bytes_per_sector) - 1) / @as(u32, self.bytes_per_sector);
    }

    pub fn dataSectors(self: *const @This()) u32 {
        return self.totalSectors() - @as(u32, self.reserved_sector_count) - (@as(u32, self.num_fats) * self.fatSize()) - self.rootDirSectors();
    }

    pub fn clusterCount(self: *const @This()) u32 {
        return self.dataSectors() / @as(u32, self.sectors_per_cluster);
    }

    pub fn variant(self: *const @This()) FatVariant {
        const clusters = self.clusterCount();

        return if (clusters < 4085)
            .fat12
        else if (clusters < 65525)
            .fat16
        else
            .fat32;
    }
};
