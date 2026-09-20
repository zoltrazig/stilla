//! Effect-semantics model — docs/effects.md §5 (element + lattice
//! interface, §5.7 provider contract) and §14 (minimal scope), the
//! HIR-side summary in docs/hir.md §6.2. This is the **M1b** effect
//! infrastructure: an abstract semantic resource model, a lattice
//! *engine*, and the default product instance, independent of any pass.
//! The HIR integration (transfer, function summaries, derived legality
//! queries) lives in `passes/hir_effects.zig`.
//!
//! This file is the aggregate module: a thin re-export hub over the
//! effect-model pieces, split along the seams of docs/effects.md so the
//! model stays one import (`@import("stilla").effects`) for consumers
//! while each concern keeps its own file:
//!
//! - `effects_lattice.zig` — the summary element and its lattice algebra,
//!   the pending/ready `State`, and the `Interner` (§5.1–§5.4, §10.1);
//! - `effects_registry.zig` — the `ResourceRegistry` of `stable` /
//!   `disjoint` domain facts (§5.5–§5.6);
//! - `effects_engine.zig` — providers, the `Ops` table, the `Engine`,
//!   the `ProductLattice` / `HierarchyLattice` instances, and the
//!   standard-library host-domain ids (§5.7);
//! - `effects_host.zig` — host metadata (`HostDecl` / `HostEffects` /
//!   `StillaExecution`) and the effect-environment fingerprint (§13);
//! - `effects_conflict.zig` — the §5.6 conflict queries over a registry;
//! - `effects_hash.zig` — the canonical fixed-width hash encoding shared
//!   by the interners, the carrier hash, and the fingerprint (§13).

const std = @import("std");

const lattice = @import("effects_lattice.zig");
const registry_mod = @import("effects_registry.zig");
const engine_mod = @import("effects_engine.zig");
const host_mod = @import("effects_host.zig");
const conflict_mod = @import("effects_conflict.zig");

// -- element lattice (effects_lattice.zig) --------------------------------

pub const ConstId = lattice.ConstId;
pub const HostBindingId = lattice.HostBindingId;
pub const HostDomainId = lattice.HostDomainId;
pub const RuntimeDomainId = lattice.RuntimeDomainId;
pub const ProviderId = lattice.ProviderId;
pub const ResourceId = lattice.ResourceId;
pub const ModeId = lattice.ModeId;
pub const EffectMode = lattice.EffectMode;
pub const mode_count = lattice.mode_count;
pub const max_mode_count = lattice.max_mode_count;
pub const ModeSet = lattice.ModeSet;
pub const modeBit = lattice.modeBit;
pub const builtin_mode_set = lattice.builtin_mode_set;
pub const ModeDecl = lattice.ModeDecl;
pub const default_modes = lattice.default_modes;
pub const modeDeclOf = lattice.modeDeclOf;
pub const modeDeclLessThan = lattice.modeDeclLessThan;
pub const OperandUse = lattice.OperandUse;
pub const EffectResource = lattice.EffectResource;
pub const isUnknownResource = lattice.isUnknownResource;
pub const ResourceCtx = lattice.ResourceCtx;
pub const AliasMap = lattice.AliasMap;
pub const EffectAccess = lattice.EffectAccess;
pub const AccessSet = lattice.AccessSet;
pub const canonicalize = lattice.canonicalize;
pub const canonicalizeMapped = lattice.canonicalizeMapped;
pub const contains = lattice.contains;
pub const joinAccess = lattice.joinAccess;
pub const latticeMeetAccess = lattice.latticeMeetAccess;
pub const Summary = lattice.Summary;
pub const bottom = lattice.bottom;
pub const pure = lattice.pure;
pub const may_trap = lattice.may_trap;
pub const may_diverge = lattice.may_diverge;
pub const top = lattice.top;
pub const host_top = lattice.host_top;
pub const summaryOf = lattice.summaryOf;
pub const join = lattice.join;
pub const sequence = lattice.sequence;
pub const latticeMeet = lattice.latticeMeet;
pub const joinAll = lattice.joinAll;
pub const sequenceAll = lattice.sequenceAll;
pub const isTotal = lattice.isTotal;
pub const isObservableEffectFree = lattice.isObservableEffectFree;
pub const discardView = lattice.discardView;
pub const isPure = lattice.isPure;
pub const State = lattice.State;
pub const RowId = lattice.RowId;
pub const SummaryId = lattice.SummaryId;
pub const pure_id = lattice.pure_id;
pub const top_id = lattice.top_id;
pub const Interner = lattice.Interner;

// -- resource registry (effects_registry.zig) ------------------------------

pub const ResourceRegistry = registry_mod.ResourceRegistry;

// -- lattice engine + providers (effects_engine.zig) -----------------------

pub const Relation = engine_mod.Relation;
pub const ResourceOrder = engine_mod.ResourceOrder;
pub const Provider = engine_mod.Provider;
pub const default_provider_id = engine_mod.default_provider_id;
pub const default_provider_version = engine_mod.default_provider_version;
pub const product_provider = engine_mod.product_provider;
pub const mode_commute_update = engine_mod.mode_commute_update;
pub const hierarchy_modes = engine_mod.hierarchy_modes;
pub const example_hierarchy = engine_mod.example_hierarchy;
pub const stdlib_host_tree = engine_mod.stdlib_host_tree;
pub const domain_builtin = engine_mod.domain_builtin;
pub const domain_io_root = engine_mod.domain_io_root;
pub const domain_collections_root = engine_mod.domain_collections_root;
pub const domain_math_root = engine_mod.domain_math_root;
pub const domain_list = engine_mod.domain_list;
pub const domain_string = engine_mod.domain_string;
pub const domain_array = engine_mod.domain_array;
pub const domain_hashmap = engine_mod.domain_hashmap;
pub const domain_math = engine_mod.domain_math;
pub const Ops = engine_mod.Ops;
pub const ProductLattice = engine_mod.ProductLattice;
pub const HierarchyLattice = engine_mod.HierarchyLattice;
pub const Engine = engine_mod.Engine;

// -- host metadata + fingerprint (effects_host.zig) ------------------------

pub const HostEffects = host_mod.HostEffects;
pub const HostDeclKey = host_mod.HostDeclKey;
pub const HostDecl = host_mod.HostDecl;
pub const StillaExecution = host_mod.StillaExecution;
pub const Environment = host_mod.Environment;
pub const EffectEnvironmentFingerprint = host_mod.EffectEnvironmentFingerprint;

// -- conflict queries (effects_conflict.zig) -------------------------------

pub const Conflict = conflict_mod.Conflict;
pub const conflictOf = conflict_mod.conflictOf;
pub const orderCompatible = conflict_mod.orderCompatible;
