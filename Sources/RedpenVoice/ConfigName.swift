import VoiceCore

/// Settings live in VoiceCore so their file handling can be tested. This keeps `Config` in the app meaning that
/// type, even if a speech framework the app imports ever declares a `Config` of its own.
typealias Config = VoiceCore.Config
