// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use der::pem::LineEnding;
use der::{Decode, DecodePem, Encode, EncodePem};

use ed25519_dalek::{Signature, Verifier, VerifyingKey};

use rcgen::SigningKey;

use x509_cert::Certificate;

use super::error::PkiError;
use super::generate::SigningIdentity;

const SIGNATURE_LEN: usize = 64;
const LENGTH_PREFIX_LEN: usize = 4;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CertificateKind {
    Hook = 0,
}

impl CertificateKind {
    fn from_u8(value: u8) -> Result<Self, PkiError> {
        match value {
            0 => Ok(CertificateKind::Hook),
            _ => Err(PkiError::Malformed),
        }
    }
}

pub struct RootCertificate(pub(crate) Certificate);

impl RootCertificate {
    pub fn to_bytes(&self) -> Result<Vec<u8>, PkiError> {
        Ok(self.0.to_der()?)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, PkiError> {
        Ok(RootCertificate(Certificate::from_der(bytes)?))
    }

    pub fn to_pem(&self) -> Result<String, PkiError> {
        Ok(self.0.to_pem(LineEnding::LF)?)
    }

    pub fn from_pem(pem: &str) -> Result<Self, PkiError> {
        Ok(RootCertificate(Certificate::from_pem(pem.as_bytes())?))
    }
}

pub struct HookSignature {
    pub(crate) certificate_kind: CertificateKind,
    pub(crate) certificate: Certificate,
    pub(crate) signature: Signature,
}

impl HookSignature {
    pub fn sign(hook_bytes: &[u8], signing: &SigningIdentity) -> Result<Self, PkiError> {
        let signature_bytes = signing.key_pair.sign(hook_bytes)?;

        let signature = Signature::try_from(signature_bytes.as_slice()).map_err(|_| PkiError::Malformed)?;

        Ok(HookSignature {
            certificate_kind: CertificateKind::Hook,
            certificate: signing.certificate.clone(),
            signature,
        })
    }

    pub fn verify(&self, hook_bytes: &[u8], root_certificate: &RootCertificate) -> Result<(), PkiError> {
        Self::verify_issued_by(&self.certificate, &root_certificate.0)?;

        let verifying_key = Self::extract_verifying_key(&self.certificate)?;
        verifying_key
            .verify(hook_bytes, &self.signature)
            .map_err(|_| PkiError::InvalidSignature)?;

        Ok(())
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>, PkiError> {
        let certificate_der = self.certificate.to_der()?;

        let mut bytes = Vec::with_capacity(1 + LENGTH_PREFIX_LEN + certificate_der.len() + SIGNATURE_LEN);

        bytes.push(self.certificate_kind as u8);

        bytes.extend_from_slice(&(certificate_der.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&certificate_der);

        bytes.extend_from_slice(&self.signature.to_bytes());

        Ok(bytes)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, PkiError> {
        let (&kind_byte, rest) = bytes.split_first().ok_or(PkiError::Malformed)?;
        let certificate_kind = CertificateKind::from_u8(kind_byte)?;

        if rest.len() < LENGTH_PREFIX_LEN {
            return Err(PkiError::Malformed);
        }
        let (length_bytes, rest) = rest.split_at(LENGTH_PREFIX_LEN);
        let certificate_len = u32::from_be_bytes(length_bytes.try_into()?) as usize;

        if rest.len() < certificate_len {
            return Err(PkiError::Malformed);
        }
        let (certificate_bytes, rest) = rest.split_at(certificate_len);
        let certificate = Certificate::from_der(certificate_bytes)?;

        if rest.len() != SIGNATURE_LEN {
            return Err(PkiError::Malformed);
        }
        let signature = Signature::try_from(rest).map_err(|_| PkiError::Malformed)?;

        Ok(HookSignature {
            certificate_kind,
            certificate,
            signature,
        })
    }

    fn verify_issued_by(certificate: &Certificate, issuer_certificate: &Certificate) -> Result<(), PkiError> {
        let verifying_key = Self::extract_verifying_key(issuer_certificate)?;

        let tbs_der = certificate.tbs_certificate().to_der()?;

        let signature = Signature::try_from(certificate.signature().raw_bytes()).map_err(|_| PkiError::Malformed)?;

        verifying_key
            .verify(&tbs_der, &signature)
            .map_err(|_| PkiError::InvalidSignature)?;

        Ok(())
    }

    fn extract_verifying_key(certificate: &Certificate) -> Result<VerifyingKey, PkiError> {
        let key_bytes = certificate
            .tbs_certificate()
            .subject_public_key_info()
            .subject_public_key
            .raw_bytes();

        let key_bytes: [u8; 32] = key_bytes.try_into()?;

        VerifyingKey::from_bytes(&key_bytes).map_err(|_| PkiError::Malformed)
    }
}
