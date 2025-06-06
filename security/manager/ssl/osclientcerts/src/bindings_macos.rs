/* -*- Mode: rust; rust-indent-offset: 4 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// This was originally generated by rust-bindgen at build time. Later in
// development it became clear that using bindgen for this library as part of
// mozilla-central would be difficult (if not impossible). So, this was
// converted to a static file and unused declarations were removed. Also,
// intermediate types added by rust-bindgen were removed for clarity.

pub type OSStatus = i32;
pub const errSecSuccess: OSStatus = 0;
pub const errSecItemNotFound: OSStatus = -25300;

pub type SecKeyAlgorithm = CFStringRef;

extern "C" {
    // Available starting macOS 10.3
    pub fn SecCertificateGetTypeID() -> CFTypeID;
    pub fn SecTrustCreateWithCertificates(
        certificates: SecCertificateRef,
        policies: SecPolicyRef,
        trust: *mut SecTrustRef,
    ) -> OSStatus;
    pub fn SecIdentityGetTypeID() -> CFTypeID;
    pub fn SecIdentityCopyCertificate(
        identityRef: SecIdentityRef,
        certificateRef: *mut SecCertificateRef,
    ) -> OSStatus;
    pub fn SecIdentityCopyPrivateKey(
        identityRef: SecIdentityRef,
        privateKeyRef: *mut SecKeyRef,
    ) -> OSStatus;
    pub fn SecKeyGetTypeID() -> CFTypeID;
    pub fn SecPolicyGetTypeID() -> CFTypeID;
    pub fn SecTrustGetTypeID() -> CFTypeID;

    // Available starting macOS 10.6
    pub fn SecCertificateCopyData(certificate: SecCertificateRef) -> CFDataRef;
    pub fn SecCertificateCopySubjectSummary(certificate: SecCertificateRef) -> CFStringRef;
    pub fn SecItemCopyMatching(query: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
    pub fn SecPolicyCreateSSL(server: bool, hostname: CFStringRef) -> SecPolicyRef;
    pub static kSecClass: CFStringRef;
    pub static kSecAttrKeyType: CFStringRef;
    pub static kSecAttrKeySizeInBits: CFStringRef;
    pub static kSecMatchLimit: CFStringRef;
    pub static kSecMatchLimitAll: CFStringRef;
    pub static kSecReturnRef: CFStringRef;

    // Available starting macOS 10.7
    pub fn SecTrustGetCertificateAtIndex(trust: SecTrustRef, ix: CFIndex) -> SecCertificateRef;
    pub fn SecTrustGetCertificateCount(trust: SecTrustRef) -> CFIndex;
    pub static kSecClassIdentity: CFStringRef;
    pub static kSecAttrKeyTypeRSA: CFStringRef;

    // Available starting macOS 10.9
    pub fn SecTrustSetNetworkFetchAllowed(trust: SecTrustRef, allowFetch: Boolean) -> OSStatus;

    // Available starting macOS 10.12
    pub fn SecKeyCreateSignature(
        key: SecKeyRef,
        algorithm: SecKeyAlgorithm,
        data: CFDataRef,
        err: *mut CFErrorRef,
    ) -> CFDataRef;
    pub fn SecKeyCopyAttributes(key: SecKeyRef) -> CFDictionaryRef;
    pub fn SecKeyCopyExternalRepresentation(key: SecKeyRef, err: *mut CFErrorRef) -> CFDataRef;
    pub static kSecAttrKeyTypeECSECPrimeRandom: CFStringRef;
    pub static kSecKeyAlgorithmECDSASignatureDigestX962SHA1: CFStringRef;
    pub static kSecKeyAlgorithmECDSASignatureDigestX962SHA256: CFStringRef;
    pub static kSecKeyAlgorithmECDSASignatureDigestX962SHA384: CFStringRef;
    pub static kSecKeyAlgorithmECDSASignatureDigestX962SHA512: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512: CFStringRef;
    pub static kSecKeyAlgorithmRSASignatureRaw: CFStringRef;
}
