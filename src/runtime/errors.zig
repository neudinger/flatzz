//! Public error domains. Checked access never substitutes assertions for errors.
//! Define runtime errors here and reference these sets at each failure site.

/// Fixed-width decoding can reject an unknown exhaustive enum tag.
pub const DecodeError = error{InvalidBuffer};

/// Local bounds, framing, scalar-tag, and union validation failures.
/// Successful local access does not verify every reachable schema field.
pub const AccessError = DecodeError || error{
    OutOfBounds,
    IdentifierMismatch,
    InvalidUnion,
    UnknownUnionTag,
};
/// Checked-access failures plus size-preserving replacement restrictions.
/// AliasedInput rejects unsafe source overlap; ConflictingAlias rejects distinct
/// replacements for a single shared string target. Failed updates preserve bytes.
pub const MutationError = AccessError || error{
    CannotClearField,
    LengthMismatch,
    InvalidUtf8,
    AliasedInput,
    ConflictingAlias,
};
/// Construction state, capacity, offset, schema-presence, and input failures.
/// NoSpaceLeft means the supplied storage is too small; BufferTooLarge means the
/// runtime's representable buffer limit would be exceeded.
pub const BuildError = error{
    MissingRequiredField,
    InvalidState,
    InvalidOffset,
    DuplicateField,
    NoSpaceLeft,
    BufferTooLarge,
    TableTooLarge,
    InvalidUtf8,
    AliasedInput,
    InvalidUnion,
};
/// Local-access failures plus missing required fields and traversal-budget limits.
pub const VerifyError = AccessError || error{
    MissingRequiredField,
    DepthLimit,
    ObjectLimit,
    WorkLimit,
};
