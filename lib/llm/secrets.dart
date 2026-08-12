/// Marks a value inside a tool result as secret.
///
/// A tool prefixes a sensitive value with this marker. The turn loop strips the
/// marker before the model reads the result, and the persistence layer replaces
/// the marked value with dots before writing it to SQLite. The user still sees
/// the real value in the live answer they asked for.
const String kSecretMarker = '__secret__';

/// Removes the marker, leaving the real secret. Used on the path to the model.
String stripSecretMarkers(String text) => text.replaceAll(kSecretMarker, '');

/// Replaces marked secrets with dots. Used on the path to SQLite, so a stored
/// transcript does not keep the WiFi passphrase in plain text forever.
///
/// This covers the verbatim tool result. It cannot cover the assistant's own
/// prose, which by design repeats the passphrase back to the user who asked
/// for it.
/// What a redacted secret is replaced with.
///
/// Phrased as an instruction rather than as dots because this string is what
/// the model reads when the turn is replayed from storage. Shown plain dots,
/// it answered follow-up questions about the passphrase by waffling about the
/// encryption mode; told what to do, it can call the tool again.
const String kRedactedPlaceholder = '[đã ẩn — gọi lại get_wifi_info để đọc]';

String redactSecrets(String text) =>
    text.replaceAll(RegExp('$kSecretMarker[^"]*'), kRedactedPlaceholder);
