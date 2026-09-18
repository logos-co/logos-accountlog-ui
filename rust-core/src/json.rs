//! JSON for text that carries a key.

use serde::Serialize;

/// `value` as JSON, in a buffer sized before it is written with `spare` bytes
/// to go after it, so no buffer grown along the way leaves a copy of what it
/// holds in freed memory.
pub(crate) fn to_vec_sized<T: Serialize + ?Sized>(value: &T, spare: usize) -> Vec<u8> {
    let mut length = Length(0);
    serde_json::to_writer(&mut length, value).expect("a JSON value serializes");
    let mut bytes = Vec::with_capacity(length.0 + spare);
    serde_json::to_writer(&mut bytes, value).expect("a JSON value serializes");
    bytes
}

/// Counts what is written to it.
struct Length(usize);

impl std::io::Write for Length {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
