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

// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const basalt = @import("basalt");

const sync = basalt.sync;

const Prism = sync.Prism;
const Facet = sync.Facet;

// --- proto/umbilical.zig --- //

pub const prism_options = Prism.Options{
    .arg_formats = .pair64,
    .notify_on_drop = .sidelist,
    .queue_mode = .backpressure,
    .queue_size = 1,
};

pub const InvocationArg = packed struct(u64) {};

const Umbilical = @This();

facet: Facet,
