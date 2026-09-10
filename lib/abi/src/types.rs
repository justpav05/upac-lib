// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::CStr;
use std::mem::{forget, size_of};
use std::ptr::{copy_nonoverlapping, null, null_mut};
use std::slice::{from_raw_parts, from_raw_parts_mut};

use crate::error::ErrorKind;
use crate::memory::{alloc_bytes, free_cslice, free_cvec};

pub fn check_size<T>(struct_size: usize) -> Result<(), ErrorKind> {
    if struct_size != size_of::<T>() {
        return Err(ErrorKind::AbiMismatch);
    }
    Ok(())
}

pub trait CBorrowed {
    type Borrowed: ?Sized;

    fn from_borrowed(value: &Self::Borrowed) -> Self;

    /// # Safety
    /// `self` must currently hold a valid, validated view onto `Self::Borrowed` (e.g. checked via
    /// `validate()`) for the lifetime of the returned reference.
    unsafe fn as_borrowed(&self) -> &Self::Borrowed;
}

pub trait COwned {
    type Owned;

    fn from_owned(value: Self::Owned) -> Self;

    /// # Safety
    /// `self` must actually own the memory it represents (produced via `from_owned`, not a borrowed/
    /// foreign view), since this consumes it and hands ownership to the returned value.
    unsafe fn into_owned(self) -> Self::Owned;
}

pub trait CValidatable {
    /// # Safety
    /// Same contract as the inherent `validate()` this forwards to — the receiver must be a
    /// freshly-received C-ABI struct that hasn't yet been trusted for reads.
    unsafe fn validate(&self) -> Result<(), ErrorKind>;
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CSlice {
    pub ptr: *const u8,
    pub len: usize,
}

impl CSlice {
    /// # Safety
    /// `self.ptr`, if non-null, must point to at least `self.len + 1` readable bytes, the last of which
    /// is the NUL terminator, valid for the lifetime of the returned reference.
    pub unsafe fn as_cstr(&self) -> Result<&CStr, ErrorKind> {
        if self.ptr.is_null() {
            return Err(ErrorKind::InvalidEntry);
        }
        let bytes = unsafe { from_raw_parts(self.ptr, self.len + 1) };
        Ok(CStr::from_bytes_with_nul(bytes)?)
    }

    /// # Safety
    /// `self.ptr`, if non-null, must point to at least `self.len` readable bytes valid for the lifetime
    /// of the returned reference.
    pub unsafe fn as_slice(&self) -> &[u8] {
        if self.ptr.is_null() {
            return &[];
        }
        unsafe { from_raw_parts(self.ptr, self.len) }
    }

    /// # Safety
    /// Same contract as `as_cstr`.
    pub unsafe fn as_str(&self) -> Result<&str, ErrorKind> {
        Ok(unsafe { self.as_cstr()?.to_str()? })
    }

    pub fn from_slice(slice: Option<&[u8]>) -> CSlice {
        match slice {
            None => CSlice { ptr: null(), len: 0 },
            Some(string) => CSlice {
                ptr: string.as_ptr(),
                len: string.len(),
            },
        }
    }

    /// # Safety
    /// Same contract as `as_cstr` — this is the entry point that checks an untrusted, C-supplied
    /// slice is safe to read further.
    pub unsafe fn validate(&self) -> Result<(), ErrorKind> {
        unsafe { self.as_cstr().map(|_| ()) }
    }
}

impl CBorrowed for CSlice {
    type Borrowed = [u8];

    fn from_borrowed(value: &[u8]) -> Self {
        CSlice::from_slice(Some(value))
    }

    unsafe fn as_borrowed(&self) -> &[u8] {
        unsafe { self.as_slice() }
    }
}

impl<'a> TryFrom<&'a CSlice> for &'a str {
    type Error = ErrorKind;

    fn try_from(slice: &'a CSlice) -> Result<Self, ErrorKind> {
        unsafe { slice.as_str() }
    }
}

impl<'a> TryFrom<&'a CSlice> for Option<&'a str> {
    type Error = ErrorKind;

    fn try_from(slice: &'a CSlice) -> Result<Self, ErrorKind> {
        if slice.ptr.is_null() {
            return Ok(None);
        }
        Ok(Some(slice.try_into()?))
    }
}

impl COwned for CSlice {
    type Owned = Vec<u8>;

    fn from_owned(value: Vec<u8>) -> Self {
        let len = value.len();
        let ptr = unsafe { alloc_bytes(len + 1) };

        unsafe {
            copy_nonoverlapping(value.as_ptr(), ptr, len);
            *ptr.add(len) = 0;
        }

        CSlice { ptr, len }
    }

    unsafe fn into_owned(self) -> Vec<u8> {
        let owned = unsafe { self.as_slice() }.to_vec();
        unsafe { free_cslice(&self) };
        owned
    }
}

impl From<Option<String>> for CSlice {
    fn from(value: Option<String>) -> Self {
        match value {
            Some(value) => CSlice::from_owned(value.into_bytes()),
            None => CSlice { ptr: null(), len: 0 },
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CVec<T> {
    pub ptr: *mut T,
    pub len: usize,
}

impl<T> CVec<T> {
    /// # Safety
    /// `self.ptr`, if non-null, must point to `self.len` valid, initialized `T` values — this is the
    /// entry point that checks an untrusted, C-supplied vector is safe to read further.
    pub unsafe fn validate(&self) -> Result<(), ErrorKind> {
        if self.ptr.is_null() && self.len > 0 {
            return Err(ErrorKind::InvalidEntry);
        }
        Ok(())
    }

    /// # Safety
    /// `self.ptr`, if non-null, must point to `self.len` valid, initialized `T` values for the lifetime
    /// of the returned slice.
    pub unsafe fn as_slice(&self) -> &[T] {
        if self.ptr.is_null() || self.len == 0 {
            return &[];
        }
        unsafe { from_raw_parts(self.ptr, self.len) }
    }

    /// # Safety
    /// Same contract as `as_slice`, plus the caller must guarantee exclusive access — no other live
    /// reference to this buffer — for the lifetime of the returned slice.
    pub unsafe fn as_mut_slice(&mut self) -> &mut [T] {
        if self.ptr.is_null() || self.len == 0 {
            return &mut [];
        }
        unsafe { from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl<T> CBorrowed for CVec<T> {
    type Borrowed = [T];

    fn from_borrowed(value: &[T]) -> Self {
        CVec {
            ptr: value.as_ptr() as *mut T,
            len: value.len(),
        }
    }

    unsafe fn as_borrowed(&self) -> &[T] {
        unsafe { self.as_slice() }
    }
}

impl<'a, T, U> TryFrom<&'a CVec<T>> for Vec<U>
where
    U: TryFrom<&'a T, Error = ErrorKind>,
{
    type Error = ErrorKind;

    fn try_from(vec: &'a CVec<T>) -> Result<Self, ErrorKind> {
        unsafe { vec.validate()? };
        unsafe { vec.as_slice() }.iter().map(U::try_from).collect()
    }
}

impl<T> COwned for CVec<T> {
    type Owned = Vec<T>;

    fn from_owned(value: Vec<T>) -> Self {
        let len = value.len();
        if len == 0 {
            return CVec {
                ptr: null_mut(),
                len: 0,
            };
        }

        let ptr = unsafe { alloc_bytes(len * size_of::<T>()) } as *mut T;
        unsafe { copy_nonoverlapping(value.as_ptr(), ptr, len) };
        forget(value);

        CVec { ptr, len }
    }

    unsafe fn into_owned(self) -> Vec<T> {
        let mut owned = Vec::with_capacity(self.len);

        if !self.ptr.is_null() && self.len > 0 {
            unsafe {
                copy_nonoverlapping(self.ptr, owned.as_mut_ptr(), self.len);
                owned.set_len(self.len);
            }
        }

        unsafe { free_cvec(&self) };
        owned
    }
}
