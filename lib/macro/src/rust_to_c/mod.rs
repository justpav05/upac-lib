// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

//! `#[derive(RustToC)]` — generates `impl From<Rust> for CRust`, converting
//! an owned Rust domain type into its C-ABI mirror (outbound direction).

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{Data, DeriveInput, Error, Fields, Ident, PathSegment, Type, parse_macro_input};

use crate::common::{PRIMITIVES, SHARED_TYPES, generic_arg, segment_name};

fn string_to_c(ident: &Ident) -> TokenStream2 {
    quote! { CSlice::from_owned(value.#ident.into_bytes()) }
}

fn option_to_c(ident: &Ident) -> TokenStream2 {
    quote! { value.#ident.into() }
}

fn primitive_to_c(ident: &Ident) -> TokenStream2 {
    quote! { value.#ident }
}

fn composite_to_c(ident: &Ident, name: &str) -> TokenStream2 {
    let c_ty = format_ident!("C{name}");
    quote! { #c_ty::from(value.#ident) }
}

fn vec_to_c(ident: &Ident, segment: &PathSegment) -> TokenStream2 {
    let Some(inner_name) = generic_arg(segment).and_then(segment_name) else {
        return quote! { compile_error!("RustToC: unsupported Vec element type") };
    };

    if inner_name == "String" {
        quote! { CVec::from_owned(value.#ident.into_iter().map(|element| CSlice::from_owned(element.into_bytes())).collect()) }
    } else if PRIMITIVES.contains(&inner_name.as_str()) {
        quote! { CVec::from_owned(value.#ident) }
    } else {
        let c_inner = format_ident!("C{inner_name}");
        quote! { CVec::from_owned(value.#ident.into_iter().map(#c_inner::from).collect()) }
    }
}

fn field_path_to_c(ident: &Ident, segment: &PathSegment) -> TokenStream2 {
    match segment.ident.to_string().as_str() {
        "String" => string_to_c(ident),
        "Option" => option_to_c(ident),
        "Vec" => vec_to_c(ident, segment),
        name if PRIMITIVES.contains(&name) || SHARED_TYPES.contains(&name) => primitive_to_c(ident),
        name => composite_to_c(ident, name),
    }
}

fn field_to_c(ident: &Ident, ty: &Type) -> TokenStream2 {
    if let Type::Array(_) = ty {
        return quote! { value.#ident };
    }

    if let Type::Ptr(_) = ty {
        return quote! { value.#ident };
    }

    let Type::Path(type_path) = ty else {
        return quote! { compile_error!("RustToC: unsupported field type") };
    };

    match type_path.path.segments.last() {
        Some(segment) => field_path_to_c(ident, segment),
        None => quote! { compile_error!("RustToC: unsupported field type") },
    }
}

fn to_c_impl(name: &Ident, c_name: &Ident, field_values: &[TokenStream2]) -> TokenStream2 {
    quote! {
        impl From<#name> for #c_name {
            fn from(value: #name) -> Self {
                #c_name {
                    struct_size: size_of::<#c_name>(),
                    #(#field_values)*
                }
            }
        }
    }
}

pub(crate) fn expand(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let c_name = format_ident!("C{name}");

    let fields = match &input.data {
        Data::Struct(s) => match &s.fields {
            Fields::Named(named) => &named.named,
            _ => {
                return Error::new_spanned(name, "RustToC only supports structs with named fields")
                    .to_compile_error()
                    .into();
            }
        },
        _ => {
            return Error::new_spanned(name, "RustToC only supports structs")
                .to_compile_error()
                .into();
        }
    };

    let mut field_values = Vec::new();

    for field in fields {
        let Some(ident) = field.ident.as_ref() else {
            return Error::new_spanned(field, "RustToC only supports named fields")
                .to_compile_error()
                .into();
        };

        let value = field_to_c(ident, &field.ty);
        field_values.push(quote! { #ident: #value, });
    }

    to_c_impl(name, &c_name, &field_values).into()
}
