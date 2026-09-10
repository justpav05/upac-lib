// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

//! `#[derive(CValidate)]` — generates an unsafe `validate()` that checks
//! `struct_size` and every field, driven by `#[optional]`/`#[non_empty]`
//! field attributes.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;

use quote::quote;

use syn::{Data, DeriveInput, Error, Field, Fields, Ident, PathSegment, Type, TypePtr, parse_macro_input};

use crate::common::{VALIDATABLE_COMPOSITES, generic_arg, segment_name};

fn has_attr(field: &Field, name: &str) -> bool {
    field.attrs.iter().any(|attr| attr.path().is_ident(name))
}

fn cslice_validate(ident: &Ident, optional: bool) -> TokenStream2 {
    if optional {
        quote! {
            if !self.#ident.ptr.is_null() {
                unsafe { self.#ident.validate()? };
            }
        }
    } else {
        quote! {
            unsafe { self.#ident.validate()?; }
        }
    }
}

fn composite_validate(ident: &Ident) -> TokenStream2 {
    quote! {
        unsafe { self.#ident.validate()?; }
    }
}

fn cvec_empty_check(ident: &Ident, non_empty: bool) -> TokenStream2 {
    if non_empty {
        quote! {
            if self.#ident.len == 0 {
                return Err(ErrorKind::InvalidEntry);
            }
        }
    } else {
        quote! {}
    }
}

fn cvec_element_check(ident: &Ident, seg: &PathSegment) -> TokenStream2 {
    match generic_arg(seg).and_then(segment_name) {
        Some(inner) if inner == "CSlice" || VALIDATABLE_COMPOSITES.contains(&inner.as_str()) => quote! {
            for element in unsafe { self.#ident.as_slice() } {
                unsafe { element.validate()? };
            }
        },
        _ => quote! {},
    }
}

fn cvec_validate(ident: &Ident, seg: &PathSegment, non_empty: bool) -> TokenStream2 {
    let empty_check = cvec_empty_check(ident, non_empty);
    let element_check = cvec_element_check(ident, seg);

    quote! {
        unsafe { self.#ident.validate()?; }
        #empty_check
        #element_check
    }
}

fn field_path_validate(ident: &Ident, seg: &PathSegment, optional: bool, non_empty: bool) -> TokenStream2 {
    match seg.ident.to_string().as_str() {
        "CSlice" => cslice_validate(ident, optional),
        "CVec" => cvec_validate(ident, seg, non_empty),
        name if VALIDATABLE_COMPOSITES.contains(&name) => composite_validate(ident),
        _ => quote! {},
    }
}

fn field_ptr_validate(ident: &Ident, ptr: &TypePtr) -> TokenStream2 {
    let Type::Path(tp) = ptr.elem.as_ref() else {
        return quote! {};
    };
    let Some(seg) = tp.path.segments.last() else {
        return quote! {};
    };

    let name = seg.ident.to_string();

    if name == "CancelToken" {
        return quote! {
            if self.#ident.is_null() {
                return Err(ErrorKind::InvalidEntry);
            }
        };
    }

    if VALIDATABLE_COMPOSITES.contains(&name.as_str()) {
        quote! {
            unsafe {
                if self.#ident.is_null() {
                    return Err(ErrorKind::InvalidEntry);
                }
                (*self.#ident).validate()?;
            }
        }
    } else {
        quote! {}
    }
}

fn field_validate(field: &Field) -> TokenStream2 {
    let Some(ident) = field.ident.as_ref() else {
        return quote! { compile_error!("CValidate only supports named fields") };
    };
    let optional = has_attr(field, "optional");
    let non_empty = has_attr(field, "non_empty");

    match &field.ty {
        Type::Path(tp) => match tp.path.segments.last() {
            Some(seg) => field_path_validate(ident, seg, optional, non_empty),
            None => quote! {},
        },
        Type::Ptr(ptr) => field_ptr_validate(ident, ptr),
        _ => quote! {},
    }
}

fn validate_impl(name: &Ident, validations: &[TokenStream2]) -> TokenStream2 {
    quote! {
        impl #name {
            pub unsafe fn validate(&self) -> Result<(), ErrorKind> {
                check_size::<#name>(self.struct_size)?;
                #(#validations)*
                Ok(())
            }
        }

        impl crate::types::CValidatable for #name {
            unsafe fn validate(&self) -> Result<(), ErrorKind> {
                unsafe { #name::validate(self) }
            }
        }
    }
}

pub(crate) fn expand(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;

    let fields = match &input.data {
        Data::Struct(s) => match &s.fields {
            Fields::Named(named) => &named.named,
            _ => {
                return Error::new_spanned(name, "CValidate only supports structs with named fields")
                    .to_compile_error()
                    .into();
            }
        },
        _ => {
            return Error::new_spanned(name, "CValidate only supports structs")
                .to_compile_error()
                .into();
        }
    };

    let validations: Vec<TokenStream2> = fields.iter().map(field_validate).collect();

    validate_impl(name, &validations).into()
}
