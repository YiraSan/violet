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

const std = @import("std");

pub fn build(b: *std.Build) void {
    const is_module = b.option(bool, "is_module", "is_module") orelse false;

    const basalt_mod = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "is_module", is_module);
    basalt_mod.addImport("build_options", build_options.createModule());
}
