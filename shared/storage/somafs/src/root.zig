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

const std = @import("std");
const diskio = @import("diskio");

pub const SFS_MAGIC: u64 = 0x534F4D4120465321; // "SOMA FS!"

pub const CHUNCK_SIZE = 0x2000;
pub const MIN_SECTOR_SIZE = 512;

pub const SemanticVersion = packed struct(u32) {
    major: u12,
    minor: u12,
    patch: u8,
};

pub const Header = packed struct {
    // 0.1.0 //
    magic: u64 = SFS_MAGIC,
    version: SemanticVersion,
    last_comp_version: SemanticVersion,

    _reserved: [496]u8,
};

pub const DataBlock = packed struct {
    /// BLAKE3-256 cryptographic checksum used for deduplication and integrity
    hash: u256,
    refcount: u64,
    size: u64,
};

// Size Check
comptime {
    if (@sizeOf(Header) != MIN_SECTOR_SIZE) @compileError("Header is too large");
    if (@sizeOf(DataBlock) > MIN_SECTOR_SIZE) @compileError("DataBlock is too large");
}
