//! Public error domains. Checked access never substitutes assertions for errors.
//! Define runtime errors here and reference these sets at each failure site.
//! The `flatzz` facade reexports AccessError, MutationError, BuildError, and VerifyError.
//! Wire decoders use DecodeError directly. Missing optional fields normally return
//! null/defaults (or false for replacement), not an error.
//! Mutation errors preserve the operation's target bytes; construction errors can
//! retain partial children as documented by the calling builder/schema operation.

/// Fixed-width decoding can reject an unknown exhaustive enum tag.
pub const DecodeError = error{
    /// The wire representation is invalid; scalar decoding rejects unknown exhaustive-enum tags.
    InvalidBuffer,
};

/// Local bounds, framing, scalar-tag, and union validation failures.
/// Successful local access does not verify every reachable schema field.
pub const AccessError = DecodeError || error{
    /// A requested byte range or sequence index lies outside the available data.
    OutOfBounds,
    /// The selected frame's four-byte identifier differs from the expected bytes.
    IdentifierMismatch,
    /// Union tag/payload presence, paired vector counts, or vector ranges disagree.
    InvalidUnion,
    /// A union discriminator is absent from its exhaustive tag enum.
    UnknownUnionTag,
};
/// Checked-access failures plus size-preserving replacement restrictions.
/// AliasedInput rejects unsafe source overlap; ConflictingAlias rejects distinct
/// replacements for a single shared string target. Failed updates preserve bytes.
pub const MutationError = AccessError || error{
    /// A null replacement would remove a present field without rebuilding its table.
    CannotClearField,
    /// Replacement string lengths or vector counts differ from their stored sizes.
    LengthMismatch,
    /// Replacement string bytes are not valid UTF-8.
    InvalidUtf8,
    /// Replacement values or slice descriptors borrow the frame in an unsupported way.
    AliasedInput,
    /// References to the same stored string request different replacement bytes.
    ConflictingAlias,
};
/// Construction state, capacity, offset, schema-presence, and input failures.
/// NoSpaceLeft means the supplied storage is too small; BufferTooLarge means the
/// runtime's representable buffer limit would be exceeded.
pub const BuildError = error{
    /// A required schema field has no supplied value.
    MissingRequiredField,
    /// The operation conflicts with the builder state or uses a stale table context.
    InvalidState,
    /// A child handle lies outside completed storage, or the selected root is not a valid table.
    InvalidOffset,
    /// One physical table slot was added more than once, including explicit omissions.
    DuplicateField,
    /// Caller-owned builder storage cannot hold the requested output.
    NoSpaceLeft,
    /// The buffer or requested sequence would exceed the runtime's representable limit.
    BufferTooLarge,
    /// An inline table body exceeds the u16 size stored in its vtable.
    TableTooLarge,
    /// String input is not valid UTF-8.
    InvalidUtf8,
    /// Input overlaps builder storage where copying could corrupt pending values or metadata.
    AliasedInput,
    /// Supplied union slots or paired vectors are inconsistent.
    InvalidUnion,
    /// Native packing would exceed the active table-depth limit, including cycles.
    DepthLimit,
    /// Native graph traversal would exceed the configured work budget.
    WorkLimit,
};
/// Local-access failures plus missing required fields and traversal-budget limits.
pub const VerifyError = AccessError || error{
    /// A known required schema field is absent from the buffer.
    MissingRequiredField,
    /// Entering another table would exceed the active table-depth limit.
    DepthLimit,
    /// Visiting another table, string, or vector would exceed the object-visit limit.
    ObjectLimit,
    /// A field visit or declared payload would exceed the remaining traversal-work budget.
    WorkLimit,
};
