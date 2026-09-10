// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

//! Consts and type-introspection helpers shared by more than one derive
//! macro in this crate.

use syn::{GenericArgument, PathArguments, PathSegment, Type};

pub(crate) const PRIMITIVES: &[&str] = &[
    "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "bool", "f32", "f64",
];

pub(crate) const SHARED_TYPES: &[&str] = &["FileDiffKind", "PackageDiffKind", "DiffFileSource", "FsKind"];

pub(crate) const VALIDATABLE_COMPOSITES: &[&str] = &[
    "CVersion",
    "CPackageMeta",
    "CPackageInfo",
    "CDiffFileEntryCommon",
    "CDiffPrefixFileEntry",
    "CDiffConfigFileEntry",
    "CDiffUntrackedFileEntry",
    "CDiffPackageEntry",
    "CConfigCommitEntry",
    "CSearchFileEntry",
    "CPrefixEntry",
    "CHistoryEntry",
    "CRequestBase",
    "CPackageDependency",
];

pub(crate) fn generic_arg(segment: &PathSegment) -> Option<&Type> {
    let PathArguments::AngleBracketed(args) = &segment.arguments else {
        return None;
    };

    args.args.iter().find_map(|arg| match arg {
        GenericArgument::Type(ty) => Some(ty),
        _ => None,
    })
}

pub(crate) fn segment_name(ty: &Type) -> Option<String> {
    let Type::Path(type_path) = ty else {
        return None;
    };

    type_path.path.segments.last().map(|segment| segment.ident.to_string())
}
