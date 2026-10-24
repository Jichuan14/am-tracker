// Read-only Apple Music playback query. Never launches Music.
var music = Application('com.apple.Music');
var result = {running: music.running()};
if (result.running) {
    result.state = music.playerState();
    if (result.state !== 'stopped') {
        var t = music.currentTrack;
        function read(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }
        result.title = read(function () { return t.name(); }, '');
        result.artist = read(function () { return t.artist(); }, '');
        result.album = read(function () { return t.album(); }, '');
        result.album_artist = read(function () { return t.albumArtist(); }, '');
        result.disc_number = read(function () { return t.discNumber(); }, 0);
        result.disc_count = read(function () { return t.discCount(); }, 0);
        result.track_number = read(function () { return t.trackNumber(); }, 0);
        result.track_count = read(function () { return t.trackCount(); }, 0);
        result.persistent_id = read(function () { return t.persistentID(); }, '');
        result.duration = read(function () { return t.duration(); }, 0);
        result.position = read(function () { return music.playerPosition(); }, 0);
    }
}
JSON.stringify(result);
