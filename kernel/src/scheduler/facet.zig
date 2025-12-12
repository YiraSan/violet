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
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;

const heap = mem.heap;

const Prism = scheduler.Prism;

// --- scheduler/facet.zig --- //

const Facet = @This();
const FacetMap = heap.SlotMap(Facet);
pub const Id = FacetMap.Key;

var facets_map: FacetMap = .init();
var facets_map_lock: mem.RwLock = .{};

id: Id,
prism_id: Prism.Id,
