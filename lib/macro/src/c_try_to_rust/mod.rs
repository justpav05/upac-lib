// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

//! `#[derive(CTryToRust)]` — generates `impl TryFrom<&CRust> for Rust`,
//! validating the C-ABI struct first and then converting it into an owned
//! Rust domain type (fallible inbound direction).

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{Data, DeriveInput, Error, Fields, Ident, PathSegment, Type, parse_macro_input};

use crate::common::{PRIMITIVES, SHARED_TYPES, generic_arg, segment_name};

fn string_from_c(ident: &Ident) -> TokenStream2 {
    quote! {
        {
            let s: &str = (&value.#ident).try_into()?;
            s.to_owned()
        }
    }
}

fn option_from_c(ident: &Ident, segment: &PathSegment) -> TokenStream2 {
    let Some(inner_name) = generic_arg(segment).and_then(segment_name) else {
        return quote! { compile_error!("CTryToRust: unsupported Option inner type") };
    };

    if inner_name == "String" {
        quote! { Option::<&str>::try_from(&value.#ident)?.map(str::to_owned) }
    } else if inner_name == "HookMessageFn" {
        quote! { value.#ident }
    } else {
        quote! { compile_error!("CTryToRust: unsupported Option inner type") }
    }
}

fn vec_from_c(ident: &Ident, segment: &PathSegment) -> TokenStream2 {
    let Some(inner_name) = generic_arg(segment).and_then(segment_name) else {
        return quote! { compile_error!("CTryToRust: unsupported Vec element type") };
    };

    if inner_name == "String" {
        quote! {
            {
                unsafe { value.#ident.validate()? };
                unsafe { value.#ident.as_slice() }
                    .iter()
                    .map(<&str>::try_from)
                    .map(|element| element.map(str::to_owned))
                    .collect::<Result<Vec<_>, ErrorKind>>()?
            }
        }
    } else if PRIMITIVES.contains(&inner_name.as_str()) {
        quote! {
            {
                unsafe { value.#ident.validate()? };
                unsafe { value.#ident.as_borrowed() }.to_vec()
            }
        }
    } else {
        quote! { Vec::try_from(&value.#ident)? }
    }
}

fn primitive_from_c(ident: &Ident) -> TokenStream2 {
    quote! { value.#ident }
}

fn composite_from_c(ident: &Ident, name: &str) -> TokenStream2 {
    let rust_ty = format_ident!("{name}");
    quote! { #rust_ty::try_from(&value.#ident)? }
}

fn field_path_from_c(ident: &Ident, segment: &PathSegment) -> TokenStream2 {
    match segment.ident.to_string().as_str() {
        "String" => string_from_c(ident),
        "Option" => option_from_c(ident, segment),
        "Vec" => vec_from_c(ident, segment),
        name if PRIMITIVES.contains(&name) || SHARED_TYPES.contains(&name) => primitive_from_c(ident),
        name => composite_from_c(ident, name),
    }
}

fn ptr_from_c(ident: &Ident) -> TokenStream2 {
    quote! {
        {
            if value.#ident.is_null() {
                return Err(ErrorKind::InvalidEntry);
            }
            value.#ident
        }
    }
}

fn field_from_c_fallible(ident: &Ident, ty: &Type) -> TokenStream2 {
    if let Type::Array(_) = ty {
        return quote! { value.#ident };
    }

    if let Type::Ptr(_) = ty {
        return ptr_from_c(ident);
    }

    let Type::Path(type_path) = ty else {
        return quote! { compile_error!("CTryToRust: unsupported field type") };
    };

    match type_path.path.segments.last() {
        Some(segment) => field_path_from_c(ident, segment),
        None => quote! { compile_error!("CTryToRust: unsupported field type") },
    }
}

fn try_from_impl(name: &Ident, c_name: &Ident, field_values: &[TokenStream2]) -> TokenStream2 {
    quote! {
        impl TryFrom<&#c_name> for #name {
            type Error = ErrorKind;

            fn try_from(value: &#c_name) -> Result<Self, ErrorKind> {
                unsafe { value.validate()? };

                Ok(#name {
                    #(#field_values)*
                })
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
                return Error::new_spanned(name, "CTryToRust only supports structs with named fields")
                    .to_compile_error()
                    .into();
            }
        },
        _ => {
            return Error::new_spanned(name, "CTryToRust only supports structs")
                .to_compile_error()
                .into();
        }
    };

    let mut field_values = Vec::new();

    for field in fields {
        let Some(ident) = field.ident.as_ref() else {
            return Error::new_spanned(field, "CTryToRust only supports named fields")
                .to_compile_error()
                .into();
        };

        let value = field_from_c_fallible(ident, &field.ty);
        field_values.push(quote! { #ident: #value, });
    }

    try_from_impl(name, &c_name, &field_values).into()
}
