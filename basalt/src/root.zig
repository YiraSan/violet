// Copyright (c) 2024-2025 The violetOS authors
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

pub const sync = @import("sync/root.zig");
pub const heap = @import("heap/root.zig");
pub const module = @import("module/root.zig");
pub const process = @import("process/root.zig");
pub const proto = @import("proto/root.zig");
pub const syscall = @import("syscall/root.zig");
pub const task = @import("task/root.zig");
pub const time = @import("time/root.zig");

pub var umbilical: sync.Facet = undefined;
