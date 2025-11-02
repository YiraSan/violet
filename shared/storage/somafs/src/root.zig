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
